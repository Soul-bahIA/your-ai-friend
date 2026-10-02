#!/usr/bin/env bash
# Sauvegarde de la base SoulBah AI (Postgres Supabase) avec pg_dump.
#
# Produit, dans backups/ (ignoré par git) :
#   backups/soulbah_YYYYMMDD_HHMM.dump  — format custom (restauration sélective via pg_restore)
#   backups/soulbah_YYYYMMDD_HHMM.sql   — format texte (lisible, restaurable via psql)
# (+ .gpg / .age si le chiffrement est configuré, voir plus bas)
#
# Source de la connexion (par ordre de priorité) :
#   1. BACKUP_DATABASE_URL (variable d'environnement)
#   2. DATABASE_ADMIN_URL, sinon DATABASE_URL, lu dans backend/.env
# Le pooler Supabase en mode transaction (port 6543) est remplacé par le mode
# session (port 5432), seul compatible avec pg_dump.
#
# Secret : le mot de passe n'apparaît JAMAIS sur la ligne de commande de pg_dump
# (visible par `ps`). L'URL est décomposée en PGHOST/PGPORT/PGUSER/PGDATABASE et le
# mot de passe est écrit dans un fichier pgpass temporaire (droits 600, PGPASSFILE),
# supprimé à la sortie du script.
#
# Schémas sauvegardés : BACKUP_SCHEMAS (défaut : "public auth").
# Dossier de sortie    : BACKUP_DIR (défaut : backups/ à la racine du dépôt).
#
# Chiffrement OBLIGATOIRE par défaut (S30 : le dump contient toutes les données, dont
# les empreintes de mots de passe d'auth.users) — une des variables :
#   BACKUP_AGE_RECIPIENT=age1…            → age  -r <clé publique>      (fichiers .age)
#   BACKUP_GPG_RECIPIENT=<id ou e-mail>   → gpg --encrypt (clé publique) (fichiers .gpg)
#   BACKUP_GPG_PASSPHRASE_FILE=<fichier>  → gpg --symmetric AES256, phrase lue dans le fichier
# Après chiffrement réussi, les fichiers en clair sont supprimés
# (BACKUP_KEEP_PLAINTEXT=1 pour les garder). Sans aucune de ces variables, le script
# REFUSE de s'exécuter (code 2), sauf BACKUP_ALLOW_PLAINTEXT=1 (dump en clair assumé,
# par exemple pour une base jetable).
#
# Droits (S19) : les GRANT/REVOKE sont CONSERVÉS dans le dump (pas de --no-privileges) :
# une restauration ne doit pas rendre has_role / is_admin à PUBLIC ou anon. Seule la
# propriété des objets est omise (--no-owner). Restauration : README.md « Sauvegardes ».
#
# Vérification TLS stricte (facultatif) : PGSSLMODE=verify-full PGSSLROOTCERT=<CA Supabase>.
#
# Usage (git-bash / Linux / macOS, depuis n'importe où) :
#   BACKUP_GPG_PASSPHRASE_FILE=~/.soulbah/backup_passphrase.txt bash scripts/backup_db.sh
#   BACKUP_AGE_RECIPIENT="age1…" BACKUP_SCHEMAS="public" bash scripts/backup_db.sh
#   BACKUP_ALLOW_PLAINTEXT=1 bash scripts/backup_db.sh          # en clair, explicitement
#
# Prérequis : pg_dump dans le PATH, version >= à celle du serveur
# (Windows : C:\Program Files\PostgreSQL\<version>\bin).
#
# Tests : scripts/ci/test_backup_db.sh (source ce fichier pour tester les fonctions).

# Décodage « pourcent » de l'URL (RFC 3986). Le « + » n'est PAS un espace dans
# userinfo / chemin (seulement dans un formulaire HTML) : libpq et node-api le gardent
# tel quel, on fait de même. Les antislashs littéraux sont préservés (printf %b).
urldecode() {
  local s="${1//\\/\\\\}"
  printf '%b' "${s//%/\\x}"
}

# Échappement d'un champ du fichier pgpass (« \ » et « : »).
pgpass_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//:/\\:}"; }

# Sourcé (tests) : seules les fonctions ci-dessus sont définies.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/backend/.env"
OUT_DIR="${BACKUP_DIR:-$ROOT/backups}"
SCHEMAS="${BACKUP_SCHEMAS:-public auth}"

# --- Chiffrement : décidé AVANT toute lecture de secret ou connexion (échec rapide) ----
ENCRYPT=""
if [[ -n "${BACKUP_AGE_RECIPIENT:-}" ]]; then
  command -v age >/dev/null 2>&1 || { echo "Erreur : BACKUP_AGE_RECIPIENT défini mais 'age' introuvable." >&2; exit 1; }
  ENCRYPT="age"
elif [[ -n "${BACKUP_GPG_RECIPIENT:-}" || -n "${BACKUP_GPG_PASSPHRASE_FILE:-}" ]]; then
  command -v gpg >/dev/null 2>&1 || { echo "Erreur : chiffrement gpg demandé mais 'gpg' introuvable." >&2; exit 1; }
  if [[ -z "${BACKUP_GPG_RECIPIENT:-}" && ! -r "${BACKUP_GPG_PASSPHRASE_FILE}" ]]; then
    echo "Erreur : BACKUP_GPG_PASSPHRASE_FILE illisible : ${BACKUP_GPG_PASSPHRASE_FILE}" >&2; exit 1
  fi
  ENCRYPT="gpg"
elif [[ "${BACKUP_ALLOW_PLAINTEXT:-0}" != "1" ]]; then
  {
    echo "REFUS : aucun chiffrement configuré (S30) — le dump contiendrait toutes les données en clair,"
    echo "        y compris les empreintes de mots de passe (schéma auth)."
    echo "        Définir BACKUP_AGE_RECIPIENT, BACKUP_GPG_RECIPIENT ou BACKUP_GPG_PASSPHRASE_FILE,"
    echo "        ou BACKUP_ALLOW_PLAINTEXT=1 pour assumer explicitement un dump en clair."
  } >&2
  exit 2
fi

DB_URL="${BACKUP_DATABASE_URL:-}"
if [[ -z "$DB_URL" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Erreur : $ENV_FILE introuvable et BACKUP_DATABASE_URL non défini." >&2
    exit 1
  fi
  # Dernière définition de DATABASE_URL, sans \r (fichiers édités sous Windows) ni guillemets.
  # DATABASE_ADMIN_URL (rôle postgres) de préférence : DATABASE_URL est celle de node-api (soulbah_api, sans accès à auth).
  DB_URL="$(tr -d '\r' < "$ENV_FILE" | grep -E '^[[:space:]]*DATABASE_ADMIN_URL=' | tail -n 1 | cut -d= -f2-)"
  [ -n "$DB_URL" ] || DB_URL="$(tr -d '\r' < "$ENV_FILE" | grep -E '^[[:space:]]*DATABASE_URL=' | tail -n 1 | cut -d= -f2-)"
  DB_URL="${DB_URL%\"}"; DB_URL="${DB_URL#\"}"
  DB_URL="${DB_URL%\'}"; DB_URL="${DB_URL#\'}"
fi
if [[ -z "$DB_URL" ]]; then
  echo "Erreur : DATABASE_URL vide dans $ENV_FILE." >&2
  exit 1
fi

# --- Décomposition de l'URL postgres[ql]://user:pass@host:port/db?params -------------
case "$DB_URL" in
  postgres://*|postgresql://*) ;;
  *) echo "Erreur : DATABASE_URL doit commencer par postgres:// ou postgresql://" >&2; exit 1 ;;
esac
rest="${DB_URL#*://}"
userinfo=""; hostpart="$rest"
if [[ "$rest" == *@* ]]; then
  userinfo="${rest%@*}"        # dernier @ : le mot de passe encodé ne contient pas de @
  hostpart="${rest##*@}"
fi
db_user="${userinfo%%:*}"
db_pass=""
[[ "$userinfo" == *:* ]] && db_pass="${userinfo#*:}"
hostport="${hostpart%%/*}"
db_name="postgres"; query=""
if [[ "$hostpart" == */* ]]; then
  dbq="${hostpart#*/}"
  db_name="${dbq%%\?*}"
  [[ "$dbq" == *\?* ]] && query="${dbq#*\?}"
fi
db_host="${hostport%%:*}"
db_port="5432"
[[ "$hostport" == *:* ]] && db_port="${hostport##*:}"

# Pooler Supabase : mode transaction (6543) → mode session (5432).
if [[ "$db_host" == *pooler.supabase.com && "$db_port" == "6543" ]]; then
  db_port=5432
fi

# sslmode éventuel de l'URL ; PGSSLMODE=require par défaut (Supabase exige TLS).
if [[ "$query" =~ (^|&)sslmode=([^&]+) ]]; then
  export PGSSLMODE="${PGSSLMODE:-${BASH_REMATCH[2]}}"
fi
export PGSSLMODE="${PGSSLMODE:-require}"

export PGHOST="$db_host" PGPORT="$db_port" PGDATABASE="$(urldecode "${db_name:-postgres}")"
export PGUSER="$(urldecode "$db_user")"
export PGAPPNAME="soulbah-backup"

TMP_DIR="$(mktemp -d)"
BASE=""
cleanup() {
  local rc=$?
  rm -rf "$TMP_DIR"
  # Échec : ne pas laisser de dump partiel (ou en clair) derrière soi.
  if (( rc != 0 )) && [[ -n "$BASE" ]]; then
    rm -f "$BASE.dump" "$BASE.sql" "$BASE.dump.age" "$BASE.sql.age" "$BASE.dump.gpg" "$BASE.sql.gpg"
  fi
}
trap cleanup EXIT
if [[ -n "$db_pass" ]]; then
  printf '%s:%s:%s:%s:%s\n' \
    "$(pgpass_escape "$PGHOST")" "$PGPORT" '*' "$(pgpass_escape "$PGUSER")" \
    "$(pgpass_escape "$(urldecode "$db_pass")")" > "$TMP_DIR/pgpass"
  chmod 600 "$TMP_DIR/pgpass"
  export PGPASSFILE="$TMP_DIR/pgpass"
fi
unset db_pass userinfo rest DB_URL
unset PGPASSWORD   # jamais de mot de passe dans l'environnement hérité

if ! command -v pg_dump >/dev/null 2>&1; then
  for d in "/c/Program Files/PostgreSQL"/*/bin; do
    [[ -x "$d/pg_dump.exe" || -x "$d/pg_dump" ]] && PATH="$d:$PATH"
  done
fi
command -v pg_dump >/dev/null 2>&1 || { echo "Erreur : pg_dump introuvable (installez les outils client PostgreSQL)." >&2; exit 1; }

encrypt_file() {
  local f="$1"
  case "$ENCRYPT" in
    age)
      age -r "$BACKUP_AGE_RECIPIENT" -o "$f.age" "$f" ;;
    gpg)
      if [[ -n "${BACKUP_GPG_RECIPIENT:-}" ]]; then
        gpg --batch --yes --encrypt --recipient "$BACKUP_GPG_RECIPIENT" --output "$f.gpg" "$f"
      else
        gpg --batch --yes --pinentry-mode loopback --symmetric --cipher-algo AES256 \
          --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" --output "$f.gpg" "$f"
      fi ;;
  esac
}

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d_%H%M)"
BASE="$OUT_DIR/soulbah_$STAMP"

SCHEMA_ARGS=()
for s in $SCHEMAS; do SCHEMA_ARGS+=(--schema="$s"); done

echo "pg_dump $(pg_dump --version | awk '{print $NF}') — $PGUSER@$PGHOST:$PGPORT/$PGDATABASE (sslmode=$PGSSLMODE) — schémas : $SCHEMAS"

# Droits conservés (pas de --no-privileges) : voir l'en-tête (S19).
echo "→ $BASE.dump (format custom)"
pg_dump --format=custom --no-owner "${SCHEMA_ARGS[@]}" --file="$BASE.dump"

echo "→ $BASE.sql (format texte)"
pg_dump --format=plain --no-owner "${SCHEMA_ARGS[@]}" --file="$BASE.sql"

if [[ -n "$ENCRYPT" ]]; then
  for f in "$BASE.dump" "$BASE.sql"; do
    echo "→ chiffrement $ENCRYPT : $f"
    encrypt_file "$f"
    [[ "${BACKUP_KEEP_PLAINTEXT:-0}" == "1" ]] || rm -f "$f"
  done
  ls -lh "$BASE".*
else
  ls -lh "$BASE.dump" "$BASE.sql"
  echo "ATTENTION : sauvegarde NON chiffrée (BACKUP_ALLOW_PLAINTEXT=1) : toutes les données en clair." >&2
fi
echo "Sauvegarde terminée."
