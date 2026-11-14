-- Résultats de compétitions : formule individuelle ou par équipe (FFG)
-- + catégorie équipe Fédéral A 10-15 ans (règlement technique FFGym 2026-2027).
-- Relançable sans risque. Aucune donnée supprimée.

alter table public.competitions add column if not exists formule text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'competitions_formule_check') then
    alter table public.competitions add constraint competitions_formule_check check (formule is null or formule in ('indiv','equipe'));
  end if;
end $$;

-- 10-15 ans ajouté ; 12-15 ans (saison 2025-2026) reste accepté pour les anciennes équipes
do $$ begin
  if to_regclass('public.equipes') is not null then
    alter table public.equipes drop constraint if exists equipes_categorie_check;
    alter table public.equipes add constraint equipes_categorie_check check (categorie is null or categorie in ('10+','14+','10-15','12-15','10-13','10-11'));
  end if;
end $$;
