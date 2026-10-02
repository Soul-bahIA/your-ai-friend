"""Reconstruit le modèle figé `soulbah_catchup_template` (DB LOT 0) — copie locale représentative de la base
restaurée, rattrapée au niveau du code, servant de point de départ à tout essai de migration.

    python scripts/db/build_catchup_template.py --backup backups/soulbah_<date>.sql.gpg \
        --dump backups/soulbah_<date>.dump.gpg --passphrase-file %USERPROFILE%\\.soulbah\\backup_passphrase.txt \
        --catalog db/baseline/<date>_restored/catalog.json --state db/baseline/<date>_restored/migration_state.json \
        --out db/dryrun/<date>

Étapes (chacune doit réussir, sinon arrêt) :
  1. test de restauration de la sauvegarde dans `soulbah_dryrun_copy` (scripts/db/restore_test.py) ;
  2. inscription (baseline) des migrations dont la présence est prouvée (verdict APPLIED) ;
  3. essai à blanc puis application du rattrapage (migrations du dépôt en attente + historique), pgvector simulé ;
  4. contrôles de la CI : schema_checks.sql, post_restore_checks.sql, api_role_checks.sql (+ droits soulbah_api) ;
  5. `soulbah_catchup_template` recréé depuis la copie, marqué modèle et fermé aux connexions.
Tout se passe sur le PostgreSQL LOCAL de développement ; la base Supabase n'est jamais contactée.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db_connect import DbError, client_env, parse, psql_path, run_sql  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ADMIN = os.environ.get("SOULBAH_TEST_PG", "postgresql://postgres@127.0.0.1:54329/postgres")
COPY_DB = "soulbah_dryrun_copy"
TEMPLATE = "soulbah_catchup_template"
PY = sys.executable


def step(name: str, args: list[str], log: list[dict]) -> str:
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    p = subprocess.run([PY, *args], capture_output=True, text=True, encoding="utf-8", errors="replace", env=env,
                       timeout=3600)
    out = (p.stdout + p.stderr)[-6000:]
    log.append({"step": name, "ok": p.returncode == 0, "output": out})
    print(f"{'OK   ' if p.returncode == 0 else 'ÉCHEC'}  {name}")
    if p.returncode != 0:
        print(out)
        raise DbError(f"étape « {name} » en échec")
    return out


def psql_checks(url: str, log: list[dict]) -> None:
    conn = parse(url)
    grants = (ROOT / "scripts" / "sql" / "soulbah_api_grants.sql").read_text("utf-8")
    api_checks = (ROOT / "scripts" / "ci" / "api_role_checks.sql").read_text("utf-8")
    api_checks = "\n".join(grants if line.strip() == "-- @@SOULBAH_API_GRANTS@@" else line
                           for line in api_checks.splitlines())
    for name, sql in (("schema_checks", (ROOT / "scripts" / "ci" / "schema_checks.sql").read_text("utf-8")),
                      ("post_restore_checks", (ROOT / "scripts" / "sql" / "post_restore_checks.sql").read_text("utf-8")),
                      ("api_role_checks", api_checks)):
        p = subprocess.run([psql_path(), "-w", "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True,
                           text=True, encoding="utf-8", errors="replace", env=client_env(conn), timeout=900)
        log.append({"step": name, "ok": p.returncode == 0, "output": (p.stdout + p.stderr)[-2000:]})
        print(f"{'OK   ' if p.returncode == 0 else 'ÉCHEC'}  {name}")
        if p.returncode != 0:
            print(p.stderr[-2000:])
            raise DbError(f"contrôle {name} en échec")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backup", required=True)
    ap.add_argument("--dump", required=True)
    ap.add_argument("--passphrase-file", required=True)
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    admin = parse(ADMIN)
    if not admin.is_local:
        raise DbError("le modèle se construit uniquement sur le PostgreSQL local")
    url = f"postgresql://{admin.user}@{admin.host}:{admin.port}/{COPY_DB}"
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    log: list[dict] = []
    db = str(ROOT / "scripts" / "db")
    step("test de restauration de la sauvegarde", [f"{db}/restore_test.py", "--backup", a.backup, "--dump", a.dump,
         "--passphrase-file", a.passphrase_file, "--source-catalog", a.catalog, "--target", url, "--out", str(out)], log)
    state = json.loads(Path(a.state).read_text("utf-8"))
    applied = ",".join(m["version"] for m in state if m["verdict"] == "APPLIED")
    step("inscription des migrations présentes (baseline)", [f"{db}/migrate.py", "baseline", "--target", url,
         "--versions", applied, "--evidence", a.state], log)
    step("essai à blanc du rattrapage", [f"{db}/migrate.py", "apply", "--target", url, "--pending", "--until",
         "20261002100000", "--stub-vector", "--dry-run", "--report", str(out / "dry_run_catchup.json")], log)
    step("application du rattrapage", [f"{db}/migrate.py", "apply", "--target", url, "--pending", "--until",
         "20261002100000", "--stub-vector", "--report", str(out / "apply_catchup.json")], log)
    step("vérification des empreintes", [f"{db}/migrate.py", "verify", "--target", url, "--pending"], log)
    psql_checks(url, log)
    run_sql(admin, f'ALTER DATABASE "{TEMPLATE}" IS_TEMPLATE false', read_only=False) if \
        run_sql(admin, f"SELECT 1 FROM pg_database WHERE datname = '{TEMPLATE}'").strip() == "1" else None
    run_sql(admin, f'DROP DATABASE IF EXISTS "{TEMPLATE}" WITH (FORCE)', read_only=False)
    run_sql(admin, f'CREATE DATABASE "{TEMPLATE}" TEMPLATE "{COPY_DB}"', read_only=False)
    run_sql(admin, f'ALTER DATABASE "{TEMPLATE}" IS_TEMPLATE true ALLOW_CONNECTIONS false', read_only=False)
    log.append({"step": "modèle figé recréé", "ok": True})
    print("OK     modèle figé recréé :", TEMPLATE)
    (out / "build_catchup_template.json").write_text(json.dumps(log, ensure_ascii=False, indent=1), "utf-8")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except DbError as e:
        print(f"✖ {e}", file=sys.stderr)
        sys.exit(1)
