-- ============================================================================
-- TOUTES LES MIGRATIONS DE L'APPLICATION, dans l'ordre (chacune peut être relancée sans risque)
-- À coller en une fois dans Supabase > SQL Editor, puis « Run query ».
-- ============================================================================


-- >>>>>>>>>> migration-licences.sql <<<<<<<<<<
-- ============================================================================
-- Migration : module « Licences et documents »  (version 2)
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
--
-- Important : la table « licences » existante (cotisations : montant, paiement,
-- statut…) n'est PAS modifiée. Les licences fédérales sont dans une nouvelle
-- table, « licences_federales ».
--
-- Ce que fait le script :
--   1. ajoute « parent_email » à la table « licencies » (les autres coordonnées,
--      « responsable_legal » et « telephone_urgence » existent déjà et sont
--      réutilisées pour le contact parent) ;
--   2. crée « licences_federales » : une ligne par licencié, saison et
--      fédération (FFG ou UFOLEP), avec le numéro de licence ;
--   3. crée « documents_licencie » : certificat médical, questionnaire de santé,
--      autorisation parentale, droit à l'image, avec dates ;
--   4. protège les deux nouvelles tables par rôle :
--        - admin et entraîneur : lecture et écriture ;
--        - trésorier : lecture des licences fédérales uniquement, aucun accès
--          aux documents (données de santé de mineurs) ;
--        - toute personne hors du club ou non connectée : aucun accès.
-- ============================================================================

-- 1) Contact parent : un seul champ à ajouter ---------------------------------
alter table public.licencies
  add column if not exists parent_email text;

-- 2) Rôle de la personne connectée dans un club ------------------------------
-- security definer : lit « membres_club » sans dépendre de ses propres règles
-- d'accès (évite les boucles de règles).
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

revoke all on function public.role_dans_club(uuid) from public, anon;
grant execute on function public.role_dans_club(uuid) to authenticated;

-- 3) Licences fédérales : une ligne par licencié, saison et fédération --------
create table if not exists public.licences_federales (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id)     on delete cascade,
  licencie_id uuid not null references public.licencies(id) on delete cascade,
  saison      text not null,
  federation  text not null check (federation in ('FFG', 'UFOLEP')),
  numero      text,
  created_at  timestamptz not null default now(),
  unique (licencie_id, saison, federation)
);
create index if not exists licences_fed_club_idx     on public.licences_federales (club_id, saison);
create index if not exists licences_fed_licencie_idx on public.licences_federales (licencie_id);

-- 4) Documents du dossier -----------------------------------------------------
create table if not exists public.documents_licencie (
  id            uuid primary key default gen_random_uuid(),
  club_id       uuid not null references public.clubs(id)     on delete cascade,
  licencie_id   uuid not null references public.licencies(id) on delete cascade,
  type          text not null check (type in
                  ('certificat_medical', 'questionnaire_sante',
                   'autorisation_parentale', 'droit_image')),
  date_remise   date,
  date_validite date,
  created_at    timestamptz not null default now(),
  unique (licencie_id, type)
);
create index if not exists documents_club_idx     on public.documents_licencie (club_id);
create index if not exists documents_licencie_idx on public.documents_licencie (licencie_id);

-- 5) Sécurité par rôle ---------------------------------------------------------
alter table public.licences_federales enable row level security;
alter table public.documents_licencie enable row level security;

-- Licences fédérales : tous les membres du club lisent ; admin et entraîneur écrivent.
drop policy if exists licences_fed_lecture  on public.licences_federales;
drop policy if exists licences_fed_ecriture on public.licences_federales;

create policy licences_fed_lecture on public.licences_federales
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);

create policy licences_fed_ecriture on public.licences_federales
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

-- Documents : admin et entraîneur uniquement (lecture et écriture).
drop policy if exists documents_acces on public.documents_licencie;

create policy documents_acces on public.documents_licencie
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

-- Aucun accès sans connexion.
revoke all on public.licences_federales from anon;
revoke all on public.documents_licencie from anon;
grant select, insert, update, delete on public.licences_federales to authenticated;
grant select, insert, update, delete on public.documents_licencie to authenticated;

-- ----------------------------------------------------------------------------
-- Nettoyage facultatif : la première version du script, interrompue par une
-- erreur, a pu ajouter deux colonnes vides à « licencies ». Si la requête
-- suivante renvoie des lignes, décommentez les deux lignes d'après et exécutez-les.
--   select column_name from information_schema.columns
--   where table_schema='public' and table_name='licencies'
--     and column_name in ('parent_nom','parent_telephone');
--   -- alter table public.licencies drop column if exists parent_nom;
--   -- alter table public.licencies drop column if exists parent_telephone;
-- ----------------------------------------------------------------------------


-- >>>>>>>>>> migration-presences.sql <<<<<<<<<<
-- ============================================================================
-- Migration : module « Groupes et présences »
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
--
-- Crée trois nouvelles tables, aucune table existante n'est modifiée :
--   groupes_entrainement : un groupe = un créneau (jour, horaires, lieu) pour une saison ;
--   groupe_licencies     : quels licenciés font partie de quel groupe ;
--   presences_seances    : une ligne par licencié, groupe et date (présente,
--                          absente ou excusée). Pas de ligne = pas pointée.
--
-- Accès par rôle :
--   - admin et entraîneur : lecture et écriture (ils pointent les présences) ;
--   - trésorier : lecture seule ;
--   - toute personne hors du club ou non connectée : aucun accès.
-- ============================================================================

-- 0) Sécurité du script : s'arrêter proprement si un nom de table est déjà pris
--    par une table d'une autre structure (rien n'est alors modifié).
do $$
declare t text;
begin
  foreach t in array array['groupes_entrainement', 'groupe_licencies', 'presences_seances'] loop
    if exists (select 1 from information_schema.tables
               where table_schema = 'public' and table_name = t)
       and not exists (select 1 from information_schema.columns
                       where table_schema = 'public' and table_name = t and column_name = 'club_id') then
      raise exception 'La table % existe déjà avec une autre structure : script arrêté, rien n''a été modifié.', t;
    end if;
  end loop;
end $$;

-- 1) Rôle de la personne connectée dans un club (déjà créé par migration-licences.sql ;
--    recréé ici à l'identique pour que ce script fonctionne seul).
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

revoke all on function public.role_dans_club(uuid) from public, anon;
grant execute on function public.role_dans_club(uuid) to authenticated;

-- 2) Groupes (créneaux d'entraînement) ----------------------------------------
create table if not exists public.groupes_entrainement (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  saison      text not null,
  nom         text not null,
  jour        smallint check (jour between 1 and 7),   -- 1 = lundi … 7 = dimanche
  heure_debut time,
  heure_fin   time,
  lieu        text,
  created_at  timestamptz not null default now()
);
create index if not exists groupes_ent_club_idx on public.groupes_entrainement (club_id, saison);

-- 3) Membres des groupes ---------------------------------------------------------
create table if not exists public.groupe_licencies (
  groupe_id   uuid not null references public.groupes_entrainement(id) on delete cascade,
  licencie_id uuid not null references public.licencies(id)            on delete cascade,
  club_id     uuid not null references public.clubs(id)                on delete cascade,
  primary key (groupe_id, licencie_id)
);
create index if not exists groupe_lic_club_idx     on public.groupe_licencies (club_id);
create index if not exists groupe_lic_licencie_idx on public.groupe_licencies (licencie_id);

-- 4) Présences : une ligne par licencié, groupe et date -----------------------
create table if not exists public.presences_seances (
  groupe_id   uuid not null references public.groupes_entrainement(id) on delete cascade,
  licencie_id uuid not null references public.licencies(id)            on delete cascade,
  date        date not null,
  club_id     uuid not null references public.clubs(id)                on delete cascade,
  statut      text not null check (statut in ('present', 'absent', 'excuse')),
  updated_at  timestamptz not null default now(),
  primary key (groupe_id, licencie_id, date)
);
create index if not exists presences_club_date_idx on public.presences_seances (club_id, date);

-- 5) Sécurité par rôle -----------------------------------------------------------
alter table public.groupes_entrainement enable row level security;
alter table public.groupe_licencies     enable row level security;
alter table public.presences_seances    enable row level security;

drop policy if exists groupes_ent_lecture  on public.groupes_entrainement;
drop policy if exists groupes_ent_ecriture on public.groupes_entrainement;
create policy groupes_ent_lecture on public.groupes_entrainement
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy groupes_ent_ecriture on public.groupes_entrainement
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (public.role_dans_club(club_id) in ('admin', 'entraineur'));

drop policy if exists groupe_lic_lecture  on public.groupe_licencies;
drop policy if exists groupe_lic_ecriture on public.groupe_licencies;
create policy groupe_lic_lecture on public.groupe_licencies
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy groupe_lic_ecriture on public.groupe_licencies
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

drop policy if exists presences_lecture  on public.presences_seances;
drop policy if exists presences_ecriture on public.presences_seances;
create policy presences_lecture on public.presences_seances
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy presences_ecriture on public.presences_seances
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

-- Aucun accès sans connexion.
revoke all on public.groupes_entrainement from anon;
revoke all on public.groupe_licencies     from anon;
revoke all on public.presences_seances    from anon;
grant select, insert, update, delete on public.groupes_entrainement to authenticated;
grant select, insert, update, delete on public.groupe_licencies     to authenticated;
grant select, insert, update, delete on public.presences_seances    to authenticated;


-- >>>>>>>>>> migration-inscriptions.sql <<<<<<<<<<
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

revoke all on function public.role_dans_club(uuid) from public, anon;
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
  -- déjà remplacée par un contrôle de format (migration-parametres.sql) : on n'y touche plus
  if exists (select 1 from pg_constraint where conrelid = 'public.documents_licencie'::regclass
             and conname = 'documents_licencie_type_check' and pg_get_constraintdef(oid) like '%~%') then return; end if;
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


-- >>>>>>>>>> migration-communication.sql <<<<<<<<<<
-- ============================================================================
-- Migration : lien WhatsApp des groupes d'entraînement
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-presences.sql déjà exécuté.
--
-- Ajoute à « groupes_entrainement » la colonne « lien_whatsapp » : le lien
-- d'invitation du groupe WhatsApp (https://chat.whatsapp.com/…). Il se saisit
-- dans Présences et groupes > Groupes, et s'ouvre en un clic depuis la page
-- Messages et WhatsApp et depuis la fiche des licenciés membres du groupe.
-- Les droits existants sur la table ne changent pas.
-- ============================================================================
alter table public.groupes_entrainement
  add column if not exists lien_whatsapp text;


-- >>>>>>>>>> migration-famille.sql <<<<<<<<<<
-- ============================================================================
-- Migration : liens de parenté entre adhérents (onglet « Famille » de la fiche)
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-licences.sql déjà exécuté.
--
-- Une ligne = « autre_id est le/la <lien> de licencie_id ».
-- L'application affiche le lien dans les deux fiches (parent ↔ enfant inversés,
-- frère ou sœur, cousin, conjoint… identiques dans les deux sens).
-- Lecture : tous les membres du club. Modification : administrateur et entraîneur.
-- ============================================================================
create table if not exists public.liens_familiaux (
  id           uuid primary key default gen_random_uuid(),
  club_id      uuid not null references public.clubs(id)     on delete cascade,
  licencie_id  uuid not null references public.licencies(id) on delete cascade,
  autre_id     uuid not null references public.licencies(id) on delete cascade,
  lien         text not null default 'fratrie'
               check (lien in ('fratrie', 'parent', 'enfant', 'cousin', 'conjoint', 'autre')),
  created_at   timestamptz not null default now(),
  check (licencie_id <> autre_id),
  unique (licencie_id, autre_id)
);
create index if not exists liens_familiaux_club_idx on public.liens_familiaux (club_id);

alter table public.liens_familiaux enable row level security;

drop policy if exists liens_familiaux_lecture  on public.liens_familiaux;
drop policy if exists liens_familiaux_ecriture on public.liens_familiaux;

create policy liens_familiaux_lecture on public.liens_familiaux
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);

create policy liens_familiaux_ecriture on public.liens_familiaux
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
    and club_id = (select l.club_id from public.licencies l where l.id = autre_id)
  );

revoke all on public.liens_familiaux from anon;
grant select, insert, update, delete on public.liens_familiaux to authenticated;


-- >>>>>>>>>> migration-roles.sql <<<<<<<<<<
-- ============================================================================
-- Migration : rôles des adhérents dans l'association
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-licences.sql déjà exécuté.
--
-- Ajoute à « licencies » :
--   - fonctions       : liste des rôles, cumulables (gymnaste, président, trésorier,
--                       entraîneur, juge…) ;
--   - fonctions_note  : précisions libres (niveau de juge, diplôme d'entraîneur…).
-- Les adhérents déjà enregistrés reçoivent le rôle « gymnaste ».
-- Ces rôles décrivent l'association ; ils ne donnent aucun droit dans
-- l'application (les accès restent gérés dans « Membres »).
-- ============================================================================
alter table public.licencies
  add column if not exists fonctions      text[] not null default '{gymnaste}',
  add column if not exists fonctions_note text;

update public.licencies set fonctions = '{gymnaste}'
where fonctions is null or cardinality(fonctions) = 0;

create index if not exists licencies_fonctions_idx on public.licencies using gin (fonctions);


-- >>>>>>>>>> migration-creneaux.sql <<<<<<<<<<
-- ============================================================================
-- Migration : plusieurs entraînements par semaine, vacances scolaires,
--             noms de famille en majuscules
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-presences.sql déjà exécuté.
--
-- 1. Noms de famille des adhérents mis en majuscules.
-- 2. « periodes_vacances » : les vacances scolaires de la saison (remplies
--    depuis l'application avec le calendrier officiel, modifiables).
-- 3. « groupe_creneaux » : les entraînements d'un groupe.
--      - type 'saison'   : jour et horaires hors vacances, au lieu fixe du groupe ;
--      - type 'vacances' : jour, horaires et lieu pendant les vacances
--                          (une période précise, ou toutes si vacance_id est vide).
--    Les jours et horaires déjà saisis sur les groupes sont repris comme
--    premier entraînement de la saison.
-- Lecture : membres du club. Modification : administrateur et entraîneur.
-- ============================================================================

-- 1) Noms de famille en majuscules
update public.licencies set nom = upper(nom) where nom is not null and nom <> upper(nom);

-- 2) Vacances scolaires
create table if not exists public.periodes_vacances (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  saison      text not null,
  nom         text not null,
  debut       date not null,   -- premier jour de vacances
  fin         date not null,   -- dernier jour de vacances (veille de la reprise)
  created_at  timestamptz not null default now(),
  check (fin >= debut)
);
create index if not exists periodes_vacances_club_idx on public.periodes_vacances (club_id, saison);

-- 3) Entraînements des groupes
create table if not exists public.groupe_creneaux (
  id           uuid primary key default gen_random_uuid(),
  club_id      uuid not null references public.clubs(id) on delete cascade,
  groupe_id    uuid not null references public.groupes_entrainement(id) on delete cascade,
  type         text not null default 'saison' check (type in ('saison', 'vacances')),
  vacance_id   uuid references public.periodes_vacances(id) on delete cascade,
  jour         smallint not null check (jour between 1 and 7),   -- 1 = lundi … 7 = dimanche
  heure_debut  time,
  heure_fin    time,
  lieu         text,      -- vacances : lieu du créneau (vide = lieu habituel du groupe)
  created_at   timestamptz not null default now()
);
create index if not exists groupe_creneaux_groupe_idx on public.groupe_creneaux (groupe_id);
create index if not exists groupe_creneaux_club_idx   on public.groupe_creneaux (club_id);

-- reprise de l'horaire unique déjà saisi sur chaque groupe
insert into public.groupe_creneaux (club_id, groupe_id, type, jour, heure_debut, heure_fin)
select g.club_id, g.id, 'saison', g.jour, g.heure_debut, g.heure_fin
from public.groupes_entrainement g
where g.jour is not null
  and not exists (select 1 from public.groupe_creneaux c where c.groupe_id = g.id);

-- 4) Sécurité
alter table public.periodes_vacances enable row level security;
alter table public.groupe_creneaux   enable row level security;

drop policy if exists periodes_vacances_lecture  on public.periodes_vacances;
drop policy if exists periodes_vacances_ecriture on public.periodes_vacances;
create policy periodes_vacances_lecture on public.periodes_vacances
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy periodes_vacances_ecriture on public.periodes_vacances
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (public.role_dans_club(club_id) in ('admin', 'entraineur'));

drop policy if exists groupe_creneaux_lecture  on public.groupe_creneaux;
drop policy if exists groupe_creneaux_ecriture on public.groupe_creneaux;
create policy groupe_creneaux_lecture on public.groupe_creneaux
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy groupe_creneaux_ecriture on public.groupe_creneaux
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
    and (vacance_id is null or club_id = (select v.club_id from public.periodes_vacances v where v.id = vacance_id))
  );

revoke all on public.periodes_vacances from anon;
revoke all on public.groupe_creneaux   from anon;
grant select, insert, update, delete on public.periodes_vacances to authenticated;
grant select, insert, update, delete on public.groupe_creneaux   to authenticated;


-- >>>>>>>>>> migration-seances.sql <<<<<<<<<<
-- ============================================================================
-- Migration : séances ponctuelles et séances annulées
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-creneaux.sql déjà exécuté.
--
-- 1. « groupe_creneaux » accepte un 3e type, 'ponctuel' : une séance à une date
--    précise (stage pendant les vacances, séance exceptionnelle…), colonne « date ».
--    Le lieu peut aussi être précisé pour les entraînements de la saison.
--    Colonne « libelle » : intitulé d'une séance ponctuelle (Stage, Fête du club…).
-- 2. « seances_annulees » : une séance prévue qui n'a pas lieu à une date donnée
--    (elle disparaît du planning et du pointage ce jour-là).
-- Lecture : membres du club. Modification : administrateur et entraîneur.
-- ============================================================================

-- 1) Séances ponctuelles
alter table public.groupe_creneaux add column if not exists date date;
alter table public.groupe_creneaux add column if not exists libelle text;

do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.groupe_creneaux'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%vacances%'
  loop
    execute format('alter table public.groupe_creneaux drop constraint %I', c.conname);
  end loop;
  alter table public.groupe_creneaux
    add constraint groupe_creneaux_type_check check (type in ('saison', 'vacances', 'ponctuel'));
  alter table public.groupe_creneaux drop constraint if exists groupe_creneaux_date_check;
  alter table public.groupe_creneaux
    add constraint groupe_creneaux_date_check check (type <> 'ponctuel' or date is not null);
end $$;

-- 2) Séances annulées
create table if not exists public.seances_annulees (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  groupe_id   uuid not null references public.groupes_entrainement(id) on delete cascade,
  creneau_id  uuid not null references public.groupe_creneaux(id) on delete cascade,
  date        date not null,
  created_at  timestamptz not null default now(),
  unique (creneau_id, date)
);
create index if not exists seances_annulees_club_idx on public.seances_annulees (club_id);

alter table public.seances_annulees enable row level security;

drop policy if exists seances_annulees_lecture  on public.seances_annulees;
drop policy if exists seances_annulees_ecriture on public.seances_annulees;
create policy seances_annulees_lecture on public.seances_annulees
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy seances_annulees_ecriture on public.seances_annulees
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
  );

revoke all on public.seances_annulees from anon;
grant select, insert, update, delete on public.seances_annulees to authenticated;


-- >>>>>>>>>> migration-entraineurs.sql <<<<<<<<<<
-- ============================================================================
-- Migration : entraîneurs des groupes d'entraînement
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-presences.sql déjà exécuté.
--
-- « groupe_entraineurs » : un ou plusieurs adhérents encadrent chaque groupe.
-- Les entraîneurs ne sont pas des membres du groupe : ils n'apparaissent pas
-- dans le pointage des présences.
-- Lecture : membres du club. Modification : administrateur et entraîneur.
-- ============================================================================
create table if not exists public.groupe_entraineurs (
  groupe_id    uuid not null references public.groupes_entrainement(id) on delete cascade,
  licencie_id  uuid not null references public.licencies(id) on delete cascade,
  club_id      uuid not null references public.clubs(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (groupe_id, licencie_id)
);
create index if not exists groupe_entraineurs_club_idx on public.groupe_entraineurs (club_id);

alter table public.groupe_entraineurs enable row level security;

drop policy if exists groupe_entraineurs_lecture  on public.groupe_entraineurs;
drop policy if exists groupe_entraineurs_ecriture on public.groupe_entraineurs;
create policy groupe_entraineurs_lecture on public.groupe_entraineurs
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy groupe_entraineurs_ecriture on public.groupe_entraineurs
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

revoke all on public.groupe_entraineurs from anon;
grant select, insert, update, delete on public.groupe_entraineurs to authenticated;


-- >>>>>>>>>> migration-rotations.sql <<<<<<<<<<
-- ============================================================================
-- Migration : rotations d'agrès
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-presences.sql déjà exécuté.
--
-- « rotations_agres » : pour un groupe et une date d'entraînement, l'ordre des
-- agrès et le temps passé sur chacun, par exemple
--   [{"a":"saut","m":20},{"a":"barres","m":30},{"a":"poutre","m":30},{"a":"sol","m":40}]
-- Lecture : membres du club. Modification : administrateur et entraîneur.
-- ============================================================================
create table if not exists public.rotations_agres (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  groupe_id   uuid not null references public.groupes_entrainement(id) on delete cascade,
  date        date not null,
  agres       jsonb not null default '[]'::jsonb,
  updated_at  timestamptz not null default now(),
  unique (groupe_id, date)
);
create index if not exists rotations_agres_club_idx on public.rotations_agres (club_id, date);

alter table public.rotations_agres enable row level security;

drop policy if exists rotations_agres_lecture  on public.rotations_agres;
drop policy if exists rotations_agres_ecriture on public.rotations_agres;
create policy rotations_agres_lecture on public.rotations_agres
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy rotations_agres_ecriture on public.rotations_agres
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
  );

revoke all on public.rotations_agres from anon;
grant select, insert, update, delete on public.rotations_agres to authenticated;


-- >>>>>>>>>> migration-lieux.sql <<<<<<<<<<
-- ============================================================================
-- Migration : lieu modifié pour une seule séance
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-creneaux.sql déjà exécuté.
--
-- « seances_exceptions » : pour un entraînement (créneau) et une date, un lieu
-- différent du lieu habituel (ex. séance à Saint-Quentin au lieu de Chauny).
-- Lecture : membres du club. Modification : administrateur et entraîneur.
-- ============================================================================
create table if not exists public.seances_exceptions (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  groupe_id   uuid not null references public.groupes_entrainement(id) on delete cascade,
  creneau_id  uuid not null references public.groupe_creneaux(id) on delete cascade,
  date        date not null,
  lieu        text not null,
  created_at  timestamptz not null default now(),
  unique (creneau_id, date)
);
create index if not exists seances_exceptions_club_idx on public.seances_exceptions (club_id);

alter table public.seances_exceptions enable row level security;

drop policy if exists seances_exceptions_lecture  on public.seances_exceptions;
drop policy if exists seances_exceptions_ecriture on public.seances_exceptions;
create policy seances_exceptions_lecture on public.seances_exceptions
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy seances_exceptions_ecriture on public.seances_exceptions
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
  );

revoke all on public.seances_exceptions from anon;
grant select, insert, update, delete on public.seances_exceptions to authenticated;

-- >>>>>>>>>> migration-parametres.sql <<<<<<<<<<
-- ============================================================================
-- Migration : paramètres du club (page « Paramètres »)
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-licences.sql et migration-inscriptions.sql déjà exécutés.
--
-- « parametres_club » : une ligne par liste modifiable (lieux, rôles, agrès,
-- pièces du dossier, modes de règlement, modèles de messages, réglages…).
-- La valeur est du JSON ; sans ligne, l'application garde ses listes par défaut.
-- Lecture : membres du club. Modification : administrateur seulement.
--
-- Les pièces du dossier et les modes de règlement ajoutés depuis la page
-- Paramètres ont un code libre : la liste fermée des valeurs autorisées est
-- remplacée par un contrôle de format (lettres minuscules, chiffres, « _ »).
-- Aucune donnée existante n'est modifiée.
-- ============================================================================
create table if not exists public.parametres_club (
  club_id     uuid not null references public.clubs(id) on delete cascade,
  cle         text not null check (cle ~ '^[a-z0-9_]{1,40}$'),
  valeur      jsonb not null,
  updated_at  timestamptz not null default now(),
  primary key (club_id, cle)
);

alter table public.parametres_club enable row level security;

drop policy if exists parametres_club_lecture  on public.parametres_club;
drop policy if exists parametres_club_ecriture on public.parametres_club;
create policy parametres_club_lecture on public.parametres_club
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy parametres_club_ecriture on public.parametres_club
  for all to authenticated
  using (public.role_dans_club(club_id) = 'admin')
  with check (public.role_dans_club(club_id) = 'admin');

revoke all on public.parametres_club from anon;
grant select, insert, update, delete on public.parametres_club to authenticated;

-- Pièces du dossier : code libre au lieu d'une liste fermée ---------------------
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.documents_licencie'::regclass and contype = 'c'
      and (conname = 'documents_licencie_type_check' or pg_get_constraintdef(oid) like '%certificat_medical%')
  loop
    execute format('alter table public.documents_licencie drop constraint %I', c.conname);
  end loop;
  alter table public.documents_licencie
    add constraint documents_licencie_type_check check (type ~ '^[a-z0-9_]{1,40}$');
end $$;

-- Modes de règlement : code libre au lieu d'une liste fermée -------------------
do $$
declare c record;
begin
  if to_regclass('public.paiements_licencie') is null then return; end if;
  for c in
    select conname from pg_constraint
    where conrelid = 'public.paiements_licencie'::regclass and contype = 'c'
      and (conname = 'paiements_licencie_mode_check' or pg_get_constraintdef(oid) like '%cheques_vacances%')
  loop
    execute format('alter table public.paiements_licencie drop constraint %I', c.conname);
  end loop;
  alter table public.paiements_licencie
    add constraint paiements_licencie_mode_check check (mode ~ '^[a-z0-9_]{1,40}$');
end $$;


-- >>>>>>>>>> migration-ufolep.sql <<<<<<<<<<
-- ============================================================================
-- Migration : compétition UFOLEP (GAF, programme technique 2026-2030)
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-licences.sql déjà exécuté (fonction role_dans_club).
--
-- Tables séparées de la compétition FFG (equipes, mouvements), qui ne change pas :
--   « ufolep_equipes »      : équipes UFOLEP d'une saison, avec leur évolution (A1 à C3) ;
--   « ufolep_engagements »  : une gymnaste engagée pour la saison, avec son équipe
--                             éventuelle, son engagement en individuel et son évolution ;
--   « ufolep_mouvements »   : un enchaînement par gymnaste, saison et agrès (JSON).
-- Lecture : membres du club. Modification : administrateur et entraîneur.
-- ============================================================================
create table if not exists public.ufolep_equipes (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  saison      text not null,
  nom         text not null,
  evolution   text not null default 'A1' check (evolution in ('A1','A2','B1','B2','B3','C1','C2','C3')),
  created_at  timestamptz not null default now()
);
create index if not exists ufolep_equipes_club_idx on public.ufolep_equipes (club_id, saison);

create table if not exists public.ufolep_engagements (
  club_id      uuid not null references public.clubs(id) on delete cascade,
  licencie_id  uuid not null references public.licencies(id) on delete cascade,
  saison       text not null,
  equipe_id    uuid references public.ufolep_equipes(id) on delete set null,
  individuel   boolean not null default false,
  evolution    text check (evolution is null or evolution in ('A1','A2','B1','B2','B3','C1','C2','C3')),
  updated_at   timestamptz not null default now(),
  primary key (licencie_id, saison)
);
create index if not exists ufolep_engagements_club_idx on public.ufolep_engagements (club_id, saison);

create table if not exists public.ufolep_mouvements (
  club_id      uuid not null references public.clubs(id) on delete cascade,
  licencie_id  uuid not null references public.licencies(id) on delete cascade,
  saison       text not null,
  agres        text not null check (agres in ('barres','poutre','sol','saut')),
  data         jsonb not null default '{}'::jsonb,
  updated_at   timestamptz not null default now(),
  primary key (licencie_id, saison, agres)
);
create index if not exists ufolep_mouvements_club_idx on public.ufolep_mouvements (club_id, saison);

alter table public.ufolep_equipes     enable row level security;
alter table public.ufolep_engagements enable row level security;
alter table public.ufolep_mouvements  enable row level security;

drop policy if exists ufolep_equipes_lecture      on public.ufolep_equipes;
drop policy if exists ufolep_equipes_ecriture     on public.ufolep_equipes;
drop policy if exists ufolep_engagements_lecture  on public.ufolep_engagements;
drop policy if exists ufolep_engagements_ecriture on public.ufolep_engagements;
drop policy if exists ufolep_mouvements_lecture   on public.ufolep_mouvements;
drop policy if exists ufolep_mouvements_ecriture  on public.ufolep_mouvements;

create policy ufolep_equipes_lecture on public.ufolep_equipes
  for select to authenticated using (public.role_dans_club(club_id) is not null);
create policy ufolep_equipes_ecriture on public.ufolep_equipes
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (public.role_dans_club(club_id) in ('admin', 'entraineur'));

create policy ufolep_engagements_lecture on public.ufolep_engagements
  for select to authenticated using (public.role_dans_club(club_id) is not null);
create policy ufolep_engagements_ecriture on public.ufolep_engagements
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
    and (equipe_id is null or club_id = (select e.club_id from public.ufolep_equipes e where e.id = equipe_id))
  );

create policy ufolep_mouvements_lecture on public.ufolep_mouvements
  for select to authenticated using (public.role_dans_club(club_id) is not null);
create policy ufolep_mouvements_ecriture on public.ufolep_mouvements
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

revoke all on public.ufolep_equipes, public.ufolep_engagements, public.ufolep_mouvements from anon;
grant select, insert, update, delete on public.ufolep_equipes, public.ufolep_engagements, public.ufolep_mouvements to authenticated;


-- >>>>>>>>>> migration-competitions.sql <<<<<<<<<<
-- ============================================================================
-- Migration : résultats des compétitions (FFG et UFOLEP)
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-licences.sql déjà exécuté (fonction role_dans_club).
--
--   « competitions »             : une compétition d'une saison (fédération, nom, date, lieu, niveau) ;
--   « competition_resultats »    : les notes d'une gymnaste (D / E / pénalités par agrès), son total,
--                                  sa catégorie et son classement (rang sur nombre de classées) ;
--   « competition_equipes »      : le total et le classement d'une équipe du club.
-- Lecture : membres du club. Modification : administrateur et entraîneur.
-- ============================================================================
create table if not exists public.competitions (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  saison      text not null,
  federation  text not null check (federation in ('FFG','UFOLEP')),
  nom         text not null,
  date_comp   date,
  lieu        text,
  niveau      text,
  created_at  timestamptz not null default now()
);
create index if not exists competitions_club_idx on public.competitions (club_id, saison, federation);

create table if not exists public.competition_resultats (
  competition_id uuid not null references public.competitions(id) on delete cascade,
  licencie_id    uuid not null references public.licencies(id) on delete cascade,
  club_id        uuid not null references public.clubs(id) on delete cascade,
  categorie      text,
  equipe         text,
  notes          jsonb not null default '{}'::jsonb,
  total          numeric(6,3),
  rang           integer check (rang is null or rang > 0),
  nb_classes     integer check (nb_classes is null or nb_classes > 0),
  updated_at     timestamptz not null default now(),
  primary key (competition_id, licencie_id)
);
create index if not exists competition_resultats_gym_idx on public.competition_resultats (licencie_id);

create table if not exists public.competition_equipes (
  competition_id uuid not null references public.competitions(id) on delete cascade,
  club_id        uuid not null references public.clubs(id) on delete cascade,
  equipe_ref     text not null,
  nom            text not null,
  categorie      text,
  total          numeric(7,3),
  rang           integer check (rang is null or rang > 0),
  nb_classes     integer check (nb_classes is null or nb_classes > 0),
  updated_at     timestamptz not null default now(),
  primary key (competition_id, equipe_ref)
);

alter table public.competitions          enable row level security;
alter table public.competition_resultats enable row level security;
alter table public.competition_equipes   enable row level security;

drop policy if exists competitions_lecture   on public.competitions;
drop policy if exists competitions_ecriture  on public.competitions;
drop policy if exists comp_resultats_lecture  on public.competition_resultats;
drop policy if exists comp_resultats_ecriture on public.competition_resultats;
drop policy if exists comp_equipes_lecture    on public.competition_equipes;
drop policy if exists comp_equipes_ecriture   on public.competition_equipes;

create policy competitions_lecture on public.competitions
  for select to authenticated using (public.role_dans_club(club_id) is not null);
create policy competitions_ecriture on public.competitions
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (public.role_dans_club(club_id) in ('admin', 'entraineur'));

create policy comp_resultats_lecture on public.competition_resultats
  for select to authenticated using (public.role_dans_club(club_id) is not null);
create policy comp_resultats_ecriture on public.competition_resultats
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select c.club_id from public.competitions c where c.id = competition_id)
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

create policy comp_equipes_lecture on public.competition_equipes
  for select to authenticated using (public.role_dans_club(club_id) is not null);
create policy comp_equipes_ecriture on public.competition_equipes
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select c.club_id from public.competitions c where c.id = competition_id)
  );

revoke all on public.competitions, public.competition_resultats, public.competition_equipes from anon;
grant select, insert, update, delete on public.competitions, public.competition_resultats, public.competition_equipes to authenticated;

-- ===== migration-formule.sql =====
-- Résultats de compétitions : formule individuelle ou par équipe (FFG)
-- + catégorie équipe Fédéral A 10-15 ans (règlement technique FFGym 2026-2027).
-- Relançable sans risque. Aucune donnée supprimée.

alter table public.competitions add column if not exists formule text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'competitions_formule_check') then
    alter table public.competitions add constraint competitions_formule_check check (formule is null or formule in ('indiv','equipe'));
  end if;
end $$;

-- 10-15 ans ajouté ; 12-15 ans (saison 2025-2026) reste accepté pour les anciennes équipes
do $$ begin
  if to_regclass('public.equipes') is not null then
    alter table public.equipes drop constraint if exists equipes_categorie_check;
    alter table public.equipes add constraint equipes_categorie_check check (categorie is null or categorie in ('10+','14+','10-15','12-15','10-13','10-11'));
  end if;
end $$;

-- ===== migration-qualif.sql =====
-- Résultats de compétitions : qualification pour l'étape suivante (bouton « Q »)
-- Relançable sans risque. Aucune donnée supprimée.
alter table public.competition_resultats add column if not exists qualifie boolean not null default false;
alter table public.competition_equipes  add column if not exists qualifie boolean not null default false;

-- ===== migration-covoiturage.sql =====
-- ============================================================================
-- Migration : présents et covoiturage pour les entraînements délocalisés
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-presences.sql, migration-creneaux.sql, migration-seances.sql
--             et migration-lieux.sql déjà exécutés.
--
-- Pour une séance (créneau + date), le club ouvre un « covoiturage » : un lien
-- secret est créé. Les parents l'ouvrent SANS compte et peuvent uniquement :
--   - dire si leur enfant sera présent(e), et s'il lui faut une place en voiture ;
--   - proposer une voiture (conducteur, places, lieu et heure de rendez-vous) ;
--   - réserver ou libérer une place dans une voiture.
--
-- Tables (aucune table existante n'est modifiée) :
--   covoit_sorties   : une séance ouverte au covoiturage, avec son lien secret ;
--   covoit_reponses  : présent(e) / absent(e) et besoin d'une place, par gym ;
--   covoit_voitures  : voitures proposées ;
--   covoit_passagers : qui monte dans quelle voiture (aller, retour).
--
-- Accès :
--   - admin et entraîneur : lecture et écriture ;
--   - trésorier : lecture seule ;
--   - personne non connectée : AUCUN accès aux tables. Elle passe uniquement par
--     les fonctions covoit_public_*, qui exigent le lien secret de la séance et
--     ne montrent que le prénom et l'initiale du nom des gyms du groupe.
-- ============================================================================

-- 1) Tables --------------------------------------------------------------------
create table if not exists public.covoit_sorties (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  groupe_id   uuid not null references public.groupes_entrainement(id) on delete cascade,
  creneau_id  uuid not null references public.groupe_creneaux(id) on delete cascade,
  date        date not null,
  token       text not null unique
              default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  ouvert      boolean not null default true,
  note        text check (note is null or char_length(note) <= 500),
  created_at  timestamptz not null default now(),
  unique (creneau_id, date)
);
create index if not exists covoit_sorties_club_idx on public.covoit_sorties (club_id);

create table if not exists public.covoit_reponses (
  sortie_id     uuid not null references public.covoit_sorties(id) on delete cascade,
  licencie_id   uuid not null references public.licencies(id) on delete cascade,
  club_id       uuid not null references public.clubs(id) on delete cascade,
  statut        text not null check (statut in ('present', 'absent')),
  besoin_aller  boolean not null default false,   -- il lui faut une place à l'aller
  besoin_retour boolean not null default false,   -- il lui faut une place au retour
  commentaire   text check (commentaire is null or char_length(commentaire) <= 300),
  par           text not null default 'parent' check (par in ('parent', 'club')),
  updated_at    timestamptz not null default now(),
  primary key (sortie_id, licencie_id)
);
create index if not exists covoit_reponses_club_idx on public.covoit_reponses (club_id);

create table if not exists public.covoit_voitures (
  id          uuid primary key default gen_random_uuid(),
  sortie_id   uuid not null references public.covoit_sorties(id) on delete cascade,
  club_id     uuid not null references public.clubs(id) on delete cascade,
  conducteur  text not null check (char_length(conducteur) between 1 and 60),
  telephone   text check (telephone is null or char_length(telephone) <= 30),
  places      smallint not null check (places between 1 and 8),   -- places offertes aux autres gyms
  sens        text not null default 'aller_retour' check (sens in ('aller_retour', 'aller', 'retour')),
  rdv_lieu    text check (rdv_lieu is null or char_length(rdv_lieu) <= 120),
  rdv_heure   time,
  note        text check (note is null or char_length(note) <= 300),
  cle         text not null default replace(gen_random_uuid()::text, '-', ''),  -- clé du parent qui a proposé la voiture
  created_at  timestamptz not null default now()
);
create index if not exists covoit_voitures_sortie_idx on public.covoit_voitures (sortie_id);
create index if not exists covoit_voitures_club_idx on public.covoit_voitures (club_id);

create table if not exists public.covoit_passagers (
  voiture_id  uuid not null references public.covoit_voitures(id) on delete cascade,
  licencie_id uuid not null references public.licencies(id) on delete cascade,
  sortie_id   uuid not null references public.covoit_sorties(id) on delete cascade,
  club_id     uuid not null references public.clubs(id) on delete cascade,
  aller       boolean not null default false,
  retour      boolean not null default false,
  created_at  timestamptz not null default now(),
  primary key (voiture_id, licencie_id),
  check (aller or retour)
);
create index if not exists covoit_passagers_sortie_idx on public.covoit_passagers (sortie_id);
create index if not exists covoit_passagers_club_idx on public.covoit_passagers (club_id);

-- 2) Cohérence d'une place : gym du groupe, sens de la voiture, places restantes,
--    une seule voiture par gym et par sens. Vaut pour le club comme pour les parents.
create or replace function public.covoit_passager_verif()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v public.covoit_voitures%rowtype; s public.covoit_sorties%rowtype; n int;
begin
  select * into v from public.covoit_voitures where id = new.voiture_id for update;
  if not found then raise exception 'Voiture introuvable'; end if;
  select * into s from public.covoit_sorties where id = v.sortie_id;
  new.sortie_id := v.sortie_id;
  new.club_id := v.club_id;
  if not exists (select 1 from public.groupe_licencies gl
                 where gl.groupe_id = s.groupe_id and gl.licencie_id = new.licencie_id) then
    raise exception 'Cette gym ne fait pas partie du groupe';
  end if;
  if (new.aller and v.sens = 'retour') or (new.retour and v.sens = 'aller') then
    raise exception 'Cette voiture ne fait pas ce trajet';
  end if;
  if new.aller then
    select count(*) into n from public.covoit_passagers p
      where p.voiture_id = new.voiture_id and p.aller and p.licencie_id <> new.licencie_id;
    if n >= v.places then raise exception 'Plus de place à l''aller dans cette voiture'; end if;
    if exists (select 1 from public.covoit_passagers p
               where p.sortie_id = v.sortie_id and p.licencie_id = new.licencie_id
                 and p.aller and p.voiture_id <> new.voiture_id) then
      raise exception 'Cette gym a déjà une place à l''aller dans une autre voiture';
    end if;
  end if;
  if new.retour then
    select count(*) into n from public.covoit_passagers p
      where p.voiture_id = new.voiture_id and p.retour and p.licencie_id <> new.licencie_id;
    if n >= v.places then raise exception 'Plus de place au retour dans cette voiture'; end if;
    if exists (select 1 from public.covoit_passagers p
               where p.sortie_id = v.sortie_id and p.licencie_id = new.licencie_id
                 and p.retour and p.voiture_id <> new.voiture_id) then
      raise exception 'Cette gym a déjà une place au retour dans une autre voiture';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.covoit_passager_verif() from public, anon, authenticated;

drop trigger if exists covoit_passagers_verif on public.covoit_passagers;
create trigger covoit_passagers_verif
  before insert or update on public.covoit_passagers
  for each row execute function public.covoit_passager_verif();

-- Une voiture ne peut pas être réduite ou changer de sens si des gyms y ont déjà une place.
create or replace function public.covoit_voiture_verif()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare na int; nr int;
begin
  select count(*) filter (where aller), count(*) filter (where retour) into na, nr
    from public.covoit_passagers where voiture_id = new.id;
  if na > new.places or nr > new.places then
    raise exception 'Des gyms occupent déjà plus de places que ce nombre : retire-les d''abord';
  end if;
  if (new.sens = 'retour' and na > 0) or (new.sens = 'aller' and nr > 0) then
    raise exception 'Des gyms ont déjà une place sur le trajet supprimé : retire-les d''abord';
  end if;
  return new;
end $$;
revoke all on function public.covoit_voiture_verif() from public, anon, authenticated;

drop trigger if exists covoit_voitures_verif on public.covoit_voitures;
create trigger covoit_voitures_verif
  before update on public.covoit_voitures
  for each row execute function public.covoit_voiture_verif();

-- 3) Règles d'accès (connectés uniquement) --------------------------------------
alter table public.covoit_sorties   enable row level security;
alter table public.covoit_reponses  enable row level security;
alter table public.covoit_voitures  enable row level security;
alter table public.covoit_passagers enable row level security;

drop policy if exists covoit_sorties_lecture  on public.covoit_sorties;
drop policy if exists covoit_sorties_ecriture on public.covoit_sorties;
create policy covoit_sorties_lecture on public.covoit_sorties
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy covoit_sorties_ecriture on public.covoit_sorties
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
    and groupe_id = (select c.groupe_id from public.groupe_creneaux c where c.id = creneau_id)
  );

drop policy if exists covoit_reponses_lecture  on public.covoit_reponses;
drop policy if exists covoit_reponses_ecriture on public.covoit_reponses;
create policy covoit_reponses_lecture on public.covoit_reponses
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy covoit_reponses_ecriture on public.covoit_reponses
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select s.club_id from public.covoit_sorties s where s.id = sortie_id)
    and exists (select 1 from public.covoit_sorties s
                join public.groupe_licencies gl on gl.groupe_id = s.groupe_id
                where s.id = sortie_id and gl.licencie_id = covoit_reponses.licencie_id)
  );

drop policy if exists covoit_voitures_lecture  on public.covoit_voitures;
drop policy if exists covoit_voitures_ecriture on public.covoit_voitures;
create policy covoit_voitures_lecture on public.covoit_voitures
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy covoit_voitures_ecriture on public.covoit_voitures
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select s.club_id from public.covoit_sorties s where s.id = sortie_id)
  );

drop policy if exists covoit_passagers_lecture  on public.covoit_passagers;
drop policy if exists covoit_passagers_ecriture on public.covoit_passagers;
create policy covoit_passagers_lecture on public.covoit_passagers
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy covoit_passagers_ecriture on public.covoit_passagers
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (public.role_dans_club(club_id) in ('admin', 'entraineur'));

revoke all on public.covoit_sorties, public.covoit_reponses, public.covoit_voitures, public.covoit_passagers from anon;
revoke all on public.covoit_sorties, public.covoit_reponses, public.covoit_voitures, public.covoit_passagers from authenticated;
grant select, insert, update, delete
  on public.covoit_sorties, public.covoit_reponses, public.covoit_voitures, public.covoit_passagers to authenticated;

-- 4) Fonctions pour les parents (sans compte, avec le lien secret) ----------------
-- Séance correspondant à un lien ; p_ecriture : refuse si les réponses sont fermées,
-- la séance passée ou annulée.
create or replace function public.covoit_sortie_du_lien(p_token text, p_ecriture boolean)
returns public.covoit_sorties
language plpgsql
stable
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype;
begin
  if p_token is null or char_length(p_token) < 32 then raise exception 'Lien invalide'; end if;
  select * into s from public.covoit_sorties where token = p_token;
  if not found then raise exception 'Lien invalide ou supprimé'; end if;
  if p_ecriture then
    if not s.ouvert then raise exception 'Les réponses sont fermées : contacte l''entraîneur'; end if;
    if s.date < (now() at time zone 'Europe/Paris')::date then raise exception 'Cette séance est passée'; end if;
    if exists (select 1 from public.seances_annulees a where a.creneau_id = s.creneau_id and a.date = s.date) then
      raise exception 'Cette séance est annulée';
    end if;
  end if;
  return s;
end $$;
revoke all on function public.covoit_sortie_du_lien(text, boolean) from public, anon, authenticated;

-- Tout ce que la page des parents affiche.
create or replace function public.covoit_public_voir(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype; r jsonb;
begin
  s := public.covoit_sortie_du_lien(p_token, false);
  select jsonb_build_object(
    'club', cl.nom,
    'groupe', g.nom,
    'intitule', case when c.type = 'ponctuel' then c.libelle end,
    'date', s.date,
    'debut', to_char(c.heure_debut, 'HH24:MI'),
    'fin', to_char(c.heure_fin, 'HH24:MI'),
    'lieu', coalesce(x.lieu, c.lieu, g.lieu),
    'note', s.note,
    'annulee', exists (select 1 from public.seances_annulees a where a.creneau_id = s.creneau_id and a.date = s.date),
    'passee', s.date < (now() at time zone 'Europe/Paris')::date,
    'ouvert', s.ouvert,
    'gyms', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id,
               'nom', trim(coalesce(l.prenom, '') || ' ' || coalesce(upper(left(l.nom, 1)) || '.', '')))
             order by lower(l.prenom), lower(l.nom))
      from public.groupe_licencies gl join public.licencies l on l.id = gl.licencie_id
      where gl.groupe_id = s.groupe_id), '[]'::jsonb),
    'reponses', coalesce((
      select jsonb_agg(jsonb_build_object('l', rp.licencie_id, 's', rp.statut, 'a', rp.besoin_aller,
               'r', rp.besoin_retour, 'c', rp.commentaire))
      from public.covoit_reponses rp where rp.sortie_id = s.id), '[]'::jsonb),
    'voitures', coalesce((
      select jsonb_agg(jsonb_build_object('id', v.id, 'conducteur', v.conducteur, 'telephone', v.telephone,
               'places', v.places, 'sens', v.sens, 'rdv_lieu', v.rdv_lieu,
               'rdv_heure', to_char(v.rdv_heure, 'HH24:MI'), 'note', v.note,
               'passagers', coalesce((
                 select jsonb_agg(jsonb_build_object('l', p.licencie_id, 'a', p.aller, 'r', p.retour))
                 from public.covoit_passagers p where p.voiture_id = v.id), '[]'::jsonb))
             order by v.created_at)
      from public.covoit_voitures v where v.sortie_id = s.id), '[]'::jsonb)
  ) into r
  from public.clubs cl
  join public.groupes_entrainement g on g.id = s.groupe_id
  join public.groupe_creneaux c on c.id = s.creneau_id
  left join public.seances_exceptions x on x.creneau_id = s.creneau_id and x.date = s.date
  where cl.id = s.club_id;
  return r;
end $$;

-- Réponse d'une famille : présent(e) ou absent(e), besoin d'une place à l'aller / au retour.
create or replace function public.covoit_public_repondre(
  p_token text, p_licencie uuid, p_statut text, p_aller boolean, p_retour boolean, p_commentaire text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype; a boolean; r boolean;
begin
  s := public.covoit_sortie_du_lien(p_token, true);
  if p_statut is null or p_statut not in ('present', 'absent') then raise exception 'Réponse invalide'; end if;
  if not exists (select 1 from public.groupe_licencies gl
                 where gl.groupe_id = s.groupe_id and gl.licencie_id = p_licencie) then
    raise exception 'Cette gym ne fait pas partie du groupe';
  end if;
  a := p_statut = 'present' and coalesce(p_aller, false);
  r := p_statut = 'present' and coalesce(p_retour, false);
  insert into public.covoit_reponses (sortie_id, licencie_id, club_id, statut, besoin_aller, besoin_retour, commentaire, par)
  values (s.id, p_licencie, s.club_id, p_statut, a, r, nullif(left(trim(coalesce(p_commentaire, '')), 300), ''), 'parent')
  on conflict (sortie_id, licencie_id) do update
    set statut = excluded.statut, besoin_aller = excluded.besoin_aller, besoin_retour = excluded.besoin_retour,
        commentaire = excluded.commentaire, par = 'parent', updated_at = now();
  -- libère les places devenues inutiles
  if not a then update public.covoit_passagers set aller = false
    where sortie_id = s.id and licencie_id = p_licencie and aller and retour; end if;
  if not r then update public.covoit_passagers set retour = false
    where sortie_id = s.id and licencie_id = p_licencie and aller and retour; end if;
  delete from public.covoit_passagers p
    where p.sortie_id = s.id and p.licencie_id = p_licencie
      and not ((p.aller and a) or (p.retour and r));
  return public.covoit_public_voir(p_token);
end $$;

-- Proposer une voiture (p_id vide) ou modifier la sienne (p_id + p_cle reçue à la création).
create or replace function public.covoit_public_voiture(
  p_token text, p_id uuid, p_cle text, p_conducteur text, p_telephone text, p_places int,
  p_sens text, p_rdv_lieu text, p_rdv_heure text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype; v_id uuid; v_cle text; h time;
  nom text := left(trim(coalesce(p_conducteur, '')), 60);
begin
  s := public.covoit_sortie_du_lien(p_token, true);
  if nom = '' then raise exception 'Indique le nom du conducteur'; end if;
  if p_places is null or p_places < 1 or p_places > 8 then raise exception 'Nombre de places entre 1 et 8'; end if;
  if p_sens is null or p_sens not in ('aller_retour', 'aller', 'retour') then raise exception 'Trajet invalide'; end if;
  if coalesce(p_rdv_heure, '') ~ '^\d{1,2}:\d{2}$' then h := p_rdv_heure::time; end if;
  if p_id is null then
    if (select count(*) from public.covoit_voitures where sortie_id = s.id) >= 20 then
      raise exception 'Trop de voitures pour cette séance';
    end if;
    insert into public.covoit_voitures (sortie_id, club_id, conducteur, telephone, places, sens, rdv_lieu, rdv_heure, note)
    values (s.id, s.club_id, nom, nullif(left(trim(coalesce(p_telephone, '')), 30), ''), p_places, p_sens,
            nullif(left(trim(coalesce(p_rdv_lieu, '')), 120), ''), h, nullif(left(trim(coalesce(p_note, '')), 300), ''))
    returning id, cle into v_id, v_cle;
  else
    update public.covoit_voitures
      set conducteur = nom, telephone = nullif(left(trim(coalesce(p_telephone, '')), 30), ''), places = p_places,
          sens = p_sens, rdv_lieu = nullif(left(trim(coalesce(p_rdv_lieu, '')), 120), ''), rdv_heure = h,
          note = nullif(left(trim(coalesce(p_note, '')), 300), '')
      where id = p_id and sortie_id = s.id and cle = p_cle
      returning id, cle into v_id, v_cle;
    if v_id is null then raise exception 'Seule la personne qui a proposé cette voiture (ou l''entraîneur) peut la modifier'; end if;
  end if;
  return jsonb_build_object('id', v_id, 'cle', v_cle, 'etat', public.covoit_public_voir(p_token));
end $$;

-- Retirer sa voiture.
create or replace function public.covoit_public_voiture_suppr(p_token text, p_id uuid, p_cle text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype; n int;
begin
  s := public.covoit_sortie_du_lien(p_token, true);
  delete from public.covoit_voitures where id = p_id and sortie_id = s.id and cle = p_cle;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Seule la personne qui a proposé cette voiture (ou l''entraîneur) peut la retirer'; end if;
  return public.covoit_public_voir(p_token);
end $$;

-- Réserver (p_aller / p_retour) ou libérer (les deux à faux) une place pour une gym.
create or replace function public.covoit_public_place(
  p_token text, p_voiture uuid, p_licencie uuid, p_aller boolean, p_retour boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype; a boolean := coalesce(p_aller, false); r boolean := coalesce(p_retour, false);
begin
  s := public.covoit_sortie_du_lien(p_token, true);
  if not exists (select 1 from public.covoit_voitures v where v.id = p_voiture and v.sortie_id = s.id) then
    raise exception 'Voiture introuvable';
  end if;
  if not exists (select 1 from public.groupe_licencies gl
                 where gl.groupe_id = s.groupe_id and gl.licencie_id = p_licencie) then
    raise exception 'Cette gym ne fait pas partie du groupe';
  end if;
  if not a and not r then
    delete from public.covoit_passagers where voiture_id = p_voiture and licencie_id = p_licencie;
    return public.covoit_public_voir(p_token);
  end if;
  -- quitte les autres voitures pour les trajets demandés
  if a then update public.covoit_passagers set aller = false
    where sortie_id = s.id and licencie_id = p_licencie and voiture_id <> p_voiture and aller and retour; end if;
  if r then update public.covoit_passagers set retour = false
    where sortie_id = s.id and licencie_id = p_licencie and voiture_id <> p_voiture and aller and retour; end if;
  delete from public.covoit_passagers p
    where p.sortie_id = s.id and p.licencie_id = p_licencie and p.voiture_id <> p_voiture
      and ((p.aller and a and not p.retour) or (p.retour and r and not p.aller) or (a and r));
  insert into public.covoit_passagers (voiture_id, licencie_id, sortie_id, club_id, aller, retour)
  values (p_voiture, p_licencie, s.id, s.club_id, a, r)
  on conflict (voiture_id, licencie_id) do update set aller = excluded.aller, retour = excluded.retour;
  -- la gym est donc présente et a besoin d'une place sur ces trajets
  insert into public.covoit_reponses (sortie_id, licencie_id, club_id, statut, besoin_aller, besoin_retour, par)
  values (s.id, p_licencie, s.club_id, 'present', a, r, 'parent')
  on conflict (sortie_id, licencie_id) do update
    set statut = 'present', besoin_aller = covoit_reponses.besoin_aller or excluded.besoin_aller,
        besoin_retour = covoit_reponses.besoin_retour or excluded.besoin_retour, updated_at = now();
  return public.covoit_public_voir(p_token);
end $$;

revoke all on function public.covoit_public_voir(text) from public;
revoke all on function public.covoit_public_repondre(text, uuid, text, boolean, boolean, text) from public;
revoke all on function public.covoit_public_voiture(text, uuid, text, text, text, int, text, text, text, text) from public;
revoke all on function public.covoit_public_voiture_suppr(text, uuid, text) from public;
revoke all on function public.covoit_public_place(text, uuid, uuid, boolean, boolean) from public;
grant execute on function public.covoit_public_voir(text) to anon, authenticated;
grant execute on function public.covoit_public_repondre(text, uuid, text, boolean, boolean, text) to anon, authenticated;
grant execute on function public.covoit_public_voiture(text, uuid, text, text, text, int, text, text, text, text) to anon, authenticated;
grant execute on function public.covoit_public_voiture_suppr(text, uuid, text) to anon, authenticated;
grant execute on function public.covoit_public_place(text, uuid, uuid, boolean, boolean) to anon, authenticated;
