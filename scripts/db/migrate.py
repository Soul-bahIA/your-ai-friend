"""Gestionnaire de migrations Soulbah — MigrationPlanner + exécution contrôlée (DB LOT 0).

    python scripts/db/migrate.py status   --target <cible> [--pending]
    python scripts/db/migrate.py plan     --target <cible> [--pending] [--catalog <catalog.json>]
    python scripts/db/migrate.py baseline --target <cible> --versions V1,V2,… --evidence <migration_state.json>
    python scripts/db/migrate.py apply    --target <cible> [--pending] [--until VERSION] [--dry-run]
    python scripts/db/migrate.py verify   --target <cible> [--pending]

Cibles : URL postgresql:// (voir db_connect.py ; « dev » = base locale de développement).

Sources : supabase/migrations/ (système existant, appliqué par la CI et `supabase db push`) puis, avec --pending,
supabase/migrations_pending/ (migrations préparées, jamais appliquées automatiquement). Ordre = version (14
chiffres en tête du nom de fichier).

Sécurité :
  * écriture (apply sans --dry-run, baseline) refusée sur tout hôte non local, sauf --allow-remote ET
    --approval <empreinte du plan> (sortie de `plan`) ET SOULBAH_MIGRATION_ALLOW_REMOTE=1 : trois clés ;
  * chaque migration s'exécute dans SA transaction, sous verrou consultatif de transaction
    (pg_advisory_xact_lock) ; l'historique est relu sous ce verrou : deux exécutions concurrentes ne peuvent
    pas appliquer deux fois la même migration ;
  * lock_timeout (10 s par défaut) : une migration n'attend pas indéfiniment un verrou de table ;
  * l'empreinte (SHA-256, fins de ligne normalisées) d'une migration déjà appliquée est vérifiée : un fichier
    modifié après application arrête tout (`verify`) ;
  * un échec annule la transaction de la migration ; il est consigné dans soulbah.schema_migration_runs par
    une transaction séparée (ajout seul) ;
  * --dry-run : chaque migration est exécutée puis ANNULÉE (ROLLBACK), rien n'est écrit, pas même l'historique.
En-têtes reconnus dans une migration : `-- soulbah:rollback=YES|PARTIAL|NO`, `-- soulbah:recovery=<texte>`,
`-- soulbah:transaction=single|none` (none : instructions hors transaction, ex. CREATE INDEX CONCURRENTLY).
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db_connect import Conn, DbError, connect, run_sql  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REPO_DIR = Path(os.environ.get("SOULBAH_MIGRATIONS_DIR") or ROOT / "supabase" / "migrations")
PENDING_DIR = Path(os.environ.get("SOULBAH_MIGRATIONS_PENDING_DIR") or ROOT / "supabase" / "migrations_pending")
HISTORY_BOOTSTRAP = "20261002100000"
# --stub-vector (bases LOCALES sans pgvector seulement) : DDL vectoriel réécrit comme en CI, noté dans l'historique.
STUB_VECTOR = False
STUB_NOTE = "pgvector simulé (vector → real[], index HNSW sautés) : base locale sans extension vector"


def exec_text(m: "Migration") -> str:
    if not STUB_VECTOR:
        return m.text
    from migration_state import stub_vector
    return stub_vector(m.text)
LOCK_KEY = "soulbah.schema_migrations"
NAME_RE = re.compile(r"^(\d{14})_(.+)\.sql$")


@dataclasses.dataclass(frozen=True)
class Migration:
    version: str
    name: str
    path: Path
    source: str  # repo | pending

    @property
    def text(self) -> str:
        return self.path.read_bytes().decode("utf-8")

    @property
    def checksum(self) -> str:
        return hashlib.sha256(self.text.replace("\r\n", "\n").encode("utf-8")).hexdigest()

    def header(self, key: str, default: str | None = None) -> str | None:
        m = re.search(rf"^--\s*soulbah:{key}=(.+)$", self.text, flags=re.MULTILINE)
        return m.group(1).strip() if m else default


def discover(pending: bool) -> list[Migration]:
    found: list[Migration] = []
    for source, folder in (("repo", REPO_DIR), ("pending", PENDING_DIR)):
        if source == "pending" and not pending:
            continue
        for f in sorted(folder.glob("*.sql")):
            if f.name.endswith((".down.sql", ".test.sql")):
                continue  # retour arrière et tests : jamais des migrations à appliquer
            m = NAME_RE.match(f.name)
            if m:
                found.append(Migration(m.group(1), m.group(2), f, source))
    versions = [m.version for m in found]
    dupes = {v for v in versions if versions.count(v) > 1}
    if dupes:
        raise DbError(f"versions en double : {sorted(dupes)}")
    return sorted(found, key=lambda m: m.version)


def sql_lit(value) -> str:
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def git_commit() -> str | None:
    try:
        return subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True,
                              text=True, timeout=10).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def history(conn: Conn) -> dict[str, dict] | None:
    present = run_sql(conn, "SELECT to_regclass('soulbah.schema_migrations') IS NOT NULL").strip() == "t"
    if not present:
        return None
    out = run_sql(conn, "SELECT coalesce(json_agg(row_to_json(m)), '[]') FROM soulbah.schema_migrations m").strip()
    return {r["version"]: r for r in json.loads(out)}


# --- Analyse statique des risques (§84-§87) ---------------------------------------------------------------
RISK_PATTERNS: list[tuple[str, str, str]] = [
    ("HIGH", r"\bDROP\s+(TABLE|SCHEMA|DATABASE)\b", "suppression de table, de schéma ou de base"),
    ("HIGH", r"(?:^|;)\s*TRUNCATE\s+(?:TABLE\s+)?[\w.\"]+", "TRUNCATE"),
    ("HIGH", r"\bALTER\s+TABLE\b[^;]*\bDROP\s+COLUMN\b", "suppression de colonne"),
    ("HIGH", r"\bALTER\s+TABLE\b[^;]*\bALTER\s+(COLUMN\s+)?\w+\s+(SET\s+DATA\s+)?TYPE\b", "changement de type de colonne (réécriture)"),
    ("HIGH", r"\bDELETE\s+FROM\b(?![^;]*\bWHERE\b)", "DELETE sans WHERE"),
    ("HIGH", r"\bUPDATE\s+[\w.]+\s+SET\b(?![^;]*\bWHERE\b)", "UPDATE sans WHERE"),
    ("MEDIUM", r"\bDELETE\s+FROM\b", "suppression de lignes"),
    ("MEDIUM", r"\bUPDATE\s+[\w.]+\s+SET\b", "modification de lignes existantes"),
    ("MEDIUM", r"\bSET\s+NOT\s+NULL\b", "SET NOT NULL (parcours complet sous verrou)"),
    ("MEDIUM", r"\bADD\s+CONSTRAINT\b(?![^;]*\bNOT\s+VALID\b)[^;]*\b(CHECK|FOREIGN\s+KEY)\b", "contrainte validée immédiatement (parcours sous verrou)"),
    ("MEDIUM", r"\bREVOKE\b", "retrait de droits (effet sur les clients)"),
    ("MEDIUM", r"\bDROP\s+POLICY\b", "suppression de policy (vérifier la policy de remplacement)"),
    ("MEDIUM", r"\bALTER\s+TABLE\b[^;]*\b(DISABLE|NO\s+FORCE)\s+ROW\s+LEVEL\s+SECURITY\b", "désactivation de RLS"),
    ("MEDIUM", r"\bSECURITY\s+DEFINER\b", "fonction SECURITY DEFINER (vérifier search_path et droits EXECUTE)"),
    ("LOW", r"\bCREATE\s+(UNIQUE\s+)?INDEX\b(?!\s+CONCURRENTLY)", "index créé hors CONCURRENTLY (bloque les écritures pendant la construction)"),
    ("LOW", r"\bDROP\s+(INDEX|TRIGGER|FUNCTION|VIEW|CONSTRAINT)\b", "suppression d'objet secondaire"),
    ("LOW", r"\bGRANT\b", "attribution de droits"),
]
RANK = {"LOW": 1, "MEDIUM": 2, "HIGH": 3}


def strip_comments(sql: str) -> str:
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    return re.sub(r"--[^\n]*", " ", sql)


FUNCTION_BODY = re.compile(r"(CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\b.*?\bAS\s+)(\$\w*\$)(.*?)\2",
                           re.IGNORECASE | re.DOTALL)


def strip_function_bodies(sql: str) -> str:
    """Corps de fonctions retirés : ils ne s'exécutent pas pendant la migration (contrairement aux blocs DO)."""
    return FUNCTION_BODY.sub(lambda mt: mt.group(1) + "$body$ /* corps de fonction */ $body$", sql)


def analyse(m: Migration) -> dict:
    body = strip_function_bodies(strip_comments(m.text))
    hits = []
    for level, pattern, label in RISK_PATTERNS:
        n = len(re.findall(pattern, body, flags=re.IGNORECASE))
        if n:
            hits.append({"level": level, "pattern": label, "count": n})
    level = max((h["level"] for h in hits), key=lambda lv: RANK[lv], default="NONE")
    return {"risk": level, "reasons": hits, "rollback": m.header("rollback", "NO"),
            "recovery": m.header("recovery"), "transaction": m.header("transaction", "single")}


def plan_digest(items: list[dict]) -> str:
    canon = json.dumps([(i["version"], i["checksum"]) for i in items], separators=(",", ":"))
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


def pending_list(conn: Conn, migrations: list[Migration]) -> tuple[list[Migration], list[dict]]:
    hist = history(conn) or {}
    todo, mismatched = [], []
    for m in migrations:
        h = hist.get(m.version)
        if h is None or h.get("status") == "rolled_back":
            todo.append(m)
        elif h["checksum"] != m.checksum:
            mismatched.append({"version": m.version, "name": m.name, "recorded": h["checksum"], "file": m.checksum})
    return todo, mismatched


def guard_write(conn: Conn, args, digest: str | None) -> None:
    if conn.is_local:
        return
    if not (args.allow_remote and os.environ.get("SOULBAH_MIGRATION_ALLOW_REMOTE") == "1"):
        raise DbError(f"refus : écriture sur une base distante ({conn.host}). Exige --allow-remote, "
                      "SOULBAH_MIGRATION_ALLOW_REMOTE=1 et --approval <empreinte du plan> (validation PDG).")
    if not digest or args.approval != digest:
        raise DbError("refus : --approval ne correspond pas à l'empreinte du plan actuel (relancer `plan`).")


def record_run(conn: Conn, m: Migration, action: str, status: str, ms: int | None, error: str | None,
               details: dict | None = None) -> None:
    if history(conn) is None:
        return
    run_sql(conn, f"""INSERT INTO soulbah.schema_migration_runs
      (version, action, status, checksum, execution_ms, error, app_commit, details)
      VALUES ({sql_lit(m.version)}, {sql_lit(action)}, {sql_lit(status)}, {sql_lit(m.checksum)}, {ms if ms is not None else 'NULL'},
              {sql_lit(error[:4000] if error else None)}, {sql_lit(git_commit())}, {sql_lit(json.dumps(details or {}))}::jsonb)""",
            read_only=False)


def apply_one(conn: Conn, m: Migration, *, dry_run: bool, lock_timeout: str, statement_timeout: str) -> tuple[str, int, str | None]:
    """Renvoie (statut, durée ms, erreur). statut : applied | skipped | dry_run_ok | failed."""
    info = analyse(m)
    guard = f"""SELECT pg_advisory_xact_lock(hashtext({sql_lit(LOCK_KEY)}));
SET LOCAL lock_timeout = {sql_lit(lock_timeout)};
SET LOCAL statement_timeout = {sql_lit(statement_timeout)};
DO $soulbah_guard$ BEGIN
  -- Deux IF imbriqués : la requête sur l'historique n'est préparée que si la table existe.
  IF to_regclass('soulbah.schema_migrations') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM soulbah.schema_migrations
                WHERE version = {sql_lit(m.version)} AND status IN ('applied', 'baselined')) THEN
      RAISE EXCEPTION 'SOULBAH_MIGRATION_ALREADY_APPLIED';
    END IF;
  END IF;
END $soulbah_guard$;"""
    record = f"""INSERT INTO soulbah.schema_migrations
  (version, name, checksum, source, status, rollback, recovery, execution_ms, app_commit, notes)
VALUES ({sql_lit(m.version)}, {sql_lit(m.name)}, {sql_lit(m.checksum)}, {sql_lit(m.source)}, 'applied',
        {sql_lit(info['rollback'])}, {sql_lit(info['recovery'])},
        (extract(epoch FROM clock_timestamp() - transaction_timestamp()) * 1000)::int, {sql_lit(git_commit())},
        {sql_lit(STUB_NOTE if STUB_VECTOR else None)})
ON CONFLICT (version) DO UPDATE SET name = EXCLUDED.name, checksum = EXCLUDED.checksum, status = 'applied',
  rollback = EXCLUDED.rollback, recovery = EXCLUDED.recovery, executed_at = now(),
  execution_ms = EXCLUDED.execution_ms, applied_by = current_user, app_commit = EXCLUDED.app_commit,
  notes = EXCLUDED.notes;
INSERT INTO soulbah.schema_migration_runs (version, action, status, checksum, execution_ms, app_commit)
VALUES ({sql_lit(m.version)}, 'apply', 'succeeded', {sql_lit(m.checksum)},
        (extract(epoch FROM clock_timestamp() - transaction_timestamp()) * 1000)::int, {sql_lit(git_commit())});"""
    if info["transaction"] == "none":
        if dry_run:
            return "dry_run_skipped_non_transactional", 0, None
        script = exec_text(m)  # instructions hors transaction (ex. CREATE INDEX CONCURRENTLY) : à rejouer sans risque
        tail = "BEGIN;\n" + guard.split("DO $soulbah_guard$")[0] + record + "\nCOMMIT"
    else:
        end = "ROLLBACK" if dry_run else "COMMIT"
        script = ("SET client_min_messages = warning;\nBEGIN;\n" + guard + "\n" + exec_text(m) + "\n;\n"
                  + ("" if dry_run else record) + f"\n{end}")
        tail = None
    t0 = time.monotonic()
    try:
        run_sql(conn, script, read_only=False, timeout_s=3600)
        if tail:
            run_sql(conn, tail, read_only=False)
    except DbError as e:
        ms = int((time.monotonic() - t0) * 1000)
        msg = str(e)
        if "SOULBAH_MIGRATION_ALREADY_APPLIED" in msg:
            return "skipped", ms, None
        if not dry_run:
            try:
                record_run(conn, m, "apply", "failed", ms, msg)
            except DbError:
                pass
        return "failed", ms, msg
    ms = int((time.monotonic() - t0) * 1000)
    return ("dry_run_ok" if dry_run else "applied"), ms, None


def cmd_status(conn: Conn, a) -> int:
    migrations = discover(a.pending)
    hist = history(conn)
    if hist is None:
        print("Historique absent (soulbah.schema_migrations) : état déductible seulement des objets "
              "(scripts/db/migration_state.py).")
        hist = {}
    for m in migrations:
        h = hist.get(m.version)
        state = h["status"] if h else "pending"
        flag = "" if not h or h["checksum"] == m.checksum else "  ⚠ empreinte différente du fichier"
        print(f"{m.version}  {m.source:<7}  {state:<11}  {m.name}{flag}")
    return 0


def cmd_plan(conn: Conn, a) -> int:
    migrations = discover(a.pending)
    todo, mismatched = pending_list(conn, migrations)
    if a.until:
        todo = [m for m in todo if m.version <= a.until]
    items = [{"version": m.version, "name": m.name, "source": m.source, "checksum": m.checksum, **analyse(m)}
             for m in todo]
    digest = plan_digest(items)
    out = {"target": conn.label(), "pending": items, "checksum_mismatch": mismatched, "plan_digest": digest}
    if a.json:
        print(json.dumps(out, ensure_ascii=False, indent=1))
    else:
        for i in items:
            reasons = "; ".join(f"{r['pattern']} ×{r['count']}" for r in i["reasons"]) or "aucun motif à risque"
            print(f"{i['version']}  {i['risk']:<6} rollback={i['rollback']:<7} {i['name']}  — {reasons}")
        print(f"\n{len(items)} migration(s) en attente · empreinte du plan : {digest}")
        for x in mismatched:
            print(f"⚠ {x['version']} {x['name']} : fichier modifié après application")
    return 1 if mismatched else 0


def cmd_baseline(conn: Conn, a) -> int:
    wanted_versions = [v.strip() for v in a.versions.split(",") if v.strip()]
    by_version = {m.version: m for m in discover(True)}
    guard_write(conn, a, plan_digest([{"version": v, "checksum": by_version[v].checksum}
                                      for v in wanted_versions if v in by_version]))
    if not a.evidence or not Path(a.evidence).exists():
        raise DbError("--evidence <migration_state.json> requis : une baseline ne se déclare pas sans preuve")
    state = {r["version"]: r for r in json.loads(Path(a.evidence).read_text("utf-8"))}
    wanted = [v.strip() for v in a.versions.split(",") if v.strip()]
    migrations = {m.version: m for m in discover(True)}
    if history(conn) is None:
        boot = migrations.get(HISTORY_BOOTSTRAP)
        if boot is None:
            raise DbError("migration d'historique introuvable (supabase/migrations_pending)")
        status, ms, err = apply_one(conn, boot, dry_run=False, lock_timeout=a.lock_timeout,
                                    statement_timeout=a.statement_timeout)
        if status != "applied":
            raise DbError(f"création de l'historique impossible : {err}")
    for v in wanted:
        m = migrations.get(v)
        if m is None:
            raise DbError(f"migration inconnue : {v}")
        verdict = (state.get(v) or {}).get("verdict")
        if verdict not in ("APPLIED", "NO_SCHEMA_CHANGE") and not a.force_partial:
            raise DbError(f"{v} : verdict « {verdict} » dans la preuve — refus (--force-partial pour une décision explicite)")
        note = f"baseline : objets vérifiés ({verdict}) — {Path(a.evidence).name}"
        run_sql(conn, f"""BEGIN;
SELECT pg_advisory_xact_lock(hashtext({sql_lit(LOCK_KEY)}));
INSERT INTO soulbah.schema_migrations (version, name, checksum, source, status, rollback, notes, app_commit)
VALUES ({sql_lit(m.version)}, {sql_lit(m.name)}, {sql_lit(m.checksum)}, {sql_lit(m.source)}, 'baselined', 'NO',
        {sql_lit(note)}, {sql_lit(git_commit())})
ON CONFLICT (version) DO NOTHING;
INSERT INTO soulbah.schema_migration_runs (version, action, status, checksum, app_commit, details)
VALUES ({sql_lit(m.version)}, 'baseline', 'succeeded', {sql_lit(m.checksum)}, {sql_lit(git_commit())},
        {sql_lit(json.dumps({'verdict': verdict}))}::jsonb);
COMMIT""", read_only=False)
        print(f"baseline  {m.version}  {m.name}  ({verdict})")
    return 0


def dry_run_sequence(conn: Conn, todo: list[Migration], a) -> int:
    """Toute la séquence dans UNE transaction annulée à la fin : chaque migration voit les effets des
    précédentes, rien n'est écrit. Les migrations hors transaction (transaction=none) sont signalées, non jouées."""
    parts = ["SET client_min_messages = warning;", "BEGIN;",
             f"SET LOCAL lock_timeout = {sql_lit(a.lock_timeout)};",
             f"SET LOCAL statement_timeout = {sql_lit(a.statement_timeout)};"]
    skipped = []
    for m in todo:
        if analyse(m)["transaction"] == "none":
            skipped.append(m)
            continue
        parts += [f"\\echo SOULBAH_MIGRATION_START {m.version}", exec_text(m), ";"]
    parts += ["\\echo SOULBAH_DRY_RUN_COMPLETE", "ROLLBACK"]
    t0 = time.monotonic()
    error, last = None, None
    try:
        out = run_sql(conn, "\n".join(parts), read_only=False, timeout_s=3600, tuples_only=True)
    except DbError as e:
        error = str(e)
        out = getattr(e, "stdout", "") or ""
    starts = re.findall(r"SOULBAH_MIGRATION_START (\d{14})", out)
    last = starts[-1] if starts else None
    ms = int((time.monotonic() - t0) * 1000)
    ok = error is None and "SOULBAH_DRY_RUN_COMPLETE" in out
    for m in todo:
        if m in skipped:
            state = "not_run_non_transactional"
        elif ok:
            state = "dry_run_ok"
        elif last and m.version < last:
            state = "dry_run_ok"
        elif last == m.version:
            state = "failed"
        else:
            state = "not_reached"
        print(f"{state:<26} {m.version}  {m.name}")
    print(f"essai à blanc {'réussi' if ok else 'en échec'} en {ms} ms (transaction annulée, rien d'écrit)")
    if error:
        print(f"    {error.strip()[:1500]}")
    if a.report:
        Path(a.report).write_text(json.dumps({"target": conn.label(), "dry_run": True, "ok": ok, "ms": ms,
                                              "failed_at": None if ok else last, "error": error,
                                              "migrations": [m.version for m in todo],
                                              "not_run": [m.version for m in skipped]}, ensure_ascii=False, indent=1),
                                  "utf-8")
    return 0 if ok else 1


def cmd_apply(conn: Conn, a) -> int:
    migrations = discover(a.pending)
    todo, mismatched = pending_list(conn, migrations)
    if mismatched:
        for x in mismatched:
            print(f"✖ {x['version']} {x['name']} : fichier modifié après application — arrêt", file=sys.stderr)
        return 1
    if a.until:
        todo = [m for m in todo if m.version <= a.until]
    if a.dry_run:
        return dry_run_sequence(conn, todo, a)
    items = [{"version": m.version, "checksum": m.checksum} for m in todo]
    guard_write(conn, a, plan_digest(items))
    if history(conn) is None:
        boot = next((m for m in todo if m.version == HISTORY_BOOTSTRAP), None)
        if boot is None:
            raise DbError("historique absent : relancer avec --pending (migration 20261002100000)")
        todo = [boot] + [m for m in todo if m is not boot]
    results = []
    failed = False
    for m in todo:
        status, ms, err = apply_one(conn, m, dry_run=False, lock_timeout=a.lock_timeout,
                                    statement_timeout=a.statement_timeout)
        results.append({"version": m.version, "name": m.name, "status": status, "ms": ms, "error": err})
        print(f"{status:<14} {ms:>7} ms  {m.version}  {m.name}" + (f"\n    {err.strip()[:800]}" if err else ""))
        if status == "failed":
            failed = True
            break
    if a.report:
        Path(a.report).write_text(json.dumps({"target": conn.label(), "dry_run": False, "results": results},
                                             ensure_ascii=False, indent=1), "utf-8")
    return 1 if failed else 0


def cmd_verify(conn: Conn, a) -> int:
    migrations = discover(a.pending)
    hist = history(conn)
    if hist is None:
        print("Historique absent : rien à vérifier.")
        return 1
    _, mismatched = pending_list(conn, migrations)
    unknown = sorted(set(hist) - {m.version for m in migrations})
    for x in mismatched:
        print(f"✖ {x['version']} {x['name']} : empreinte enregistrée {x['recorded'][:12]}… ≠ fichier {x['file'][:12]}…")
    for v in unknown:
        print(f"⚠ {v} : présente dans l'historique, absente des fichiers")
    if not mismatched and not unknown:
        print(f"OK : {len(hist)} migration(s) enregistrée(s), empreintes conformes aux fichiers.")
    return 1 if mismatched or unknown else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["status", "plan", "baseline", "apply", "verify"])
    ap.add_argument("--target", required=True)
    ap.add_argument("--pending", action="store_true", help="inclure supabase/migrations_pending/")
    ap.add_argument("--until", help="dernière version incluse")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--report", help="fichier JSON du compte rendu (apply)")
    ap.add_argument("--versions", default="", help="baseline : versions séparées par des virgules")
    ap.add_argument("--evidence", help="baseline : migration_state.json prouvant la présence des objets")
    ap.add_argument("--force-partial", action="store_true")
    ap.add_argument("--allow-remote", action="store_true")
    ap.add_argument("--approval", help="empreinte du plan validé (écriture distante)")
    ap.add_argument("--lock-timeout", default="10s")
    ap.add_argument("--statement-timeout", default="15min")
    ap.add_argument("--stub-vector", action="store_true",
                    help="base LOCALE sans pgvector : DDL vectoriel simulé (noté dans l'historique)")
    a = ap.parse_args(argv)
    conn = connect(a.target)
    if a.stub_vector:
        if not conn.is_local:
            raise DbError("--stub-vector est réservé aux bases locales (jamais sur Supabase)")
        global STUB_VECTOR
        STUB_VECTOR = True
    return {"status": cmd_status, "plan": cmd_plan, "baseline": cmd_baseline, "apply": cmd_apply,
            "verify": cmd_verify}[a.command](conn, a)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except DbError as e:
        print(f"✖ {e}", file=sys.stderr)
        sys.exit(1)
