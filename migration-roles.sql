-- ============================================================================
-- Migration : rôles des adhérents dans l'association
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-licences.sql déjà exécuté.
--
-- Ajoute à « licencies » :
--   - fonctions       : liste des rôles, cumulables (gymnaste, président, trésorier,
--                       entraîneur, juge…) ;
--   - fonctions_note  : précisions libres (niveau de juge, diplôme d'entraîneur…).
-- Les adhérents déjà enregistrés reçoivent le rôle « gymnaste ».
-- Ces rôles décrivent l'association ; ils ne donnent aucun droit dans
-- l'application (les accès restent gérés dans « Membres »).
-- ============================================================================
alter table public.licencies
  add column if not exists fonctions      text[] not null default '{gymnaste}',
  add column if not exists fonctions_note text;

update public.licencies set fonctions = '{gymnaste}'
where fonctions is null or cardinality(fonctions) = 0;

create index if not exists licencies_fonctions_idx on public.licencies using gin (fonctions);
