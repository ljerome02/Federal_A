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
