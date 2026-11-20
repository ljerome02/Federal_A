-- Fichiers des adhérents (certificats médicaux, autorisations, fiches d'inscription…)
--   • espace de stockage PRIVÉ « documents-adherents » (10 Mo max par fichier, PDF et photos)
--   • table « fichiers_licencie » : la liste des fichiers de chaque adhérent
--   • accès réservé aux administrateurs et aux entraîneurs du club (comme documents_licencie)
-- Chemin d'un fichier : <club_id>/<licencie_id>/<type>/<horodatage>-<nom>
-- Relançable sans risque. Aucune donnée supprimée.

create table if not exists public.fichiers_licencie (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id)     on delete cascade,
  licencie_id uuid not null references public.licencies(id) on delete cascade,
  type        text not null check (type ~ '^[a-z0-9_]{1,40}$'),
  nom         text not null check (char_length(nom) between 1 and 200),
  chemin      text not null unique,
  taille      bigint not null default 0 check (taille >= 0),
  mime        text,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid()
);
create index if not exists fichiers_club_idx     on public.fichiers_licencie (club_id);
create index if not exists fichiers_licencie_idx on public.fichiers_licencie (licencie_id);

alter table public.fichiers_licencie enable row level security;
drop policy if exists fichiers_acces on public.fichiers_licencie;
create policy fichiers_acces on public.fichiers_licencie
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
    and chemin like club_id::text || '/' || licencie_id::text || '/%'
  );
revoke all on public.fichiers_licencie from anon;
grant select, insert, update, delete on public.fichiers_licencie to authenticated;

-- droit sur un chemin de fichier : admin ou entraîneur du club, et l'adhérent appartient bien au club
create or replace function public.fichier_droit(p text)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when split_part(p, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and split_part(p, '/', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then coalesce(public.role_dans_club(split_part(p, '/', 1)::uuid) in ('admin', 'entraineur'), false)
     and exists (select 1 from public.licencies l
                 where l.id = split_part(p, '/', 2)::uuid and l.club_id = split_part(p, '/', 1)::uuid)
    else false end
$$;
revoke all on function public.fichier_droit(text) from public, anon;
grant execute on function public.fichier_droit(text) to authenticated;

-- espace de stockage privé
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents-adherents', 'documents-adherents', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
                               allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists docs_adh_lecture     on storage.objects;
drop policy if exists docs_adh_ajout       on storage.objects;
drop policy if exists docs_adh_modif       on storage.objects;
drop policy if exists docs_adh_suppression on storage.objects;
create policy docs_adh_lecture on storage.objects for select to authenticated
  using (bucket_id = 'documents-adherents' and public.fichier_droit(name));
create policy docs_adh_ajout on storage.objects for insert to authenticated
  with check (bucket_id = 'documents-adherents' and public.fichier_droit(name));
create policy docs_adh_modif on storage.objects for update to authenticated
  using (bucket_id = 'documents-adherents' and public.fichier_droit(name))
  with check (bucket_id = 'documents-adherents' and public.fichier_droit(name));
create policy docs_adh_suppression on storage.objects for delete to authenticated
  using (bucket_id = 'documents-adherents' and public.fichier_droit(name));
