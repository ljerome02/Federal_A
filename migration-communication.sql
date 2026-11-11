-- ============================================================================
-- Migration : lien WhatsApp des groupes d'entraînement
-- À exécuter UNE fois dans Supabase > SQL Editor (peut être relancé sans risque).
-- Prérequis : migration-presences.sql déjà exécuté.
--
-- Ajoute à « groupes_entrainement » la colonne « lien_whatsapp » : le lien
-- d'invitation du groupe WhatsApp (https://chat.whatsapp.com/…). Il se saisit
-- dans Présences et groupes > Groupes, et s'ouvre en un clic depuis la page
-- Messages et WhatsApp et depuis la fiche des licenciés membres du groupe.
-- Les droits existants sur la table ne changent pas.
-- ============================================================================
alter table public.groupes_entrainement
  add column if not exists lien_whatsapp text;
