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
