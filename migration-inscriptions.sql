-- ============================================================================
-- Migration : « Dossier d'inscription » (annexes 1, 2 et 3 du club)
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-licences.sql déjà exécuté.
--
-- Ce que fait le script :
--   1. Annexe 1 (inscription) : ajoute à « licencies » le lien du responsable
--      (père, mère, tuteur) et deux personnes à contacter en cas d'urgence.
--      Le sexe, l'adresse, le téléphone, « responsable_legal » et
--      « telephone_urgence » (téléphone du responsable) existent déjà.
--   2. Annexe 1 et 2 : crée « inscriptions » (une ligne par licencié et saison) :
--      renseignements médicaux, dossier MDPH, autorisations de l'annexe 2,
--      lieu et date de signature.
--   3. Annexe 3 (fiche comptable) : crée « cotisations_saison » (montant dû,
--      code Pass'Sport, reçu remis) et « paiements_licencie » (une ligne par
--      chèque, chèque vacances, Pass'Sport ou paiement en espèces).
--   4. Cadre « réservé au club » : ajoute les pièces « photo », « caution » et
--      « fiche d'inscription » aux documents du dossier.
--   5. Sécurité par rôle :
--        - inscriptions (santé de mineurs) : admin et entraîneur uniquement ;
--        - cotisations et paiements : admin et trésorier uniquement ;
--        - toute personne hors du club ou non connectée : aucun accès.
--
-- La table « licences » existante (ancienne table de cotisations, sans club_id)
-- n'est pas modifiée et n'est plus utilisée par l'application.
-- ============================================================================

-- 0) Rôle de la personne connectée dans un club (déjà créé par les scripts précédents)
create or replace function public.role_dans_club(c uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select m.role::text
  from public.membres_club m
  where m.club_id = c and m.user_id = auth.uid()
  limit 1
$$;

revoke all on function public.role_dans_club(uuid) from public;
grant execute on function public.role_dans_club(uuid) to authenticated;

-- 1) Annexe 1 : responsable et personnes à contacter --------------------------
alter table public.licencies
  add column if not exists responsable_lien text,
  add column if not exists urgence1_nom     text,
  add column if not exists urgence1_tel     text,
  add column if not exists urgence1_lien    text,
  add column if not exists urgence2_nom     text,
  add column if not exists urgence2_tel     text,
  add column if not exists urgence2_lien    text;

-- 2) Inscription de la saison : santé et autorisations ------------------------
create table if not exists public.inscriptions (
  id               uuid primary key default gen_random_uuid(),
  club_id          uuid not null references public.clubs(id)     on delete cascade,
  licencie_id      uuid not null references public.licencies(id) on delete cascade,
  saison           text not null,
  date_inscription date,
  infos_medicales  text,
  mdph             boolean not null default false,
  aut_urgence      boolean not null default false,
  aut_hopital      boolean not null default false,
  aut_droit_image  boolean not null default false,
  aut_depart_seul  boolean not null default false,
  reglement_lu     boolean not null default false,
  lieu_signature   text,
  date_signature   date,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (licencie_id, saison)
);
create index if not exists inscriptions_club_idx on public.inscriptions (club_id, saison);

-- 3) Annexe 3 : cotisation et paiements ---------------------------------------
create table if not exists public.cotisations_saison (
  id            uuid primary key default gen_random_uuid(),
  club_id       uuid not null references public.clubs(id)     on delete cascade,
  licencie_id   uuid not null references public.licencies(id) on delete cascade,
  saison        text not null,
  montant_du    numeric(8,2) not null default 0,
  pass_sport    text,
  recu_remis    boolean not null default false,
  created_at    timestamptz not null default now(),
  unique (licencie_id, saison)
);
create index if not exists cotisations_club_idx on public.cotisations_saison (club_id, saison);

create table if not exists public.paiements_licencie (
  id           uuid primary key default gen_random_uuid(),
  club_id      uuid not null references public.clubs(id)     on delete cascade,
  licencie_id  uuid not null references public.licencies(id) on delete cascade,
  saison       text not null,
  mode         text not null check (mode in
                 ('cheque', 'cheques_vacances', 'pass_sport', 'especes', 'virement')),
  date_prevue  date,
  montant      numeric(8,2) not null default 0,
  banque       text,      -- banque du chèque, ou nature (ANCV, Sport…) pour les chèques vacances
  numero       text,      -- numéro du chèque
  encaisse_le  date,      -- vide tant que le règlement n'est pas encaissé
  created_at   timestamptz not null default now()
);
create index if not exists paiements_club_idx     on public.paiements_licencie (club_id, saison);
create index if not exists paiements_licencie_idx on public.paiements_licencie (licencie_id, saison);

-- 4) Cadre « réservé au club » : nouvelles pièces du dossier -------------------
-- Remplace la liste des types autorisés (l'ancienne liste reste valable).
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.documents_licencie'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%certificat_medical%'
  loop
    execute format('alter table public.documents_licencie drop constraint %I', c.conname);
  end loop;
  alter table public.documents_licencie
    add constraint documents_licencie_type_check check (type in
      ('certificat_medical', 'questionnaire_sante', 'autorisation_parentale',
       'droit_image', 'photo', 'caution', 'fiche_inscription'));
end $$;

-- 5) Sécurité par rôle ---------------------------------------------------------
alter table public.inscriptions        enable row level security;
alter table public.cotisations_saison  enable row level security;
alter table public.paiements_licencie  enable row level security;

drop policy if exists inscriptions_acces on public.inscriptions;
create policy inscriptions_acces on public.inscriptions
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

drop policy if exists cotisations_acces on public.cotisations_saison;
create policy cotisations_acces on public.cotisations_saison
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'tresorier'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'tresorier')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

drop policy if exists paiements_acces on public.paiements_licencie;
create policy paiements_acces on public.paiements_licencie
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'tresorier'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'tresorier')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

revoke all on public.inscriptions       from anon;
revoke all on public.cotisations_saison from anon;
revoke all on public.paiements_licencie from anon;
grant select, insert, update, delete on public.inscriptions       to authenticated;
grant select, insert, update, delete on public.cotisations_saison to authenticated;
grant select, insert, update, delete on public.paiements_licencie to authenticated;
