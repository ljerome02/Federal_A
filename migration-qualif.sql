-- Résultats de compétitions : qualification pour l'étape suivante (bouton « Q »)
-- Relançable sans risque. Aucune donnée supprimée.
alter table public.competition_resultats add column if not exists qualifie boolean not null default false;
alter table public.competition_equipes  add column if not exists qualifie boolean not null default false;
