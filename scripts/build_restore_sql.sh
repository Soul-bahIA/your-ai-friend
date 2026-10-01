#!/usr/bin/env bash
# Régénère RESTAURATION_BASE.sql = en-tête + toutes les migrations Supabase, dans l'ordre.
# Usage (depuis la racine du dépôt, git-bash / Linux / macOS) : bash scripts/build_restore_sql.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=RESTAURATION_BASE.sql
{
cat <<'HEADER'
-- =============================================================================
-- SOULBAH AI — SCRIPT DE RESTAURATION COMPLÈTE DU SCHÉMA
-- =============================================================================
-- Fichier GÉNÉRÉ : concaténation, dans l'ordre, de TOUTES les migrations de
-- supabase/migrations/ (ne pas éditer à la main — modifier/ajouter une migration
-- puis régénérer ce fichier).
--
-- USAGE
--   * Méthode recommandée : `supabase link --project-ref <ref>` puis `supabase db push`
--     (applique uniquement les migrations manquantes et tient l'historique à jour).
--   * Sinon : coller ce fichier dans Supabase > SQL Editor et l'exécuter.
--
-- ATTENTION
--   * À exécuter sur un projet Supabase NEUF et VIDE (schéma public vierge).
--     Les 4 migrations de février 2026 utilisent CREATE TABLE / CREATE POLICY sans
--     IF NOT EXISTS : rejouer ce script sur une base existante échouera.
--     JAMAIS sur le projet existant : utiliser `supabase db push` (docs/SUPABASE_REPRISE.md).
--     Les migrations à partir de 20260703000000 sont rejouables ; c'est vérifié par
--     scripts/ci/apply_migrations.sh (job CI `db`).
--   * Le script s'exécute dans UNE transaction : en cas d'erreur, rien n'est appliqué.
--   * Prérequis Supabase : schéma auth, rôles authenticated/anon, publication
--     supabase_realtime, extensions pgvector et pg_trgm (disponibles sur Supabase).
--   * Ne restaure QUE le schéma (droits et policies compris). Les données se
--     restaurent ENSUITE depuis une sauvegarde (scripts/backup_db.sh / .ps1) :
--     pg_restore --data-only, puis scripts/sql/post_restore_checks.sql
--     (procédure : README.md, section « Sauvegardes »).
--
-- Régénération (git-bash) :
--   bash scripts/build_restore_sql.sh
-- =============================================================================

BEGIN;
HEADER
for f in supabase/migrations/*.sql; do
  printf '\n\n-- >>>>>>>>>> %s <<<<<<<<<<\n\n' "$(basename "$f")"
  cat "$f"
done
printf '\n\nCOMMIT;\n'
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "$OUT régénéré ($(ls supabase/migrations/*.sql | wc -l) migrations)."
