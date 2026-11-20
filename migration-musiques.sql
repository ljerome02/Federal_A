-- Musiques des gymnastes (musique de sol)
--   • espace de stockage PRIVÉ « musiques » (15 Mo max par fichier, formats audio)
--   • table « musiques_licencie » : versions de chaque gym, dont une « principale »
--   • écoute : tous les membres connectés du club ; ajout / suppression : administrateurs et entraîneurs
-- Chemin d'un fichier : <club_id>/<licencie_id>/<horodatage>-<nom>
-- Relançable sans risque. Aucune donnée supprimée.

create table if not exists public.musiques_licencie (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id)     on delete cascade,
  licencie_id uuid not null references public.licencies(id) on delete cascade,
  agres       text not null default 'sol' check (agres ~ '^[a-z_]{1,20}$'),
  nom         text not null check (char_length(nom) between 1 and 200),
  version     text check (version is null or char_length(version) <= 120),
  chemin      text not null unique,
  taille      bigint not null default 0 check (taille >= 0),
  mime        text,
  duree       numeric(6,1) check (duree is null or duree >= 0),
  principale  boolean not null default false,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid()
);
create index if not exists musiques_club_idx     on public.musiques_licencie (club_id);
create index if not exists musiques_licencie_idx on public.musiques_licencie (licencie_id);

alter table public.musiques_licencie enable row level security;
drop policy if exists musiques_lecture  on public.musiques_licencie;
drop policy if exists musiques_ecriture on public.musiques_licencie;
create policy musiques_lecture on public.musiques_licencie
  for select to authenticated using (public.role_dans_club(club_id) is not null);
create policy musiques_ecriture on public.musiques_licencie
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select l.club_id from public.licencies l where l.id = licencie_id)
    and chemin like club_id::text || '/' || licencie_id::text || '/%'
  );
revoke all on public.musiques_licencie from anon;
grant select, insert, update, delete on public.musiques_licencie to authenticated;

-- droit sur un chemin : membre du club (écoute) ou admin / entraîneur (écriture), adhérent du club
create or replace function public.musique_droit(p text, ecriture boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when split_part(p, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and split_part(p, '/', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then coalesce(case when ecriture
                       then public.role_dans_club(split_part(p, '/', 1)::uuid) in ('admin', 'entraineur')
                       else public.role_dans_club(split_part(p, '/', 1)::uuid) is not null end, false)
     and exists (select 1 from public.licencies l
                 where l.id = split_part(p, '/', 2)::uuid and l.club_id = split_part(p, '/', 1)::uuid)
    else false end
$$;
revoke all on function public.musique_droit(text, boolean) from public, anon;
grant execute on function public.musique_droit(text, boolean) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('musiques', 'musiques', false, 15728640,
        array['audio/mpeg', 'audio/mp3', 'audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/wav', 'audio/x-wav', 'audio/ogg', 'audio/webm', 'video/mp4', 'video/mpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
                               allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists musiques_obj_lecture     on storage.objects;
drop policy if exists musiques_obj_ajout       on storage.objects;
drop policy if exists musiques_obj_modif       on storage.objects;
drop policy if exists musiques_obj_suppression on storage.objects;
create policy musiques_obj_lecture on storage.objects for select to authenticated
  using (bucket_id = 'musiques' and public.musique_droit(name, false));
create policy musiques_obj_ajout on storage.objects for insert to authenticated
  with check (bucket_id = 'musiques' and public.musique_droit(name, true));
create policy musiques_obj_modif on storage.objects for update to authenticated
  using (bucket_id = 'musiques' and public.musique_droit(name, true))
  with check (bucket_id = 'musiques' and public.musique_droit(name, true));
create policy musiques_obj_suppression on storage.objects for delete to authenticated
  using (bucket_id = 'musiques' and public.musique_droit(name, true));

-- fédération de la musique (durées différentes en FFG et en UFOLEP) ; « FFG+UFOLEP » = même musique pour les deux
alter table public.musiques_licencie add column if not exists federation text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'musiques_federation_check') then
    alter table public.musiques_licencie add constraint musiques_federation_check
      check (federation is null or federation in ('FFG', 'UFOLEP', 'FFG+UFOLEP'));
  end if;
end $$;
