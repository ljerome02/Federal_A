-- ============================================================================
-- Migration : documents d'une compétition (organigramme, convocation, plan d'accès…)
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-competitions.sql déjà exécuté.
--
-- « competition_documents » : un fichier PDF ou une photo (5 Mo maximum) rattaché à une
-- compétition. Le contenu est gardé dans la table (base64) : documents légers, pas d'espace
-- de stockage à gérer.
-- Lecture : membres du club. Ajout et suppression : administrateur et entraîneur.
-- ============================================================================
create table if not exists public.competition_documents (
  id             uuid primary key default gen_random_uuid(),
  competition_id uuid not null references public.competitions(id) on delete cascade,
  club_id        uuid not null references public.clubs(id) on delete cascade,
  nom            text not null check (char_length(nom) between 1 and 200),
  mime           text not null check (mime in ('application/pdf','image/jpeg','image/png','image/webp')),
  taille         integer not null check (taille between 1 and 5242880),
  contenu_b64    text not null check (char_length(contenu_b64) <= 7000000),
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid()
);
create index if not exists competition_documents_comp_idx on public.competition_documents (competition_id);

alter table public.competition_documents enable row level security;
drop policy if exists comp_docs_lecture  on public.competition_documents;
drop policy if exists comp_docs_ecriture on public.competition_documents;
create policy comp_docs_lecture on public.competition_documents
  for select to authenticated using (public.role_dans_club(club_id) is not null);
create policy comp_docs_ecriture on public.competition_documents
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select c.club_id from public.competitions c where c.id = competition_id)
  );

revoke all on public.competition_documents from anon;
grant select, insert, update, delete on public.competition_documents to authenticated;
