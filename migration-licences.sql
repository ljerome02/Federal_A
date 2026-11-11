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
