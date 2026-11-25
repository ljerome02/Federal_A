-- ============================================================================
-- Migration : ordre de passage d'une gym à une compétition (repris de l'organigramme).
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- passage = { "sub": 1, "debut": "10:00", "fin": "12:00", "presence": "09:15",
--             "agres": "sol", "ordre": 1, "palmares": "12:00" }
-- ============================================================================
alter table public.competition_resultats add column if not exists passage jsonb not null default '{}'::jsonb;
alter table public.competition_resultats drop constraint if exists competition_resultats_passage_obj;
alter table public.competition_resultats add constraint competition_resultats_passage_obj check (jsonb_typeof(passage) = 'object');
