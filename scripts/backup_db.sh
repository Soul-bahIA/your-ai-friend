#!/usr/bin/env bash
# Sauvegarde de la base SoulBah AI (Postgres Supabase) avec pg_dump.
#
# Produit, dans backups/ (ignoré par git) :
#   backups/soulbah_YYYYMMDD_HHMM.dump  — format custom (restauration sélective via pg_restore)
#   backups/soulbah_YYYYMMDD_HHMM.sql   — format texte (lisible, restaurable via psql)
#
# Source de la connexion (par ordre de priorité) :
#   1. BACKUP_DATABASE_URL (variable d'environnement)
#   2. DATABASE_URL lu dans backend/.env
# Le pooler Supabase en mode transaction (port 6543) est remplacé par le mode
# session (port 5432), seul compatible avec pg_dump.
#
# Schémas sauvegardés : BACKUP_SCHEMAS (défaut : "public auth").
#
# Usage (git-bash / Linux / macOS, depuis n'importe où) :
#   bash scripts/backup_db.sh
#   BACKUP_SCHEMAS="public" bash scripts/backup_db.sh
#
# Prérequis : pg_dump dans le PATH, version >= à celle du serveur
# (Windows : C:\Program Files\PostgreSQL\<version>\bin).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/backend/.env"
OUT_DIR="$ROOT/backups"
SCHEMAS="${BACKUP_SCHEMAS:-public auth}"

DB_URL="${BACKUP_DATABASE_URL:-}"
if [[ -z "$DB_URL" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Erreur : $ENV_FILE introuvable et BACKUP_DATABASE_URL non défini." >&2
    exit 1
  fi
  # Dernière définition de DATABASE_URL, sans \r (fichiers édités sous Windows) ni guillemets.
  DB_URL="$(tr -d '\r' < "$ENV_FILE" | grep -E '^[[:space:]]*DATABASE_URL=' | tail -n 1 | cut -d= -f2-)"
  DB_URL="${DB_URL%\"}"; DB_URL="${DB_URL#\"}"
  DB_URL="${DB_URL%\'}"; DB_URL="${DB_URL#\'}"
fi
if [[ -z "$DB_URL" ]]; then
  echo "Erreur : DATABASE_URL vide dans $ENV_FILE." >&2
  exit 1
fi

# Pooler Supabase : mode transaction (6543) → mode session (5432).
if [[ "$DB_URL" == *pooler.supabase.com:6543* ]]; then
  DB_URL="${DB_URL/pooler.supabase.com:6543/pooler.supabase.com:5432}"
fi

# PGSSLMODE=require par défaut (Supabase exige TLS), surchargeable.
export PGSSLMODE="${PGSSLMODE:-require}"

if ! command -v pg_dump >/dev/null 2>&1; then
  for d in "/c/Program Files/PostgreSQL"/*/bin; do
    [[ -x "$d/pg_dump.exe" || -x "$d/pg_dump" ]] && PATH="$d:$PATH"
  done
fi
command -v pg_dump >/dev/null 2>&1 || { echo "Erreur : pg_dump introuvable (installez les outils client PostgreSQL)." >&2; exit 1; }

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d_%H%M)"
BASE="$OUT_DIR/soulbah_$STAMP"

SCHEMA_ARGS=()
for s in $SCHEMAS; do SCHEMA_ARGS+=(--schema="$s"); done

echo "pg_dump $(pg_dump --version | awk '{print $NF}') — schémas : $SCHEMAS"

echo "→ $BASE.dump (format custom)"
pg_dump --dbname="$DB_URL" --format=custom --no-owner --no-privileges \
  "${SCHEMA_ARGS[@]}" --file="$BASE.dump"

echo "→ $BASE.sql (format texte)"
pg_dump --dbname="$DB_URL" --format=plain --no-owner --no-privileges \
  "${SCHEMA_ARGS[@]}" --file="$BASE.sql"

ls -lh "$BASE.dump" "$BASE.sql"
echo "Sauvegarde terminée."
