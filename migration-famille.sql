-- ============================================================================
-- Migration : liens de parenté entre adhérents (onglet « Famille » de la fiche)
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-licences.sql déjà exécuté.
--
-- Une ligne = « autre_id est le/la <lien> de licencie_id ».
-- L'application affiche le lien dans les deux fiches (parent ↔ enfant inversés,
-- frère ou sœur, cousin, conjoint… identiques dans les deux sens).
-- Lecture : tous les membres du club. Modification : administrateur et entraîneur.
-- ============================================================================
create table if not exists public.liens_familiaux (
  id           uuid primary key default gen_random_uuid(),
  club_id      uuid not null references public.clubs(id)     on delete cascade,
  licencie_id  uuid not null references public.licencies(id) on delete cascade,
  autre_id     uuid not null references public.licencies(id) on delete cascade,
  lien         text not null default 'fratrie'
               check (lien in ('fratrie', 'parent', 'enfant', 'cousin', 'conjoint', 'autre')),
  created_at   timestamptz not null default now(),
  check (licencie_id <> autre_id),
  unique (licencie_id, autre_id)
);
create index if not exists liens_familiaux_club_idx on public.liens_familiaux (club_id);

alter table public.liens_familiaux enable row level security;

drop policy if exists liens_familiaux_lecture  on public.liens_familiaux;
drop policy if exists liens_familiaux_ecriture on public.liens_familiaux;

create policy liens_familiaux_lecture on public.liens_familiaux
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);

create policy liens_familiaux_ecriture on public.liens_familiaux
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
    and club_id = (select l.club_id from public.licencies l where l.id = autre_id)
  );

revoke all on public.liens_familiaux from anon;
grant select, insert, update, delete on public.liens_familiaux to authenticated;
