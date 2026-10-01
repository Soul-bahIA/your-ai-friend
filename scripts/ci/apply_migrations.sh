#!/usr/bin/env bash
# Applique TOUTES les migrations de supabase/migrations/ sur une base Postgres JETABLE,
# deux fois, et vérifie que le second passage ne modifie pas le schéma.
#
#   1. scripts/ci/auth_stub.sql            (rôles, schéma auth, auth.uid(), publication)
#   2. passage 1 : toutes les migrations, dans l'ordre, une transaction par fichier
#                  (comme `supabase db push`)
#   3. passage 2 : rejeu des migrations >= REPLAY_FROM (défaut 20260703000000)
#   4. comparaison des schémas (pg_dump --schema-only) après passage 1 et passage 2
#   5. --checks : assertions scripts/ci/schema_checks.sql (exécutées puis annulées),
#                 contrôles post-restauration scripts/sql/post_restore_checks.sql (lecture
#                 seule) et rôle soulbah_api (scripts/ci/api_role_checks.sql, avec les
#                 droits de scripts/sql/soulbah_api_grants.sql ; annulé)
#
# Les 4 migrations de février 2026 (générées par Lovable : CREATE TYPE / TABLE / POLICY
# sans garde) ne sont PAS rejouables et ne sont donc appliquées qu'une fois ; toutes
# les migrations suivantes doivent l'être (règle des migrations LOT 1+).
#
# Usage (connexion par les variables libpq PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE) :
#   bash scripts/ci/apply_migrations.sh [--stub-vector] [--checks]
#
# Variables :
#   PSQL         commande psql      (défaut : psql)
#                ex. CI : PSQL="docker exec -i <conteneur> psql -U postgres -d postgres"
#   PG_DUMP      commande pg_dump   (défaut : pg_dump ; "none" = pas de comparaison)
#                Doit être de version >= serveur : en CI, celui du conteneur.
#   REPLAY_FROM  première version rejouée au passage 2 (défaut : 20260703000000)
#   PG_MIN_MESSAGES  niveau client_min_messages pendant les migrations (défaut : warning)
#   STUB_VECTOR=1 équivaut à --stub-vector : réécrit à la volée le DDL pgvector
#                (CREATE EXTENSION vector supprimé, vector(N) et `vector` sans dimension
#                → real[], index HNSW sautés) pour un PG local SANS pgvector (cas de ce PC
#                Windows, PG18).
#                Valide tout le schéma SAUF la sémantique vectorielle, couverte par le
#                job CI `db` (image pgvector).
#
# SÉCURITÉ : refuse de tourner sur une base qui ressemble à un vrai projet Supabase.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIG_DIR="$ROOT/supabase/migrations"
STUB_VECTOR="${STUB_VECTOR:-0}"
RUN_CHECKS=0
REPLAY_FROM="${REPLAY_FROM:-20260703000000}"

for arg in "$@"; do
  case "$arg" in
    --stub-vector) STUB_VECTOR=1 ;;
    --checks)      RUN_CHECKS=1 ;;
    -h|--help)     sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "Option inconnue : $arg" >&2; exit 2 ;;
  esac
done

read -r -a PSQL_CMD    <<< "${PSQL:-psql}"
read -r -a PG_DUMP_CMD <<< "${PG_DUMP:-pg_dump}"

# Les migrations sont en UTF-8 (psql Windows suppose sinon la page de code de la console).
export PGCLIENTENCODING="${PGCLIENTENCODING:-UTF8}"
psql_run() { "${PSQL_CMD[@]}" -X -q -v ON_ERROR_STOP=1 "$@"; }

# pgvector absent : réécriture minimale du DDL vectoriel (voir en-tête).
stub_vector() {
  perl -0pe '
    s/CREATE\s+EXTENSION\s+IF\s+NOT\s+EXISTS\s+vector\s*;/-- [stub-vector] extension pgvector absente : non créée/gi;
    s/\bvector\((\d+)\)/real[] \/* [stub-vector] vector($1) *\//gi;
    s/(\s)vector(\s*,)/$1real[] \/* [stub-vector] vector *\/$2/gi;
    s/CREATE\s+INDEX\s+IF\s+NOT\s+EXISTS\s+(\w+)\s+ON\s+[\w.]+\s+USING\s+hnsw\s*\([^;]*;/-- [stub-vector] index HNSW $1 sauté/gi;
  '
}

# Une transaction par fichier (-1). Les NOTICE « already exists, skipping » du rejeu sont
# masqués par défaut : PG_MIN_MESSAGES=notice pour tout voir.
apply_file() {
  local f="$1"
  local level=(-c "SET client_min_messages = ${PG_MIN_MESSAGES:-warning}")
  if [[ "$STUB_VECTOR" == "1" ]]; then
    stub_vector < "$f" | psql_run -1 "${level[@]}" -f -
  else
    psql_run -1 "${level[@]}" -f - < "$f"
  fi
}

dump_schema() {
  local out="$1"
  "${PG_DUMP_CMD[@]}" --schema-only --schema=public --schema=auth --schema=soulbah > "$out.raw"
  # \restrict / \unrestrict : jetons aléatoires ajoutés par pg_dump >= 17.6 / 18.0.
  grep -Ev '^\\(un)?restrict ' "$out.raw" > "$out" || true
}

# --- Garde-fou : jamais sur un vrai Supabase ------------------------------------------
looks_real="$(psql_run -At -c "SELECT
  (to_regnamespace('supabase_migrations') IS NOT NULL)
  OR EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'auth' AND table_name = 'users'
                AND column_name = 'encrypted_password')")"
if [[ "$looks_real" == "t" ]]; then
  echo "REFUS : cette base ressemble à un projet Supabase réel (supabase_migrations / auth.users complet)." >&2
  exit 3
fi

shopt -s nullglob
MIGRATIONS=("$MIG_DIR"/*.sql)
(( ${#MIGRATIONS[@]} > 0 )) || { echo "Aucune migration dans $MIG_DIR" >&2; exit 1; }

echo "== Stub Supabase (auth, rôles, publication)"
psql_run -f - < "$ROOT/scripts/ci/auth_stub.sql"

echo "== Passage 1 : ${#MIGRATIONS[@]} migrations (stub-vector=$STUB_VECTOR)"
for f in "${MIGRATIONS[@]}"; do
  echo "   + $(basename "$f")"
  apply_file "$f"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [[ "${PG_DUMP:-}" != "none" ]]; then
  dump_schema "$TMP/pass1.sql"
fi

echo "== Passage 2 : rejeu des migrations >= $REPLAY_FROM"
replayed=0
for f in "${MIGRATIONS[@]}"; do
  version="$(basename "$f" | cut -d_ -f1)"
  if [[ "$version" < "$REPLAY_FROM" ]]; then
    echo "   - $(basename "$f") (non rejouable : appliquée une seule fois)"
    continue
  fi
  echo "   + $(basename "$f")"
  apply_file "$f"
  replayed=$((replayed + 1))
done

if [[ "${PG_DUMP:-}" != "none" ]]; then
  dump_schema "$TMP/pass2.sql"
  if ! diff -u "$TMP/pass1.sql" "$TMP/pass2.sql"; then
    echo "ÉCHEC : le rejeu a modifié le schéma (diff ci-dessus)." >&2
    exit 1
  fi
  echo "== Schéma identique après rejeu ($(wc -l < "$TMP/pass1.sql") lignes comparées)"
fi

if [[ "$RUN_CHECKS" == "1" ]]; then
  echo "== Assertions (scripts/ci/schema_checks.sql)"
  psql_run -f - < "$ROOT/scripts/ci/schema_checks.sql"
  echo "== Contrôles post-restauration (scripts/sql/post_restore_checks.sql)"
  psql_run -f - < "$ROOT/scripts/sql/post_restore_checks.sql"
  echo "== Rôle soulbah_api (scripts/ci/api_role_checks.sql + scripts/sql/soulbah_api_grants.sql)"
  # Le fichier de droits est inséré à la place du marqueur (psql lit l'entrée standard :
  # pas de \i possible quand psql tourne dans un conteneur).
  awk -v grants="$ROOT/scripts/sql/soulbah_api_grants.sql" '
    /^-- @@SOULBAH_API_GRANTS@@\r?$/ { while ((getline line < grants) > 0) print line; next }
    { print }
  ' "$ROOT/scripts/ci/api_role_checks.sql" | psql_run -f -
fi

echo "OK : ${#MIGRATIONS[@]} migrations appliquées, $replayed rejouées sans erreur."
