-- Compétitions dont le jour n'est pas encore connu (« 12 ou 13 déc. ») : date_comp = le samedi,
-- date_incertaine = vrai → l'application affiche « samedi ou dimanche ». Script réexécutable.
alter table public.competitions add column if not exists date_incertaine boolean not null default false;
