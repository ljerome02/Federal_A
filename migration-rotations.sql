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
