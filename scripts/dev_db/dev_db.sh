#!/usr/bin/env bash
# Base PostgreSQL LOCALE et JETABLE pour développer et tester SoulBah sans Supabase (LOT 3).
#
# Cluster créé avec initdb/pg_ctl dans .dev_db/pg (hors git), écoute UNIQUEMENT sur
# 127.0.0.1:${DEV_DB_PORT:-54329}, authentification « trust » (base de dev, aucune donnée
# réelle). Le schéma est celui du dépôt : scripts/ci/auth_stub.sql (stub de Supabase) puis
# TOUTES les migrations de supabase/migrations/, appliquées DEUX fois avec les assertions
# (scripts/ci/apply_migrations.sh --checks). Sans pgvector (cas de PG18 sous Windows), le
# DDL vectoriel est réécrit en stub : tout le schéma est validé SAUF la sémantique
# vectorielle, couverte par le job CI `db` (image pgvector).
#
# Usage :
#   bash scripts/dev_db/dev_db.sh up        init (si besoin) + start + migrate (si besoin) + seed
#   bash scripts/dev_db/dev_db.sh init      initdb dans .dev_db/pg
#   bash scripts/dev_db/dev_db.sh start|stop|restart|status
#   bash scripts/dev_db/dev_db.sh migrate   stub Supabase + migrations ×2 + assertions (une fois par cluster)
#   bash scripts/dev_db/dev_db.sh seed      utilisateur de dev + clé agent → .dev_db/dev.env (idempotent)
#   bash scripts/dev_db/dev_db.sh url       affiche DATABASE_URL
#   bash scripts/dev_db/dev_db.sh env       affiche le contenu de .dev_db/dev.env (à `source`)
#   bash scripts/dev_db/dev_db.sh test      tests d'intégration node-api sur la base de TEST soulbah_test
#                                           (recréée si absente : n'interfère pas avec l'appli qui tourne)
#   bash scripts/dev_db/dev_db.sh testdb    (re)crée soulbah_test : stub + migrations ×2 + contrôles + tests
#   bash scripts/dev_db/dev_db.sh psql [..] ouvre psql sur la base
#   bash scripts/dev_db/dev_db.sh reset     stop + suppression du cluster + up (dev.env conservé : jeton stable)
#   bash scripts/dev_db/dev_db.sh destroy   stop + suppression de .dev_db/ entier (dev.env compris)
#
# Variables :
#   PG_BIN         dossier des binaires PostgreSQL (défaut : pg_ctl du PATH, pg_config --bindir,
#                  sinon la version la plus récente de C:\Program Files\PostgreSQL ou /usr/lib/postgresql)
#   DEV_DB_DIR     dossier du cluster et de dev.env (défaut : <dépôt>/.dev_db)
#   DEV_DB_PORT    port d'écoute (défaut : 54329)
#   SOULBAH_WORKSPACE  dossier autorisé de la clé agent de dev (défaut : ~/SoulbahWorkspace)
#
# Ensuite (hors Docker) :
#   source .dev_db/dev.env            # DATABASE_URL, AUTH_MODE=dev-local, DEV_LOCAL_*, LLM_FAKE_PROVIDER=1…
#   cd backend/node-api && npm run dev
#   cd backend/python-ia && .venv/Scripts/python -m uvicorn app.main:app --port 8000
#   curl -H "Authorization: Bearer $DEV_LOCAL_TOKEN" http://127.0.0.1:3000/api/agent-tasks
#
# PowerShell : powershell -ExecutionPolicy Bypass -File scripts\dev_db\dev_db.ps1 up
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEV_DB_DIR="${DEV_DB_DIR:-$ROOT/.dev_db}"
DATA_DIR="$DEV_DB_DIR/pg"
PORT="${DEV_DB_PORT:-54329}"
ENV_FILE="$DEV_DB_DIR/dev.env"
LOG_FILE="$DEV_DB_DIR/postgres.log"
DB_USER=postgres
DB_NAME=postgres
# Utilisateur de dev FIXE (uuid v4 valide) : le même sur tous les postes → .env partageables.
DEV_USER_ID="a0000000-0000-4000-8000-000000000001"
DEV_USER_EMAIL="dev@soulbah.local"
# ASCII : sous Windows, psql reçoit les arguments -v dans la page de code de la console (pas en UTF-8).
DEV_KEY_LABEL="PC de developpement (dev_db)"

die() { echo "dev_db : $*" >&2; exit 1; }
info() { echo "== $*"; }

is_windows() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }

# --- Binaires PostgreSQL --------------------------------------------------------------
has_pg_ctl() { [[ -x "$1/pg_ctl" || -x "$1/pg_ctl.exe" ]]; }

find_pg_bin() {
  if [[ -n "${PG_BIN:-}" ]]; then
    has_pg_ctl "$PG_BIN" || die "PG_BIN=$PG_BIN ne contient pas pg_ctl"
    echo "$PG_BIN"; return
  fi
  if command -v pg_ctl >/dev/null 2>&1; then dirname "$(command -v pg_ctl)"; return; fi
  if command -v pg_config >/dev/null 2>&1; then pg_config --bindir; return; fi
  local base best
  for base in "/c/Program Files/PostgreSQL" "/usr/lib/postgresql" "/usr/local/pgsql" "/opt/homebrew/opt/postgresql"; do
    [[ -d "$base" ]] || continue
    if has_pg_ctl "$base/bin"; then echo "$base/bin"; return; fi
    best="$(ls -1 "$base" 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$best" ]] && has_pg_ctl "$base/$best/bin"; then echo "$base/$best/bin"; return; fi
  done
  echo ""
}

PGBIN="$(find_pg_bin)"
[[ -n "$PGBIN" ]] || die "PostgreSQL introuvable : installez-le (PG ≥ 16) ou définissez PG_BIN=<dossier bin>"
# Les chemins avec espaces (C:\Program Files) cassent les commandes passées en variables :
# on met le dossier en tête du PATH et on appelle les binaires par leur nom.
export PATH="$PGBIN:$PATH"
export PGCLIENTENCODING=UTF8

db_url() { echo "postgres://$DB_USER@127.0.0.1:$PORT/$DB_NAME"; }
psql_db() { psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" -U "$DB_USER" -d "$DB_NAME" "$@"; }
is_running() { pg_ctl -D "$DATA_DIR" status >/dev/null 2>&1; }
is_initialized() { [[ -f "$DATA_DIR/PG_VERSION" ]]; }
is_migrated() {
  [[ "$(psql_db -At -c "SELECT to_regclass('public.agent_tasks') IS NOT NULL")" == "t" ]]
}

rand_hex() {  # 32 octets → 64 caractères hexadécimaux
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
  elif command -v python3 >/dev/null 2>&1; then python3 -c "import secrets; print(secrets.token_hex(32))"
  elif command -v python >/dev/null 2>&1; then python -c "import secrets; print(secrets.token_hex(32))"
  else od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; fi
}
sha256_hex() {  # hash SHA-256 (hex) de l'argument, comme services/agentKeys.ts hashKey()
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else die "ni sha256sum ni shasum"; fi
}

# --- Commandes -------------------------------------------------------------------------
cmd_init() {
  if is_initialized; then info "cluster déjà initialisé : $DATA_DIR"; return; fi
  mkdir -p "$DEV_DB_DIR"
  info "initdb → $DATA_DIR ($(pg_ctl --version))"
  # trust : base de DÉVELOPPEMENT, écoute limitée à 127.0.0.1 au démarrage (cmd_start).
  if ! initdb -D "$DATA_DIR" -U "$DB_USER" --auth=trust -E UTF8 --no-locale >"$DEV_DB_DIR/initdb.log" 2>&1; then
    cat "$DEV_DB_DIR/initdb.log" >&2
    die "initdb a échoué (sous Windows : ne pas lancer en administrateur)"
  fi
}

cmd_start() {
  is_initialized || die "cluster absent : lancez d'abord « init » (ou « up »)"
  if is_running; then info "déjà démarré sur 127.0.0.1:$PORT"; return; fi
  local opts="-p $PORT -c listen_addresses=127.0.0.1"
  # Hors Windows, le dossier de socket par défaut (/var/run/postgresql) n'est pas inscriptible.
  is_windows || opts="$opts -c unix_socket_directories=/tmp"
  info "démarrage sur 127.0.0.1:$PORT (journal : $LOG_FILE)"
  # Entrées/sorties détachées : sous Windows, pg_ctl et le serveur héritent sinon des
  # descripteurs de l'appelant (un pipeline `dev_db.sh up | tee` ne se terminerait jamais).
  if ! pg_ctl -D "$DATA_DIR" -o "$opts" -l "$LOG_FILE" -w start </dev/null >/dev/null 2>&1; then
    tail -20 "$LOG_FILE" >&2; die "démarrage impossible"
  fi
}

cmd_stop() {
  if ! is_initialized || ! is_running; then info "non démarré"; return; fi
  pg_ctl -D "$DATA_DIR" -m fast -w stop >/dev/null
  info "arrêté"
}

cmd_status() {
  if ! is_initialized; then echo "cluster : absent ($DATA_DIR)"; return 3; fi
  if is_running; then
    echo "cluster : démarré — $(db_url)"
    if is_migrated; then echo "schéma  : migré"; else echo "schéma  : vide (lancez « migrate »)"; fi
    [[ -f "$ENV_FILE" ]] && echo "dev.env : $ENV_FILE" || echo "dev.env : absent (lancez « seed »)"
  else
    echo "cluster : arrêté"; return 3
  fi
}

cmd_migrate() {
  is_running || die "base non démarrée (« start »)"
  local stub=1
  if [[ "$(psql_db -At -c "SELECT count(*) FROM pg_available_extensions WHERE name = 'vector'")" == "1" ]]; then
    stub=0; info "pgvector disponible : DDL vectoriel appliqué tel quel"
  else
    info "pgvector absent : DDL vectoriel réécrit en stub (vector(N) → real[], HNSW sauté)"
  fi
  local args=(--checks)
  (( stub )) && args+=(--stub-vector)
  if is_migrated; then
    # Les 4 migrations de février ne sont pas rejouables : on rejoue seulement les migrations rejouables
    # (>= 20260703000000), ce qui applique les nouvelles (idempotence prouvée par la CI).
    info "schéma déjà appliqué : mise à niveau (rejeu des migrations rejouables, nouvelles comprises)"
    args+=(--upgrade)
  fi
  PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER="$DB_USER" PGDATABASE="$DB_NAME" PSQL=psql PG_DUMP=pg_dump \
    bash "$ROOT/scripts/ci/apply_migrations.sh" "${args[@]}"
}

cmd_seed() {
  is_running || die "base non démarrée (« start »)"
  is_migrated || die "schéma absent (« migrate »)"
  local token="" key=""
  # Valeurs stables : réutilisées si dev.env existe déjà (les .env des services restent valides).
  if [[ -f "$ENV_FILE" ]]; then
    token="$(sed -n 's/^DEV_LOCAL_TOKEN=//p' "$ENV_FILE" | head -1)"
    key="$(sed -n 's/^SOULBAH_AGENT_KEY=//p' "$ENV_FILE" | head -1)"
  fi
  [[ ${#token} -ge 32 ]] || token="$(rand_hex)"
  [[ "$key" == sbk_* ]] || key="sbk_$(rand_hex)"

  local workspace="${SOULBAH_WORKSPACE:-$HOME/SoulbahWorkspace}"
  if is_windows && command -v cygpath >/dev/null 2>&1; then workspace="$(cygpath -w "$workspace")"; fi

  info "seed : utilisateur $DEV_USER_EMAIL ($DEV_USER_ID) + clé agent « $DEV_KEY_LABEL »"
  psql_db -v user_id="$DEV_USER_ID" -v email="$DEV_USER_EMAIL" -v key_hash="$(sha256_hex "$key")" \
    -v key_label="$DEV_KEY_LABEL" -v workspace="$workspace" -f "$ROOT/scripts/dev_db/seed_dev.sql"

  umask 077
  cat >"$ENV_FILE" <<EOF
# Généré par scripts/dev_db/dev_db.sh seed — base LOCALE jetable, NE PAS VERSIONNER (.gitignore).
# Charger dans le shell : set -a && source .dev_db/dev.env && set +a
# --- node-api / python-ia (backend/.env hors Docker) ---
SOULBAH_ENV=dev
HOST=127.0.0.1
DATABASE_URL=$(db_url)
DATABASE_SSL=false
PG_SSL_CA=
AUTH_MODE=dev-local
DEV_LOCAL_USER_ID=$DEV_USER_ID
DEV_LOCAL_TOKEN=$token
IA_SERVICE_URL=http://127.0.0.1:8000
LLM_FAKE_PROVIDER=1
# --- agent local (agent/.env) : clé de ce PC, dossier autorisé déclaré en base ---
SOULBAH_API_URL=http://127.0.0.1:3000
SOULBAH_AGENT_KEY=$key
SOULBAH_ALLOWED_DIRS=$workspace
# --- tests d'intégration node-api (Fastify inject sur ce Postgres) ---
TEST_DATABASE_URL=$(db_url)
EOF
  info "écrit : $ENV_FILE"
  echo "   Appel JWT de dev : curl -H \"Authorization: Bearer \$DEV_LOCAL_TOKEN\" http://127.0.0.1:3000/api/agent-tasks"
}

TEST_DB=soulbah_test
test_db_url() { echo "postgresql://$DB_USER@127.0.0.1:$PORT/$TEST_DB"; }

cmd_testdb() {
  is_running || die "base non démarrée (« start »)"
  info "base de test $TEST_DB : recréation (stub Supabase + migrations ×2 + contrôles + tests des migrations)"
  psql_db -q -c "DROP DATABASE IF EXISTS $TEST_DB WITH (FORCE)" -c "CREATE DATABASE $TEST_DB"
  local args=(--checks)
  if [[ "$(psql_db -At -c "SELECT count(*) FROM pg_available_extensions WHERE name = 'vector'")" != "1" ]]; then args+=(--stub-vector); fi
  PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER="$DB_USER" PGDATABASE="$TEST_DB" PSQL=psql PG_DUMP=pg_dump \
    bash "$ROOT/scripts/ci/apply_migrations.sh" "${args[@]}"
}

cmd_test() {
  is_running || die "base non démarrée (« start »)"
  if [[ "$(psql_db -At -c "SELECT count(*) FROM pg_database WHERE datname = '$TEST_DB'")" != "1" ]]; then cmd_testdb; fi
  info "tests d'intégration node-api sur $(test_db_url)"
  # Base de test DISTINCTE de la base de dev : l'appli locale (scheduler, relecteur P1) qui tourne sur la base
  # de dev n'agit pas sur les tâches des tests. Fichiers en série, comme la CI (npm run test:pg).
  ( cd "$ROOT/backend/node-api" && TEST_DATABASE_URL="$(test_db_url)" npx vitest run test/integration --no-file-parallelism "$@" )
}

cmd_up() {
  cmd_init
  cmd_start
  cmd_migrate
  cmd_seed
  cmd_status || true
}

cmd_reset() {
  cmd_stop
  rm -rf "$DATA_DIR"
  info "cluster supprimé"
  cmd_up
}

cmd_destroy() {
  cmd_stop
  rm -rf "$DEV_DB_DIR"
  info "supprimé : $DEV_DB_DIR"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)       cmd_up ;;
  init)     cmd_init ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_stop; cmd_start ;;
  status)   cmd_status ;;
  migrate)  cmd_migrate ;;
  seed)     cmd_seed ;;
  url)      db_url ;;
  env)      [[ -f "$ENV_FILE" ]] && cat "$ENV_FILE" || die "dev.env absent (« seed »)" ;;
  test)     cmd_test "$@" ;;
  testdb)   cmd_testdb ;;
  psql)     is_running || die "base non démarrée"; exec psql -h 127.0.0.1 -p "$PORT" -U "$DB_USER" -d "$DB_NAME" "$@" ;;
  reset)    cmd_reset ;;
  destroy)  cmd_destroy ;;
  -h|--help|help|"") sed -n '2,40p' "$0" ;;
  *) die "commande inconnue « $cmd » (voir --help)" ;;
esac
