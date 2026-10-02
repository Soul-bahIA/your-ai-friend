#!/usr/bin/env python3
"""Contrôles d'intégration sur une copie locale portant les lots DB : les trois contrôles de la CI (schema_checks,
post_restore_checks, api_role_checks avec les droits de soulbah_api) puis les tests d'intégration de node-api
(vitest, fichiers en série) contre cette copie. Rapport JSON.

    python scripts/db/integration_checks.py --target postgresql://postgres@127.0.0.1:54329/soulbah_scratch_full \
        --out db/dryrun/2026-10-02/integration_checks.json [--skip-node]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from db_connect import DbError, parse  # noqa: E402
from build_catchup_template import psql_checks  # noqa: E402


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--skip-node", action="store_true")
    a = ap.parse_args(argv)
    conn = parse(a.target)
    if not conn.is_local:
        raise DbError("les contrôles d'intégration ne s'exécutent que sur une copie locale")
    log: list[dict] = []
    report = {"target": conn.dbname, "started_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "steps": log}
    ok = True
    try:
        psql_checks(a.target, log)
    except DbError as e:
        ok = False
        report["error"] = str(e)
    if ok and not a.skip_node:
        env = dict(os.environ, TEST_DATABASE_URL=a.target, CI="1")
        t0 = time.monotonic()
        p = subprocess.run(["npx.cmd" if os.name == "nt" else "npx", "vitest", "run", "test/integration", "--no-file-parallelism"],
                           cwd=ROOT / "backend" / "node-api", capture_output=True, text=True, encoding="utf-8", errors="replace",
                           env=env, timeout=3600)
        out = (p.stdout + p.stderr)
        summary = "\n".join(l for l in out.splitlines() if "Test Files" in l or "Tests " in l or "FAIL" in l or "failed" in l.lower())[-3000:]
        log.append({"step": "node-api vitest test/integration", "ok": p.returncode == 0, "seconds": round(time.monotonic() - t0, 1),
                    "summary": summary, "output_tail": out[-6000:]})
        print(f"{'OK   ' if p.returncode == 0 else 'ÉCHEC'}  node-api vitest test/integration ({round(time.monotonic() - t0)} s)\n{summary}")
        ok &= p.returncode == 0
    report["ok"] = ok
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
    print("RÉSULTAT :", "tout passe" if ok else "échec", "→", a.out)
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except DbError as e:
        print(f"ERREUR : {e}", file=sys.stderr)
        sys.exit(2)
