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

revoke all on function public.role_dans_club(uuid) from public;
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

revoke all on function public.role_dans_club(uuid) from public;
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
-- 2. « seances_annulees » : une séance prévue qui n'a pas lieu à une date donnée
--    (elle disparaît du planning et du pointage ce jour-là).
-- Lecture : membres du club. Modification : administrateur et entraîneur.
-- ============================================================================

-- 1) Séances ponctuelles
alter table public.groupe_creneaux add column if not exists date date;

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
