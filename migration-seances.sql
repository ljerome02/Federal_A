-- ============================================================================
-- Migration : séances ponctuelles et séances annulées
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-creneaux.sql déjà exécuté.
--
-- 1. « groupe_creneaux » accepte un 3e type, 'ponctuel' : une séance à une date
--    précise (stage pendant les vacances, séance exceptionnelle…), colonne « date ».
--    Le lieu peut aussi être précisé pour les entraînements de la saison.
--    Colonne « libelle » : intitulé d'une séance ponctuelle (Stage, Fête du club…).
-- 2. « seances_annulees » : une séance prévue qui n'a pas lieu à une date donnée
--    (elle disparaît du planning et du pointage ce jour-là).
-- Lecture : membres du club. Modification : administrateur et entraîneur.
-- ============================================================================

-- 1) Séances ponctuelles
alter table public.groupe_creneaux add column if not exists date date;
alter table public.groupe_creneaux add column if not exists libelle text;

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
