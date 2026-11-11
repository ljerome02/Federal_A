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
