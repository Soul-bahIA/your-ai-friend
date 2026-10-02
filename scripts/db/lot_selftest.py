"""Banc d'essai d'un ou plusieurs lots de migrations préparées (DB LOT 0) — sur une copie jetable.

    python scripts/db/lot_selftest.py --name <étiquette> --lots 01,02[,…] [--keep] [--report fichier.json]

Pour les lots demandés (fichiers supabase/migrations_pending/<version>_dbNN_*.sql) :
  1. copie jetable `soulbah_scratch_<étiquette>` du modèle figé `soulbah_catchup_template` (base restaurée +
     rattrapage des 15 migrations du dépôt ; réessais si le modèle est momentanément occupé) ;
  2. application, avec scripts/db/migrate.py et pgvector simulé, de l'historique (db00) et des lots demandés —
     dans l'ordre des versions, et SEULEMENT ces lots (un dossier temporaire isole les fichiers d'autres lots en
     cours d'écriture) ;
  3. tests : chaque fichier tests/<nom>.test.sql exécuté dans une transaction annulée ; il doit passer ;
  4. rejeu : le SQL de chaque lot est rejoué (COMMIT) et le schéma (pg_dump --schema-only) doit rester
     identique — idempotence prouvée, pas supposée ;
  5. retour arrière : si <nom>.down.sql existe, il est appliqué puis le lot est réappliqué et ses tests
     repassent ;
  6. la copie est supprimée (sauf --keep). Compte rendu JSON ; code 0 seulement si tout passe.
Ne touche jamais une base distante : le modèle et la copie sont sur le PostgreSQL local de développement.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db_connect import DbError, client_env, parse, psql_path, run_sql  # noqa: E402
from migration_state import stub_vector  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PENDING = ROOT / "supabase" / "migrations_pending"
TEMPLATE = "soulbah_catchup_template"
ADMIN = os.environ.get("SOULBAH_TEST_PG", "postgresql://postgres@127.0.0.1:54329/postgres")
PY = sys.executable


def lot_files(lots: list[str]) -> list[Path]:
    files = []
    for lot in lots:
        found = sorted(p for p in PENDING.glob(f"*_db{lot}_*.sql") if not p.name.endswith(".down.sql"))
        if not found:
            raise DbError(f"aucun fichier pour le lot db{lot} dans {PENDING}")
        files += found
    return sorted(files, key=lambda p: p.name)


def clone(name: str) -> str:
    admin = parse(ADMIN)
    if not admin.is_local:
        raise DbError("le banc d'essai n'utilise que le PostgreSQL local")
    db = f"soulbah_scratch_{re.sub(r'[^a-z0-9_]', '_', name.lower())}"
    run_sql(admin, f'DROP DATABASE IF EXISTS "{db}" WITH (FORCE)', read_only=False)
    for attempt in range(8):
        try:
            run_sql(admin, f'CREATE DATABASE "{db}" TEMPLATE {TEMPLATE}', read_only=False)
            return f"postgresql://{admin.user}@{admin.host}:{admin.port}/{db}"
        except DbError as e:
            if "being accessed" not in str(e) or attempt == 7:
                raise
            time.sleep(2 + attempt * 2)
    raise DbError("copie impossible")


def drop(url: str) -> None:
    db = parse(url).dbname
    run_sql(parse(ADMIN), f'DROP DATABASE IF EXISTS "{db}" WITH (FORCE)', read_only=False)


def psql_file(url: str, path: Path, *, wrap_rollback: bool, stub: bool = False) -> tuple[bool, str]:
    conn = parse(url)
    body = path.read_bytes().decode("utf-8")
    if stub:
        body = stub_vector(body)
    script = ("SET client_min_messages = warning;\nBEGIN;\n" + body + "\n;\nROLLBACK;\n") if wrap_rollback else \
             ("SET client_min_messages = warning;\nBEGIN;\n" + body + "\n;\nCOMMIT;\n")
    p = subprocess.run([psql_path(), "-w", "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=script, capture_output=True,
                       text=True, encoding="utf-8", errors="replace", env=client_env(conn), timeout=1800)
    return p.returncode == 0, (p.stderr or "").strip()[-3000:]


def schema_dump(url: str) -> str:
    conn = parse(url)
    exe = str(Path(psql_path()).with_name("pg_dump" + (".exe" if psql_path().endswith(".exe") else "")))
    p = subprocess.run([exe, "--schema-only", "--schema=soulbah", "--schema=public"], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=client_env(conn), timeout=600)
    if p.returncode != 0:
        raise DbError(p.stderr[-500:])
    return "\n".join(l for l in p.stdout.splitlines() if not re.match(r"^\\(un)?restrict ", l))


def schema_diff(before: str, after: str, limit: int = 200) -> str:
    """Diff unifié (tronqué) entre deux dumps de schéma : pour comprendre un retour arrière incomplet."""
    import difflib
    lines = list(difflib.unified_diff(before.splitlines(), after.splitlines(), "avant", "après", lineterm="", n=2))
    return "\n".join(lines[:limit]) + ("" if len(lines) <= limit else f"\n… ({len(lines) - limit} lignes de plus)")


def migrate(url: str, pending_dir: Path, *extra: str, command: str = "apply") -> tuple[int, str]:
    env = dict(os.environ, SOULBAH_MIGRATIONS_PENDING_DIR=str(pending_dir), PYTHONIOENCODING="utf-8")
    p = subprocess.run([PY, str(ROOT / "scripts" / "db" / "migrate.py"), command, "--target", url, "--pending",
                        "--stub-vector", *extra], capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=env, timeout=3600)
    return p.returncode, (p.stdout + p.stderr)[-4000:]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", required=True)
    ap.add_argument("--lots", required=True, help="numéros de lots, ex. 01,02 (prérequis compris)")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--report")
    a = ap.parse_args(argv)
    lots = [x.strip().zfill(2) for x in a.lots.split(",") if x.strip()]
    files = lot_files(lots)
    report: dict = {"lots": lots, "files": [f.name for f in files], "steps": []}
    url = clone(a.name)
    report["scratch"] = parse(url).dbname
    tmp = Path(tempfile.mkdtemp(prefix="soulbah_lots_"))
    ok = True
    try:
        for f in PENDING.glob("*_db00_*.sql"):
            if not f.name.endswith(".down.sql"):
                shutil.copy(f, tmp / f.name)
        for f in files:
            shutil.copy(f, tmp / f.name)
            down = f.with_name(f.name[:-4] + ".down.sql")
            if down.exists():
                shutil.copy(down, tmp / down.name)
        before_lots = schema_dump(url)
        code, out = migrate(url, tmp)
        report["steps"].append({"step": "apply", "ok": code == 0, "output": out})
        ok &= code == 0
        if ok:
            for f in files:
                test = PENDING / "tests" / f.name.replace(".sql", ".test.sql")
                if not test.exists():
                    report["steps"].append({"step": f"test {f.name}", "ok": False, "output": "fichier de test absent"})
                    ok = False
                    continue
                passed, out = psql_file(url, test, wrap_rollback=True)
                report["steps"].append({"step": f"test {f.name}", "ok": passed, "output": out})
                ok &= passed
            before = schema_dump(url)
            for f in files:
                passed, out = psql_file(url, f, wrap_rollback=False, stub=True)
                report["steps"].append({"step": f"rejeu {f.name}", "ok": passed, "output": out})
                ok &= passed
            after_replay = schema_dump(url)
            same = after_replay == before
            report["steps"].append({"step": "rejeu sans changement de schéma", "ok": same,
                                    "diff": None if same else schema_diff(before, after_replay)})
            ok &= same
            # Retour arrière de TOUTE la séquence (ordre inverse, via le gestionnaire : historique tenu), schéma
            # comparé à l'état d'avant les lots, puis réapplication complète et tests. Les lots sans fichier
            # .down.sql (rollback=NO) rendent ce contrôle impossible : signalé, pas masqué.
            missing = [f.name for f in files if not f.with_name(f.name[:-4] + ".down.sql").exists()]
            if missing:
                report["rollback_untested"] = missing
                report["steps"].append({"step": "retour arrière", "ok": True,
                                        "output": "NON TESTÉ (pas de .down.sql) : " + ", ".join(missing)})
            else:
                versions = ",".join(f.name.split("_", 1)[0] for f in files)
                code, out = migrate(url, tmp, "--versions", versions, command="rollback")
                report["steps"].append({"step": "retour arrière de la séquence (ordre inverse)", "ok": code == 0, "output": out})
                ok &= code == 0
                if code == 0:
                    after_rollback = schema_dump(url)
                    same = after_rollback == before_lots
                    report["steps"].append({"step": "schéma revenu à l'état d'avant les lots", "ok": same, "diff": None if same else schema_diff(before_lots, after_rollback)})
                    ok &= same
                    code, out = migrate(url, tmp)
                    report["steps"].append({"step": "réapplication complète", "ok": code == 0, "output": out})
                    ok &= code == 0
                    for f in files:
                        test = PENDING / "tests" / f.name.replace(".sql", ".test.sql")
                        if test.exists():
                            passed, out = psql_file(url, test, wrap_rollback=True)
                            report["steps"].append({"step": f"test après réapplication {f.name}", "ok": passed, "output": out})
                            ok &= passed
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        if not a.keep:
            drop(url)
    report["ok"] = bool(ok)
    if a.report:
        Path(a.report).write_text(json.dumps(report, ensure_ascii=False, indent=1), "utf-8")
    for s in report["steps"]:
        print(f"{'OK   ' if s['ok'] else 'ÉCHEC'}  {s['step']}")
        if not s["ok"] and s.get("output"):
            print("       " + s["output"].strip().replace("\n", "\n       ")[:2500])
    print("RÉSULTAT :", "tout passe" if ok else "échec")
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except DbError as e:
        print(f"✖ {e}", file=sys.stderr)
        sys.exit(1)
