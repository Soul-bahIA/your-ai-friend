"""Schema Drift Report : base réelle contre schéma attendu par le code — SchemaDriftDetector (DB LOT 0).

    python scripts/db/schema_drift.py --actual <catalog.json> --expected <catalog.json>
           [--migration-state <migration_state.json>] --out <dossier>

Répond à la question : « la base restaurée correspond-elle réellement au code actuel de Soulbah ? ».
Écrit drift.json (écarts classés : missing_table, missing_column, extra_column, type_mismatch,
missing_index, missing_constraint, missing_foreign_key, migration_drift, orphan_table, duplicate_index,
invalid_policy, rls_mismatch, …) et drift.md (synthèse lisible).
"""
from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_diff as CD  # noqa: E402

APP_SCHEMAS = {"public", "soulbah"}


def load(path: str) -> dict:
    return json.loads(Path(path).read_text("utf-8"))


def key_text(key: dict) -> str:
    parts = [str(key.get(k)) for k in ("schema", "table", "name", "args", "grantee", "privilege", "function")
             if key.get(k) is not None]
    return ".".join(parts[:3]) + (" " + " ".join(parts[3:]) if len(parts) > 3 else "")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--actual", required=True)
    ap.add_argument("--expected", required=True)
    ap.add_argument("--migration-state")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    actual, expected = load(a.actual), load(a.expected)
    raw = CD.compare(expected, actual, APP_SCHEMAS, vector_stub=True)
    items = CD.classify(raw)
    items += CD.duplicate_indexes(actual, APP_SCHEMAS)
    items += CD.invalid_policies(actual, APP_SCHEMAS)
    state = load(a.migration_state) if a.migration_state else []
    history_absent = actual.get("supabase_migrations") is None and actual.get("soulbah_migrations") is None
    if history_absent:
        items.append({"drift": "migration_drift", "key": {"name": "historique"},
                      "note": "aucune table d'historique (supabase_migrations.schema_migrations ni "
                              "soulbah.schema_migrations) : l'état appliqué ne peut être déduit que des objets"})
    for m in state:
        if m["verdict"] in ("PARTIAL", "NOT_APPLIED"):
            items.append({"drift": "migration_drift", "key": {"name": m["file"]}, "verdict": m["verdict"],
                          "absent": m["absent"], "differs": m["differs"], "present": m["present"]})
    counts = collections.Counter(i["drift"] for i in items)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "drift.json").write_text(json.dumps({"counts": counts, "items": items}, ensure_ascii=False, indent=1,
                                               default=str), "utf-8")
    lines = ["# Schema Drift Report (généré)", "",
             f"Base réelle : {actual.get('meta', {}).get('server_version')} · schémas applicatifs "
             f"{', '.join(actual.get('app_schemas') or [])}", "",
             f"Schéma attendu : {expected.get('meta', {}).get('server_version')} · schémas "
             f"{', '.join(expected.get('app_schemas') or [])}", "", "| Écart | Nombre |", "|---|---|"]
    lines += [f"| `{k}` | {v} |" for k, v in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]
    by_kind: dict[str, list[dict]] = collections.defaultdict(list)
    for i in items:
        by_kind[i["drift"]].append(i)
    for kind in sorted(by_kind):
        lines += ["", f"## {kind}", ""]
        for i in by_kind[kind][:400]:
            extra = ""
            if i.get("diff"):
                extra = " — " + "; ".join(f"{k} : attendu {v['expected']!r}, réel {v['actual']!r}"
                                           for k, v in i["diff"].items())
            elif i.get("problems"):
                extra = " — " + "; ".join(i["problems"])
            elif i.get("indexes"):
                extra = " — " + ", ".join(i["indexes"])
            elif i.get("verdict"):
                extra = f" — {i['verdict']} (présents {i['present']}, absents {i['absent']}, différents {i['differs']})"
            elif i.get("note"):
                extra = " — " + i["note"]
            lines.append(f"- `{key_text(i['key'])}`{extra}")
        if len(by_kind[kind]) > 400:
            lines.append(f"- … {len(by_kind[kind]) - 400} de plus (drift.json)")
    (out / "drift.md").write_text("\n".join(lines) + "\n", "utf-8")
    for k, v in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"{v:>5}  {k}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
