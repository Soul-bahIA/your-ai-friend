#!/usr/bin/env bash
# Tests de scripts/backup_db.sh (S30, S19).
#
#   1. Décodage de l'URL : « + » littéral conservé (comme libpq / node-api), %XX décodé,
#      antislash littéral intact ; échappement pgpass.
#   2. Sans chiffrement ni BACKUP_ALLOW_PLAINTEXT=1 : refus (code 2) AVANT toute lecture
#      de backend/.env ou connexion, aucun fichier écrit.
#   3. Intégration (facultative) si BACKUP_TEST_DATABASE_URL pointe vers une base JETABLE
#      (migrations appliquées, p. ex. par scripts/ci/apply_migrations.sh) : dump en clair
#      explicite, droits conservés dans le dump (ACL de has_role), mot de passe avec « + ».
#
# Usage : bash scripts/ci/test_backup_db.sh
#         BACKUP_TEST_DATABASE_URL=postgresql://u:p@127.0.0.1:55432/base?sslmode=disable \
#           bash scripts/ci/test_backup_db.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/backup_db.sh"
failures=0

check() {  # libellé, attendu, obtenu
  if [[ "$2" == "$3" ]]; then
    echo "ok    $1"
  else
    echo "ÉCHEC $1 : attendu «$2», obtenu «$3»"
    failures=$((failures + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1) Fonctions (le script sourcé ne définit que ses fonctions) ----------------------
# shellcheck source=../backup_db.sh
source "$SCRIPT"
check "urldecode : + littéral conservé"     'a+b9xQ'      "$(urldecode 'a+b9xQ')"
check "urldecode : %2B → +"                 'a+b'         "$(urldecode 'a%2Bb')"
check "urldecode : caractères réservés"     'p@ss:w/rd'   "$(urldecode 'p%40ss%3Aw%2Frd')"
check "urldecode : espace encodé"           'a b'         "$(urldecode 'a%20b')"
check "urldecode : %25 → %"                 '100%'        "$(urldecode '100%25')"
check "urldecode : UTF-8"                   'é'           "$(urldecode '%C3%A9')"
check "urldecode : antislash littéral"      'a\nb'        "$(urldecode 'a\nb')"
check "pgpass_escape : « : » et « \\ »"     'a\:b\\c'     "$(pgpass_escape 'a:b\c')"

# --- 2) Refus du dump en clair ------------------------------------------------------
out="$(env -u BACKUP_AGE_RECIPIENT -u BACKUP_GPG_RECIPIENT -u BACKUP_GPG_PASSPHRASE_FILE \
        -u BACKUP_ALLOW_PLAINTEXT \
        BACKUP_DIR="$TMP/refus" BACKUP_DATABASE_URL='postgresql://u:p@127.0.0.1:1/db' \
        bash "$SCRIPT" 2>&1)"
rc=$?
check "sans chiffrement : code de sortie" 2 "$rc"
check "sans chiffrement : message REFUS" 1 "$(grep -c '^REFUS' <<< "$out")"
check "sans chiffrement : aucun fichier écrit" 0 "$(find "$TMP" -type f | wc -l | tr -d ' ')"

out="$(env -u BACKUP_AGE_RECIPIENT -u BACKUP_GPG_RECIPIENT -u BACKUP_ALLOW_PLAINTEXT \
        BACKUP_GPG_PASSPHRASE_FILE="$TMP/absent.txt" \
        BACKUP_DIR="$TMP/refus" BACKUP_DATABASE_URL='postgresql://u:p@127.0.0.1:1/db' \
        bash "$SCRIPT" 2>&1)"
rc=$?
check "phrase de passe illisible : échec" 1 "$(( rc != 0 ))"
check "phrase de passe illisible : aucun fichier écrit" 0 "$(find "$TMP" -type f | wc -l | tr -d ' ')"

# --- 3) Intégration sur une base jetable (facultative) --------------------------------
if [[ -n "${BACKUP_TEST_DATABASE_URL:-}" ]]; then
  echo "--- intégration : $(sed -E 's#://([^:/@]*):[^@]*@#://\1:***@#' <<< "$BACKUP_TEST_DATABASE_URL")"
  BACKUP_ALLOW_PLAINTEXT=1 BACKUP_DIR="$TMP/int" BACKUP_SCHEMAS="${BACKUP_TEST_SCHEMAS:-public}" \
    BACKUP_DATABASE_URL="$BACKUP_TEST_DATABASE_URL" bash "$SCRIPT" > "$TMP/int.log" 2>&1
  rc=$?
  check "intégration : sauvegarde en clair explicite (code)" 0 "$rc"
  (( rc == 0 )) || sed 's/^/      /' "$TMP/int.log"
  dump="$(ls "$TMP"/int/soulbah_*.dump 2>/dev/null | head -n 1)"
  sql="$(ls "$TMP"/int/soulbah_*.sql 2>/dev/null | head -n 1)"
  check "intégration : .dump et .sql produits" 2 "$(ls "$TMP"/int/soulbah_* 2>/dev/null | wc -l | tr -d ' ')"
  if [[ -n "$dump" && -n "$sql" ]]; then
    check "intégration : ACL de has_role dans le .dump (S19)" 1 \
      "$(pg_restore -l "$dump" | grep -c 'ACL public FUNCTION has_role')"
    check "intégration : REVOKE … FROM PUBLIC dans le .sql (S19)" 1 \
      "$(grep -c 'REVOKE ALL ON FUNCTION public.has_role(_user_id uuid, _role public.app_role) FROM PUBLIC' "$sql")"
  fi
fi

if (( failures > 0 )); then
  echo "test_backup_db.sh : $failures échec(s)"
  exit 1
fi
echo "test_backup_db.sh : tous les tests sont passés"
