"""État RÉEL de chaque migration du dépôt dans une base cible — MigrationPlanner, étape 1 (DB LOT 0).

    python scripts/db/migration_state.py --actual <catalog.json> --scratch <URL locale jetable> --out <dossier>

La base restaurée n'a pas d'historique de migrations : on ne peut pas savoir « ce qui a été appliqué »
autrement qu'en regardant les objets. Méthode :
  1. sur une base LOCALE JETABLE (--scratch, recréée), bouchon Supabase de la CI puis chaque migration du
     dépôt, une à une (pgvector simulé comme en CI) ; instantané du catalogue après chacune ;
  2. objets ajoutés, supprimés ou modifiés par chaque migration = différence entre deux instantanés ;
  3. ces objets sont cherchés dans le catalogue de la base cible (--actual, lu en lecture seule par
     db_catalog.py) : APPLIED (tout est là), NOT_APPLIED (rien), PARTIAL (mélange), avec le détail.

Garde-fou : --scratch doit viser 127.0.0.1 / localhost et une base dont le nom contient « scratch » ou
« migstate » ; elle est supprimée puis recréée. La base cible n'est jamais contactée par cet outil.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_diff as CD  # noqa: E402
from db_catalog import STRUCTURAL_SECTIONS, build  # noqa: E402
from db_connect import DbError, parse, run_sql  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
AUTH_STUB = ROOT / "scripts" / "ci" / "auth_stub.sql"
APP_SCHEMAS = {"public", "soulbah"}


def stub_vector(sql: str) -> str:
    """Équivalent Python de stub_vector() de scripts/ci/apply_migrations.sh."""
    sql = re.sub(r"CREATE\s+EXTENSION\s+IF\s+NOT\s+EXISTS\s+vector\s*;",
                 "-- [stub-vector] extension pgvector absente : non créée", sql, flags=re.IGNORECASE)
    sql = re.sub(r"\bvector\((\d+)\)", r"real[] /* [stub-vector] vector(\1) */", sql, flags=re.IGNORECASE)
    sql = re.sub(r"(\s)vector(\s*,)", r"\1real[] /* [stub-vector] vector */\2", sql, flags=re.IGNORECASE)
    sql = re.sub(r"CREATE\s+INDEX\s+IF\s+NOT\s+EXISTS\s+(\w+)\s+ON\s+[\w.]+\s+USING\s+hnsw\s*\([^;]*;",
                 r"-- [stub-vector] index HNSW \1 sauté", sql, flags=re.IGNORECASE)
    return sql


def guard_scratch(url: str):
    conn = parse(url)
    if not conn.is_local or not re.search(r"scratch|migstate", conn.dbname):
        raise DbError("--scratch doit être une base LOCALE dont le nom contient « scratch » ou « migstate »")
    return conn


def recreate(conn) -> None:
    admin = parse(f"postgresql://{conn.user}@{conn.host}:{conn.port}/postgres")
    run_sql(admin, f'DROP DATABASE IF EXISTS "{conn.dbname}" WITH (FORCE)', read_only=False)
    run_sql(admin, f'CREATE DATABASE "{conn.dbname}"', read_only=False)


def snapshot(conn) -> dict:
    cat = build(conn, counts=False, sections=STRUCTURAL_SECTIONS)
    if cat.get("_errors"):
        raise DbError(f"instantané incomplet : {cat['_errors']}")
    return cat


def _key_tuple(item: dict) -> tuple:
    return tuple(sorted((k, str(v)) for k, v in item["key"].items()))


def evaluate(delta: list[dict], final_cat: dict, actual: dict) -> dict:
    """Pour chaque objet touché par une migration : présent / absent / différent dans la base cible."""
    act_idx = {s: CD.index(actual, s, APP_SCHEMAS) for s in CD.SPECS}
    fin_idx = {s: CD.index(final_cat, s, APP_SCHEMAS) for s in CD.SPECS}
    results = {"present": [], "absent": [], "differs": []}
    for d in delta:
        sec = d["section"]
        keys, attrs = CD.SPECS[sec]
        key = tuple(d["key"].get(k) for k in keys)
        a = act_idx[sec].get(key)
        label = {"section": sec, "key": d["key"], "change": d["kind"]}
        if d["kind"] == "extra":  # supprimé par la migration
            (results["present"] if a is None else results["absent"]).append(label)
            continue
        if a is None:
            results["absent"].append(label)
            continue
        target = d.get("expected") or {}
        fin = fin_idx[sec].get(key)

        def same(ref: dict | None) -> bool:
            if ref is None:
                return False
            for attr in attrs:
                rv, av = ref.get(attr), a.get(attr)
                if rv == av:
                    continue
                if sec == "columns" and attr == "type" and CD.vector_equivalent(rv, av):
                    continue
                return False
            return True

        if d["kind"] == "different":
            new_def = {attr: v["expected"] for attr, v in d["diff"].items()}
            old_def = {attr: v["actual"] for attr, v in d["diff"].items()}
            if all(a.get(k) == v or (sec == "columns" and k == "type" and CD.vector_equivalent(v, a.get(k)))
                   for k, v in new_def.items()) or same(fin):
                results["present"].append(label)
            elif all(a.get(k) == v for k, v in old_def.items()):
                results["absent"].append({**label, "note": "ancienne définition encore en place"})
            else:
                results["differs"].append(label)
            continue
        if same(target) or same(fin):
            results["present"].append(label)
        else:
            results["differs"].append({**label, "actual": {k: a.get(k) for k in attrs},
                                       "expected": {k: (fin or target).get(k) for k in attrs}})
    return results


def verdict(res: dict) -> str:
    p, ab, df = len(res["present"]), len(res["absent"]), len(res["differs"])
    if p + ab + df == 0:
        return "NO_SCHEMA_CHANGE"
    if ab == 0 and df == 0:
        return "APPLIED"
    if p == 0 and df == 0:
        return "NOT_APPLIED"
    return "PARTIAL"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--actual", required=True, help="catalog.json de la base cible (db_catalog.py)")
    ap.add_argument("--scratch", required=True, help="URL d'une base locale jetable")
    ap.add_argument("--out", required=True)
    ap.add_argument("--migrations", default=str(CD.MIGRATIONS_DIR))
    a = ap.parse_args(argv)
    actual = json.loads(Path(a.actual).read_text("utf-8"))
    conn = guard_scratch(a.scratch)
    recreate(conn)
    run_sql(conn, AUTH_STUB.read_text("utf-8"), read_only=False)
    files = sorted(Path(a.migrations).glob("*.sql"))
    snaps = [snapshot(conn)]
    deltas = []
    for f in files:
        sql = "SET client_min_messages = warning;\n" + stub_vector(f.read_text("utf-8"))
        run_sql(conn, "BEGIN;\n" + sql + "\nCOMMIT", read_only=False, timeout_s=600)
        snaps.append(snapshot(conn))
        delta = [d for d in CD.compare(snaps[-1], snaps[-2], APP_SCHEMAS, vector_stub=False)]
        deltas.append((f, delta))
        print(f"  {f.name} : {len(delta)} changement(s) de schéma", flush=True)
    final = snaps[-1]
    report = []
    for f, delta in deltas:
        res = evaluate(delta, final, actual)
        report.append({"file": f.name, "version": f.name.split("_", 1)[0], "verdict": verdict(res),
                       "changes": len(delta), "present": len(res["present"]), "absent": len(res["absent"]),
                       "differs": len(res["differs"]), "absent_items": res["absent"][:200],
                       "differs_items": res["differs"][:200]})
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "migration_state.json").write_text(json.dumps(report, ensure_ascii=False, indent=1, default=str), "utf-8")
    width = max(len(r["file"]) for r in report)
    for r in report:
        print(f"{r['file']:<{width}}  {r['verdict']:<16} présents {r['present']:>4} · absents {r['absent']:>4} · "
              f"différents {r['differs']:>3}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except DbError as e:
        print(f"✖ {e}", file=sys.stderr)
        sys.exit(1)
