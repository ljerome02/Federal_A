-- ============================================================================
-- Migration : module « Groupes et présences »
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
--
-- Crée trois nouvelles tables, aucune table existante n'est modifiée :
--   groupes_entrainement : un groupe = un créneau (jour, horaires, lieu) pour une saison ;
--   groupe_licencies     : quels licenciés font partie de quel groupe ;
--   presences_seances    : une ligne par licencié, groupe et date (présente,
--                          absente ou excusée). Pas de ligne = pas pointée.
--
-- Accès par rôle :
--   - admin et entraîneur : lecture et écriture (ils pointent les présences) ;
--   - trésorier : lecture seule ;
--   - toute personne hors du club ou non connectée : aucun accès.
-- ============================================================================

-- 0) Sécurité du script : s'arrêter proprement si un nom de table est déjà pris
--    par une table d'une autre structure (rien n'est alors modifié).
do $$
declare t text;
begin
  foreach t in array array['groupes_entrainement', 'groupe_licencies', 'presences_seances'] loop
    if exists (select 1 from information_schema.tables
               where table_schema = 'public' and table_name = t)
       and not exists (select 1 from information_schema.columns
                       where table_schema = 'public' and table_name = t and column_name = 'club_id') then
      raise exception 'La table % existe déjà avec une autre structure : script arrêté, rien n''a été modifié.', t;
    end if;
  end loop;
end $$;

-- 1) Rôle de la personne connectée dans un club (déjà créé par migration-licences.sql ;
--    recréé ici à l'identique pour que ce script fonctionne seul).
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

-- 2) Groupes (créneaux d'entraînement) ----------------------------------------
create table if not exists public.groupes_entrainement (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  saison      text not null,
  nom         text not null,
  jour        smallint check (jour between 1 and 7),   -- 1 = lundi … 7 = dimanche
  heure_debut time,
  heure_fin   time,
  lieu        text,
  created_at  timestamptz not null default now()
);
create index if not exists groupes_ent_club_idx on public.groupes_entrainement (club_id, saison);

-- 3) Membres des groupes ---------------------------------------------------------
create table if not exists public.groupe_licencies (
  groupe_id   uuid not null references public.groupes_entrainement(id) on delete cascade,
  licencie_id uuid not null references public.licencies(id)            on delete cascade,
  club_id     uuid not null references public.clubs(id)                on delete cascade,
  primary key (groupe_id, licencie_id)
);
create index if not exists groupe_lic_club_idx     on public.groupe_licencies (club_id);
create index if not exists groupe_lic_licencie_idx on public.groupe_licencies (licencie_id);

-- 4) Présences : une ligne par licencié, groupe et date -----------------------
create table if not exists public.presences_seances (
  groupe_id   uuid not null references public.groupes_entrainement(id) on delete cascade,
  licencie_id uuid not null references public.licencies(id)            on delete cascade,
  date        date not null,
  club_id     uuid not null references public.clubs(id)                on delete cascade,
  statut      text not null check (statut in ('present', 'absent', 'excuse')),
  updated_at  timestamptz not null default now(),
  primary key (groupe_id, licencie_id, date)
);
create index if not exists presences_club_date_idx on public.presences_seances (club_id, date);

-- 5) Sécurité par rôle -----------------------------------------------------------
alter table public.groupes_entrainement enable row level security;
alter table public.groupe_licencies     enable row level security;
alter table public.presences_seances    enable row level security;

drop policy if exists groupes_ent_lecture  on public.groupes_entrainement;
drop policy if exists groupes_ent_ecriture on public.groupes_entrainement;
create policy groupes_ent_lecture on public.groupes_entrainement
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy groupes_ent_ecriture on public.groupes_entrainement
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (public.role_dans_club(club_id) in ('admin', 'entraineur'));

drop policy if exists groupe_lic_lecture  on public.groupe_licencies;
drop policy if exists groupe_lic_ecriture on public.groupe_licencies;
create policy groupe_lic_lecture on public.groupe_licencies
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy groupe_lic_ecriture on public.groupe_licencies
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

drop policy if exists presences_lecture  on public.presences_seances;
drop policy if exists presences_ecriture on public.presences_seances;
create policy presences_lecture on public.presences_seances
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy presences_ecriture on public.presences_seances
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
  );

-- Aucun accès sans connexion.
revoke all on public.groupes_entrainement from anon;
revoke all on public.groupe_licencies     from anon;
revoke all on public.presences_seances    from anon;
grant select, insert, update, delete on public.groupes_entrainement to authenticated;
grant select, insert, update, delete on public.groupe_licencies     to authenticated;
grant select, insert, update, delete on public.presences_seances    to authenticated;
