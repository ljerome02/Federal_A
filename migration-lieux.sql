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
