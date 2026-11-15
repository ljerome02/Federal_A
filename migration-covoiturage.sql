-- ============================================================================
-- Migration : covoiturage des entraînements (suivi tenu par les entraîneurs)
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-presences.sql déjà exécuté.
--
-- Les entraîneurs font un sondage (WhatsApp), puis saisissent eux-mêmes :
--   - les gyms qui viennent ou non à chaque déplacement ;
--   - les conducteurs disponibles à l'aller et au retour (parents, gyms qui ont
--     le permis, entraîneurs), chacun avec son nombre de places ;
--   - la répartition des gyms dans les voitures.
-- L'application en tire le suivi (qui a conduit, combien de fois, écart entre
-- deux covoiturages, alertes) et le message d'annonce des départs.
--
-- Tables :
--   cv_acces       : comptes autorisés à voir et gérer le covoiturage ;
--   cv_config      : groupes fusionnés, lieu de départ habituel, seuils d'alerte ;
--   cv_conducteurs : conducteurs, places, enfants ou gym liée ;
--   cv_sorties     : déplacements (date, lieu, horaires, départ commun) ;
--   cv_reponses    : oui / non par gym, et sa voiture à l'aller et au retour ;
--   cv_dispos      : conducteurs disponibles pour un déplacement.
--
-- Accès : UNIQUEMENT les comptes inscrits dans cv_acces (quel que soit leur rôle).
-- Les autres membres du club, même administrateurs, ne voient rien.
-- Pour autoriser un compte (à faire ici, dans le SQL Editor) :
--   insert into public.cv_acces (club_id, user_id)
--   select m.club_id, m.user_id from public.membres_club m
--   join auth.users u on u.id = m.user_id where u.email = 'adresse@exemple.fr'
--   on conflict do nothing;
--
-- Cette version remplace l'essai précédent (lien pour les parents) : ses tables
-- covoit_* et ses fonctions accessibles sans compte sont supprimées.
-- ============================================================================

-- 0) Retrait de l'ancienne version (page des parents) ----------------------------
drop function if exists public.covoit_public_voir(text);
drop function if exists public.covoit_public_repondre(text, uuid, text, boolean, boolean, text);
drop function if exists public.covoit_public_voiture(text, uuid, text, text, text, int, text, text, text, text);
drop function if exists public.covoit_public_voiture_suppr(text, uuid, text);
drop function if exists public.covoit_public_place(text, uuid, uuid, boolean, boolean);
drop function if exists public.covoit_sortie_du_lien(text, boolean);
drop table if exists public.covoit_passagers;
drop table if exists public.covoit_voitures;
drop table if exists public.covoit_reponses;
drop table if exists public.covoit_sorties;
drop function if exists public.covoit_passager_verif();
drop function if exists public.covoit_voiture_verif();

-- 1) Tables --------------------------------------------------------------------
create table if not exists public.cv_acces (
  club_id    uuid not null references public.clubs(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (club_id, user_id)
);

create table if not exists public.cv_config (
  club_id     uuid primary key references public.clubs(id) on delete cascade,
  groupes     uuid[] not null default '{}',          -- groupes fusionnés pour le covoiturage
  rdv_lieu    text check (rdv_lieu is null or char_length(rdv_lieu) <= 120),  -- lieu de départ habituel
  seuil_sans  smallint not null default 3 check (seuil_sans between 1 and 20),   -- alerte : déplacements sans conduire
  seuil_jours smallint not null default 14 check (seuil_jours between 1 and 120), -- alerte : jours entre deux covoiturages
  updated_at  timestamptz not null default now()
);

create table if not exists public.cv_conducteurs (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  nom         text not null check (char_length(nom) between 1 and 60),
  type        text not null default 'parent' check (type in ('parent', 'gym', 'entraineur')),
  places      smallint not null default 3 check (places between 1 and 8),   -- gyms transportées, conducteur non compté
  licencie_id uuid references public.licencies(id) on delete set null,      -- la gym qui conduit (type gym)
  enfants     uuid[] not null default '{}',                                 -- ses enfants (type parent)
  telephone   text check (telephone is null or char_length(telephone) <= 30),
  depart_lieu text check (depart_lieu is null or char_length(depart_lieu) <= 120),
  actif       boolean not null default true,
  auto        boolean not null default false,    -- part d'office : disponible à chaque nouveau déplacement
  created_at  timestamptz not null default now()
);
alter table public.cv_conducteurs add column if not exists auto boolean not null default false;
create index if not exists cv_conducteurs_club_idx on public.cv_conducteurs (club_id);

create table if not exists public.cv_sorties (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  date        date not null,
  lieu        text check (lieu is null or char_length(lieu) <= 120),
  heure_debut time,
  heure_fin   time,
  titre       text check (titre is null or char_length(titre) <= 80),
  rdv_lieu    text check (rdv_lieu is null or char_length(rdv_lieu) <= 120),  -- départ commun à l'aller
  rdv_heure   time,
  note        text check (note is null or char_length(note) <= 500),
  created_at  timestamptz not null default now()
);
create index if not exists cv_sorties_club_idx on public.cv_sorties (club_id, date);

create table if not exists public.cv_reponses (
  sortie_id   uuid not null references public.cv_sorties(id) on delete cascade,
  licencie_id uuid not null references public.licencies(id) on delete cascade,
  club_id     uuid not null references public.clubs(id) on delete cascade,
  statut      text not null check (statut in ('oui', 'non')),
  aller_cond  uuid references public.cv_conducteurs(id) on delete set null,   -- voiture à l'aller
  retour_cond uuid references public.cv_conducteurs(id) on delete set null,   -- voiture au retour
  updated_at  timestamptz not null default now(),
  primary key (sortie_id, licencie_id)
);
create index if not exists cv_reponses_club_idx on public.cv_reponses (club_id);
create index if not exists cv_reponses_aller_idx on public.cv_reponses (aller_cond);
create index if not exists cv_reponses_retour_idx on public.cv_reponses (retour_cond);

create table if not exists public.cv_dispos (
  sortie_id     uuid not null references public.cv_sorties(id) on delete cascade,
  conducteur_id uuid not null references public.cv_conducteurs(id) on delete cascade,
  club_id       uuid not null references public.clubs(id) on delete cascade,
  aller         boolean not null default false,
  retour        boolean not null default false,
  places        smallint check (places is null or places between 1 and 8),    -- si différent ce jour-là
  rdv_lieu      text check (rdv_lieu is null or char_length(rdv_lieu) <= 120), -- départ propre à cette voiture
  rdv_heure     time,
  primary key (sortie_id, conducteur_id),
  check (aller or retour)
);
create index if not exists cv_dispos_club_idx on public.cv_dispos (club_id);
create index if not exists cv_dispos_cond_idx on public.cv_dispos (conducteur_id);

-- 2) Qui a accès ? ---------------------------------------------------------------
create or replace function public.cv_ok(c uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.cv_acces a where a.club_id = c and a.user_id = auth.uid())
     and public.role_dans_club(c) is not null
$$;
revoke all on function public.cv_ok(uuid) from public, anon;
grant execute on function public.cv_ok(uuid) to authenticated;

-- 3) Règles d'accès --------------------------------------------------------------
alter table public.cv_acces       enable row level security;
alter table public.cv_config      enable row level security;
alter table public.cv_conducteurs enable row level security;
alter table public.cv_sorties     enable row level security;
alter table public.cv_reponses    enable row level security;
alter table public.cv_dispos      enable row level security;

drop policy if exists cv_acces_moi on public.cv_acces;
create policy cv_acces_moi on public.cv_acces
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists cv_config_tout on public.cv_config;
create policy cv_config_tout on public.cv_config
  for all to authenticated using (public.cv_ok(club_id)) with check (public.cv_ok(club_id));

drop policy if exists cv_conducteurs_tout on public.cv_conducteurs;
create policy cv_conducteurs_tout on public.cv_conducteurs
  for all to authenticated using (public.cv_ok(club_id)) with check (public.cv_ok(club_id));

drop policy if exists cv_sorties_tout on public.cv_sorties;
create policy cv_sorties_tout on public.cv_sorties
  for all to authenticated using (public.cv_ok(club_id)) with check (public.cv_ok(club_id));

drop policy if exists cv_reponses_tout on public.cv_reponses;
create policy cv_reponses_tout on public.cv_reponses
  for all to authenticated using (public.cv_ok(club_id))
  with check (public.cv_ok(club_id)
    and club_id = (select s.club_id from public.cv_sorties s where s.id = sortie_id)
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id));

drop policy if exists cv_dispos_tout on public.cv_dispos;
create policy cv_dispos_tout on public.cv_dispos
  for all to authenticated using (public.cv_ok(club_id))
  with check (public.cv_ok(club_id)
    and club_id = (select s.club_id from public.cv_sorties s where s.id = sortie_id)
    and club_id = (select c.club_id from public.cv_conducteurs c where c.id = conducteur_id));

revoke all on public.cv_acces, public.cv_config, public.cv_conducteurs, public.cv_sorties, public.cv_reponses, public.cv_dispos from anon;
revoke all on public.cv_acces, public.cv_config, public.cv_conducteurs, public.cv_sorties, public.cv_reponses, public.cv_dispos from authenticated;
grant select on public.cv_acces to authenticated;
grant select, insert, update, delete
  on public.cv_config, public.cv_conducteurs, public.cv_sorties, public.cv_reponses, public.cv_dispos to authenticated;
