-- ============================================================================
-- Migration : présents et covoiturage pour les entraînements délocalisés
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-presences.sql, migration-creneaux.sql, migration-seances.sql
--             et migration-lieux.sql déjà exécutés.
--
-- Pour une séance (créneau + date), le club ouvre un « covoiturage » : un lien
-- secret est créé. Les parents l'ouvrent SANS compte et peuvent uniquement :
--   - dire si leur enfant sera présent(e), et s'il lui faut une place en voiture ;
--   - proposer une voiture (conducteur, places, lieu et heure de rendez-vous) ;
--   - réserver ou libérer une place dans une voiture.
--
-- Tables (aucune table existante n'est modifiée) :
--   covoit_sorties   : une séance ouverte au covoiturage, avec son lien secret ;
--   covoit_reponses  : présent(e) / absent(e) et besoin d'une place, par gym ;
--   covoit_voitures  : voitures proposées ;
--   covoit_passagers : qui monte dans quelle voiture (aller, retour).
--
-- Accès :
--   - admin et entraîneur : lecture et écriture ;
--   - trésorier : lecture seule ;
--   - personne non connectée : AUCUN accès aux tables. Elle passe uniquement par
--     les fonctions covoit_public_*, qui exigent le lien secret de la séance et
--     ne montrent que le prénom et l'initiale du nom des gyms du groupe.
-- ============================================================================

-- 1) Tables --------------------------------------------------------------------
create table if not exists public.covoit_sorties (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  groupe_id   uuid not null references public.groupes_entrainement(id) on delete cascade,
  creneau_id  uuid not null references public.groupe_creneaux(id) on delete cascade,
  date        date not null,
  token       text not null unique
              default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  ouvert      boolean not null default true,
  note        text check (note is null or char_length(note) <= 500),
  created_at  timestamptz not null default now(),
  unique (creneau_id, date)
);
create index if not exists covoit_sorties_club_idx on public.covoit_sorties (club_id);

create table if not exists public.covoit_reponses (
  sortie_id     uuid not null references public.covoit_sorties(id) on delete cascade,
  licencie_id   uuid not null references public.licencies(id) on delete cascade,
  club_id       uuid not null references public.clubs(id) on delete cascade,
  statut        text not null check (statut in ('present', 'absent')),
  besoin_aller  boolean not null default false,   -- il lui faut une place à l'aller
  besoin_retour boolean not null default false,   -- il lui faut une place au retour
  commentaire   text check (commentaire is null or char_length(commentaire) <= 300),
  par           text not null default 'parent' check (par in ('parent', 'club')),
  updated_at    timestamptz not null default now(),
  primary key (sortie_id, licencie_id)
);
create index if not exists covoit_reponses_club_idx on public.covoit_reponses (club_id);

create table if not exists public.covoit_voitures (
  id          uuid primary key default gen_random_uuid(),
  sortie_id   uuid not null references public.covoit_sorties(id) on delete cascade,
  club_id     uuid not null references public.clubs(id) on delete cascade,
  conducteur  text not null check (char_length(conducteur) between 1 and 60),
  telephone   text check (telephone is null or char_length(telephone) <= 30),
  places      smallint not null check (places between 1 and 8),   -- places offertes aux autres gyms
  sens        text not null default 'aller_retour' check (sens in ('aller_retour', 'aller', 'retour')),
  rdv_lieu    text check (rdv_lieu is null or char_length(rdv_lieu) <= 120),
  rdv_heure   time,
  note        text check (note is null or char_length(note) <= 300),
  cle         text not null default replace(gen_random_uuid()::text, '-', ''),  -- clé du parent qui a proposé la voiture
  created_at  timestamptz not null default now()
);
create index if not exists covoit_voitures_sortie_idx on public.covoit_voitures (sortie_id);
create index if not exists covoit_voitures_club_idx on public.covoit_voitures (club_id);

create table if not exists public.covoit_passagers (
  voiture_id  uuid not null references public.covoit_voitures(id) on delete cascade,
  licencie_id uuid not null references public.licencies(id) on delete cascade,
  sortie_id   uuid not null references public.covoit_sorties(id) on delete cascade,
  club_id     uuid not null references public.clubs(id) on delete cascade,
  aller       boolean not null default false,
  retour      boolean not null default false,
  created_at  timestamptz not null default now(),
  primary key (voiture_id, licencie_id),
  check (aller or retour)
);
create index if not exists covoit_passagers_sortie_idx on public.covoit_passagers (sortie_id);
create index if not exists covoit_passagers_club_idx on public.covoit_passagers (club_id);

-- 2) Cohérence d'une place : gym du groupe, sens de la voiture, places restantes,
--    une seule voiture par gym et par sens. Vaut pour le club comme pour les parents.
create or replace function public.covoit_passager_verif()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v public.covoit_voitures%rowtype; s public.covoit_sorties%rowtype; n int;
begin
  select * into v from public.covoit_voitures where id = new.voiture_id for update;
  if not found then raise exception 'Voiture introuvable'; end if;
  select * into s from public.covoit_sorties where id = v.sortie_id;
  new.sortie_id := v.sortie_id;
  new.club_id := v.club_id;
  if not exists (select 1 from public.groupe_licencies gl
                 where gl.groupe_id = s.groupe_id and gl.licencie_id = new.licencie_id) then
    raise exception 'Cette gym ne fait pas partie du groupe';
  end if;
  if (new.aller and v.sens = 'retour') or (new.retour and v.sens = 'aller') then
    raise exception 'Cette voiture ne fait pas ce trajet';
  end if;
  if new.aller then
    select count(*) into n from public.covoit_passagers p
      where p.voiture_id = new.voiture_id and p.aller and p.licencie_id <> new.licencie_id;
    if n >= v.places then raise exception 'Plus de place à l''aller dans cette voiture'; end if;
    if exists (select 1 from public.covoit_passagers p
               where p.sortie_id = v.sortie_id and p.licencie_id = new.licencie_id
                 and p.aller and p.voiture_id <> new.voiture_id) then
      raise exception 'Cette gym a déjà une place à l''aller dans une autre voiture';
    end if;
  end if;
  if new.retour then
    select count(*) into n from public.covoit_passagers p
      where p.voiture_id = new.voiture_id and p.retour and p.licencie_id <> new.licencie_id;
    if n >= v.places then raise exception 'Plus de place au retour dans cette voiture'; end if;
    if exists (select 1 from public.covoit_passagers p
               where p.sortie_id = v.sortie_id and p.licencie_id = new.licencie_id
                 and p.retour and p.voiture_id <> new.voiture_id) then
      raise exception 'Cette gym a déjà une place au retour dans une autre voiture';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.covoit_passager_verif() from public, anon, authenticated;

drop trigger if exists covoit_passagers_verif on public.covoit_passagers;
create trigger covoit_passagers_verif
  before insert or update on public.covoit_passagers
  for each row execute function public.covoit_passager_verif();

-- Une voiture ne peut pas être réduite ou changer de sens si des gyms y ont déjà une place.
create or replace function public.covoit_voiture_verif()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare na int; nr int;
begin
  select count(*) filter (where aller), count(*) filter (where retour) into na, nr
    from public.covoit_passagers where voiture_id = new.id;
  if na > new.places or nr > new.places then
    raise exception 'Des gyms occupent déjà plus de places que ce nombre : retire-les d''abord';
  end if;
  if (new.sens = 'retour' and na > 0) or (new.sens = 'aller' and nr > 0) then
    raise exception 'Des gyms ont déjà une place sur le trajet supprimé : retire-les d''abord';
  end if;
  return new;
end $$;
revoke all on function public.covoit_voiture_verif() from public, anon, authenticated;

drop trigger if exists covoit_voitures_verif on public.covoit_voitures;
create trigger covoit_voitures_verif
  before update on public.covoit_voitures
  for each row execute function public.covoit_voiture_verif();

-- 3) Règles d'accès (connectés uniquement) --------------------------------------
alter table public.covoit_sorties   enable row level security;
alter table public.covoit_reponses  enable row level security;
alter table public.covoit_voitures  enable row level security;
alter table public.covoit_passagers enable row level security;

drop policy if exists covoit_sorties_lecture  on public.covoit_sorties;
drop policy if exists covoit_sorties_ecriture on public.covoit_sorties;
create policy covoit_sorties_lecture on public.covoit_sorties
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy covoit_sorties_ecriture on public.covoit_sorties
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select g.club_id from public.groupes_entrainement g where g.id = groupe_id)
    and groupe_id = (select c.groupe_id from public.groupe_creneaux c where c.id = creneau_id)
  );

drop policy if exists covoit_reponses_lecture  on public.covoit_reponses;
drop policy if exists covoit_reponses_ecriture on public.covoit_reponses;
create policy covoit_reponses_lecture on public.covoit_reponses
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy covoit_reponses_ecriture on public.covoit_reponses
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select s.club_id from public.covoit_sorties s where s.id = sortie_id)
    and exists (select 1 from public.covoit_sorties s
                join public.groupe_licencies gl on gl.groupe_id = s.groupe_id
                where s.id = sortie_id and gl.licencie_id = covoit_reponses.licencie_id)
  );

drop policy if exists covoit_voitures_lecture  on public.covoit_voitures;
drop policy if exists covoit_voitures_ecriture on public.covoit_voitures;
create policy covoit_voitures_lecture on public.covoit_voitures
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy covoit_voitures_ecriture on public.covoit_voitures
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (
    public.role_dans_club(club_id) in ('admin', 'entraineur')
    and club_id = (select s.club_id from public.covoit_sorties s where s.id = sortie_id)
  );

drop policy if exists covoit_passagers_lecture  on public.covoit_passagers;
drop policy if exists covoit_passagers_ecriture on public.covoit_passagers;
create policy covoit_passagers_lecture on public.covoit_passagers
  for select to authenticated
  using (public.role_dans_club(club_id) is not null);
create policy covoit_passagers_ecriture on public.covoit_passagers
  for all to authenticated
  using (public.role_dans_club(club_id) in ('admin', 'entraineur'))
  with check (public.role_dans_club(club_id) in ('admin', 'entraineur'));

revoke all on public.covoit_sorties, public.covoit_reponses, public.covoit_voitures, public.covoit_passagers from anon;
revoke all on public.covoit_sorties, public.covoit_reponses, public.covoit_voitures, public.covoit_passagers from authenticated;
grant select, insert, update, delete
  on public.covoit_sorties, public.covoit_reponses, public.covoit_voitures, public.covoit_passagers to authenticated;

-- 4) Fonctions pour les parents (sans compte, avec le lien secret) ----------------
-- Séance correspondant à un lien ; p_ecriture : refuse si les réponses sont fermées,
-- la séance passée ou annulée.
create or replace function public.covoit_sortie_du_lien(p_token text, p_ecriture boolean)
returns public.covoit_sorties
language plpgsql
stable
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype;
begin
  if p_token is null or char_length(p_token) < 32 then raise exception 'Lien invalide'; end if;
  select * into s from public.covoit_sorties where token = p_token;
  if not found then raise exception 'Lien invalide ou supprimé'; end if;
  if p_ecriture then
    if not s.ouvert then raise exception 'Les réponses sont fermées : contacte l''entraîneur'; end if;
    if s.date < (now() at time zone 'Europe/Paris')::date then raise exception 'Cette séance est passée'; end if;
    if exists (select 1 from public.seances_annulees a where a.creneau_id = s.creneau_id and a.date = s.date) then
      raise exception 'Cette séance est annulée';
    end if;
  end if;
  return s;
end $$;
revoke all on function public.covoit_sortie_du_lien(text, boolean) from public, anon, authenticated;

-- Tout ce que la page des parents affiche.
create or replace function public.covoit_public_voir(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype; r jsonb;
begin
  s := public.covoit_sortie_du_lien(p_token, false);
  select jsonb_build_object(
    'club', cl.nom,
    'groupe', g.nom,
    'intitule', case when c.type = 'ponctuel' then c.libelle end,
    'date', s.date,
    'debut', to_char(c.heure_debut, 'HH24:MI'),
    'fin', to_char(c.heure_fin, 'HH24:MI'),
    'lieu', coalesce(x.lieu, c.lieu, g.lieu),
    'note', s.note,
    'annulee', exists (select 1 from public.seances_annulees a where a.creneau_id = s.creneau_id and a.date = s.date),
    'passee', s.date < (now() at time zone 'Europe/Paris')::date,
    'ouvert', s.ouvert,
    'gyms', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id,
               'nom', trim(coalesce(l.prenom, '') || ' ' || coalesce(upper(left(l.nom, 1)) || '.', '')))
             order by lower(l.prenom), lower(l.nom))
      from public.groupe_licencies gl join public.licencies l on l.id = gl.licencie_id
      where gl.groupe_id = s.groupe_id), '[]'::jsonb),
    'reponses', coalesce((
      select jsonb_agg(jsonb_build_object('l', rp.licencie_id, 's', rp.statut, 'a', rp.besoin_aller,
               'r', rp.besoin_retour, 'c', rp.commentaire))
      from public.covoit_reponses rp where rp.sortie_id = s.id), '[]'::jsonb),
    'voitures', coalesce((
      select jsonb_agg(jsonb_build_object('id', v.id, 'conducteur', v.conducteur, 'telephone', v.telephone,
               'places', v.places, 'sens', v.sens, 'rdv_lieu', v.rdv_lieu,
               'rdv_heure', to_char(v.rdv_heure, 'HH24:MI'), 'note', v.note,
               'passagers', coalesce((
                 select jsonb_agg(jsonb_build_object('l', p.licencie_id, 'a', p.aller, 'r', p.retour))
                 from public.covoit_passagers p where p.voiture_id = v.id), '[]'::jsonb))
             order by v.created_at)
      from public.covoit_voitures v where v.sortie_id = s.id), '[]'::jsonb)
  ) into r
  from public.clubs cl
  join public.groupes_entrainement g on g.id = s.groupe_id
  join public.groupe_creneaux c on c.id = s.creneau_id
  left join public.seances_exceptions x on x.creneau_id = s.creneau_id and x.date = s.date
  where cl.id = s.club_id;
  return r;
end $$;

-- Réponse d'une famille : présent(e) ou absent(e), besoin d'une place à l'aller / au retour.
create or replace function public.covoit_public_repondre(
  p_token text, p_licencie uuid, p_statut text, p_aller boolean, p_retour boolean, p_commentaire text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype; a boolean; r boolean;
begin
  s := public.covoit_sortie_du_lien(p_token, true);
  if p_statut is null or p_statut not in ('present', 'absent') then raise exception 'Réponse invalide'; end if;
  if not exists (select 1 from public.groupe_licencies gl
                 where gl.groupe_id = s.groupe_id and gl.licencie_id = p_licencie) then
    raise exception 'Cette gym ne fait pas partie du groupe';
  end if;
  a := p_statut = 'present' and coalesce(p_aller, false);
  r := p_statut = 'present' and coalesce(p_retour, false);
  insert into public.covoit_reponses (sortie_id, licencie_id, club_id, statut, besoin_aller, besoin_retour, commentaire, par)
  values (s.id, p_licencie, s.club_id, p_statut, a, r, nullif(left(trim(coalesce(p_commentaire, '')), 300), ''), 'parent')
  on conflict (sortie_id, licencie_id) do update
    set statut = excluded.statut, besoin_aller = excluded.besoin_aller, besoin_retour = excluded.besoin_retour,
        commentaire = excluded.commentaire, par = 'parent', updated_at = now();
  -- libère les places devenues inutiles
  if not a then update public.covoit_passagers set aller = false
    where sortie_id = s.id and licencie_id = p_licencie and aller and retour; end if;
  if not r then update public.covoit_passagers set retour = false
    where sortie_id = s.id and licencie_id = p_licencie and aller and retour; end if;
  delete from public.covoit_passagers p
    where p.sortie_id = s.id and p.licencie_id = p_licencie
      and not ((p.aller and a) or (p.retour and r));
  return public.covoit_public_voir(p_token);
end $$;

-- Proposer une voiture (p_id vide) ou modifier la sienne (p_id + p_cle reçue à la création).
create or replace function public.covoit_public_voiture(
  p_token text, p_id uuid, p_cle text, p_conducteur text, p_telephone text, p_places int,
  p_sens text, p_rdv_lieu text, p_rdv_heure text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype; v_id uuid; v_cle text; h time;
  nom text := left(trim(coalesce(p_conducteur, '')), 60);
begin
  s := public.covoit_sortie_du_lien(p_token, true);
  if nom = '' then raise exception 'Indique le nom du conducteur'; end if;
  if p_places is null or p_places < 1 or p_places > 8 then raise exception 'Nombre de places entre 1 et 8'; end if;
  if p_sens is null or p_sens not in ('aller_retour', 'aller', 'retour') then raise exception 'Trajet invalide'; end if;
  if coalesce(p_rdv_heure, '') ~ '^\d{1,2}:\d{2}$' then h := p_rdv_heure::time; end if;
  if p_id is null then
    if (select count(*) from public.covoit_voitures where sortie_id = s.id) >= 20 then
      raise exception 'Trop de voitures pour cette séance';
    end if;
    insert into public.covoit_voitures (sortie_id, club_id, conducteur, telephone, places, sens, rdv_lieu, rdv_heure, note)
    values (s.id, s.club_id, nom, nullif(left(trim(coalesce(p_telephone, '')), 30), ''), p_places, p_sens,
            nullif(left(trim(coalesce(p_rdv_lieu, '')), 120), ''), h, nullif(left(trim(coalesce(p_note, '')), 300), ''))
    returning id, cle into v_id, v_cle;
  else
    update public.covoit_voitures
      set conducteur = nom, telephone = nullif(left(trim(coalesce(p_telephone, '')), 30), ''), places = p_places,
          sens = p_sens, rdv_lieu = nullif(left(trim(coalesce(p_rdv_lieu, '')), 120), ''), rdv_heure = h,
          note = nullif(left(trim(coalesce(p_note, '')), 300), '')
      where id = p_id and sortie_id = s.id and cle = p_cle
      returning id, cle into v_id, v_cle;
    if v_id is null then raise exception 'Seule la personne qui a proposé cette voiture (ou l''entraîneur) peut la modifier'; end if;
  end if;
  return jsonb_build_object('id', v_id, 'cle', v_cle, 'etat', public.covoit_public_voir(p_token));
end $$;

-- Retirer sa voiture.
create or replace function public.covoit_public_voiture_suppr(p_token text, p_id uuid, p_cle text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype; n int;
begin
  s := public.covoit_sortie_du_lien(p_token, true);
  delete from public.covoit_voitures where id = p_id and sortie_id = s.id and cle = p_cle;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Seule la personne qui a proposé cette voiture (ou l''entraîneur) peut la retirer'; end if;
  return public.covoit_public_voir(p_token);
end $$;

-- Réserver (p_aller / p_retour) ou libérer (les deux à faux) une place pour une gym.
create or replace function public.covoit_public_place(
  p_token text, p_voiture uuid, p_licencie uuid, p_aller boolean, p_retour boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare s public.covoit_sorties%rowtype; a boolean := coalesce(p_aller, false); r boolean := coalesce(p_retour, false);
begin
  s := public.covoit_sortie_du_lien(p_token, true);
  if not exists (select 1 from public.covoit_voitures v where v.id = p_voiture and v.sortie_id = s.id) then
    raise exception 'Voiture introuvable';
  end if;
  if not exists (select 1 from public.groupe_licencies gl
                 where gl.groupe_id = s.groupe_id and gl.licencie_id = p_licencie) then
    raise exception 'Cette gym ne fait pas partie du groupe';
  end if;
  if not a and not r then
    delete from public.covoit_passagers where voiture_id = p_voiture and licencie_id = p_licencie;
    return public.covoit_public_voir(p_token);
  end if;
  -- quitte les autres voitures pour les trajets demandés
  if a then update public.covoit_passagers set aller = false
    where sortie_id = s.id and licencie_id = p_licencie and voiture_id <> p_voiture and aller and retour; end if;
  if r then update public.covoit_passagers set retour = false
    where sortie_id = s.id and licencie_id = p_licencie and voiture_id <> p_voiture and aller and retour; end if;
  delete from public.covoit_passagers p
    where p.sortie_id = s.id and p.licencie_id = p_licencie and p.voiture_id <> p_voiture
      and ((p.aller and a and not p.retour) or (p.retour and r and not p.aller) or (a and r));
  insert into public.covoit_passagers (voiture_id, licencie_id, sortie_id, club_id, aller, retour)
  values (p_voiture, p_licencie, s.id, s.club_id, a, r)
  on conflict (voiture_id, licencie_id) do update set aller = excluded.aller, retour = excluded.retour;
  -- la gym est donc présente et a besoin d'une place sur ces trajets
  insert into public.covoit_reponses (sortie_id, licencie_id, club_id, statut, besoin_aller, besoin_retour, par)
  values (s.id, p_licencie, s.club_id, 'present', a, r, 'parent')
  on conflict (sortie_id, licencie_id) do update
    set statut = 'present', besoin_aller = covoit_reponses.besoin_aller or excluded.besoin_aller,
        besoin_retour = covoit_reponses.besoin_retour or excluded.besoin_retour, updated_at = now();
  return public.covoit_public_voir(p_token);
end $$;

revoke all on function public.covoit_public_voir(text) from public;
revoke all on function public.covoit_public_repondre(text, uuid, text, boolean, boolean, text) from public;
revoke all on function public.covoit_public_voiture(text, uuid, text, text, text, int, text, text, text, text) from public;
revoke all on function public.covoit_public_voiture_suppr(text, uuid, text) from public;
revoke all on function public.covoit_public_place(text, uuid, uuid, boolean, boolean) from public;
grant execute on function public.covoit_public_voir(text) to anon, authenticated;
grant execute on function public.covoit_public_repondre(text, uuid, text, boolean, boolean, text) to anon, authenticated;
grant execute on function public.covoit_public_voiture(text, uuid, text, text, text, int, text, text, text, text) to anon, authenticated;
grant execute on function public.covoit_public_voiture_suppr(text, uuid, text) to anon, authenticated;
grant execute on function public.covoit_public_place(text, uuid, uuid, boolean, boolean) to anon, authenticated;
