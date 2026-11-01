-- Migration 3/6 — Nouveaux rôle et statut pour le niveau DRH.
-- Fichier séparé : une valeur d'enum ajoutée ne peut pas être utilisée dans la même transaction.
alter type public.user_role      add value if not exists 'drh';
alter type public.request_status add value if not exists 'drh_review';
