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
