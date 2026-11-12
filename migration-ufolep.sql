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
