"""Comparaison de deux catalogues (db_catalog.py) — cœur du SchemaDriftDetector (DB LOT 0).

Chaque section est indexée par une clé stable (schéma, table, nom…) puis comparée attribut par attribut,
après normalisation :
  - pgvector simulé : une colonne `real[]` du schéma attendu (base locale sans pgvector, migrations réécrites
    par --stub-vector) équivaut à `vector(N)` dans la base réelle ; les index HNSW, sautés localement, sont
    attendus d'après le texte des migrations ;
  - espaces des définitions (vues, policies) ;
  - le schéma `auth` du schéma attendu est un bouchon de CI : jamais comparé.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS_DIR = ROOT / "supabase" / "migrations"

# Clé et attributs comparés, par section.
SPECS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "schemas": (("name",), ()),
    "tables": (("schema", "name"), ("kind", "rls_enabled", "rls_forced", "persistence")),
    "columns": (("schema", "table", "name"), ("type", "not_null", "default", "identity", "generated")),
    "constraints": (("schema", "table", "name"), ("type", "definition")),
    "indexes": (("schema", "table", "name"), ("definition",)),
    "views": (("schema", "name"), ("kind", "definition_norm")),
    "types": (("schema", "name"), ("kind", "labels", "base")),
    "functions": (("schema", "name", "args"), ("returns", "language", "security_definer", "volatility", "config",
                                                 "source_md5")),
    "triggers": (("schema", "table", "name"), ("definition", "enabled")),
    "policies": (("schema", "table", "name"), ("permissive", "roles", "cmd", "using_norm", "check_norm")),
    "table_grants": (("schema", "table", "grantee", "privilege"), ()),
    "function_grants": (("schema", "function", "grantee", "privilege"), ()),
    "extensions": (("name",), ()),
    "publications": (("publication", "schema", "table"), ()),
}

WS = re.compile(r"\s+")


def norm_text(value) -> str | None:
    if value is None:
        return None
    return WS.sub(" ", str(value)).strip()


def hnsw_index_names(mig_dir: Path = MIGRATIONS_DIR) -> set[str]:
    """Index HNSW déclarés dans les migrations (sautés quand pgvector est simulé)."""
    names: set[str] = set()
    pat = re.compile(r"CREATE\s+INDEX\s+(?:CONCURRENTLY\s+)?IF\s+NOT\s+EXISTS\s+(\w+)\s+ON\s+[\w.]+\s+USING\s+hnsw",
                     re.IGNORECASE)
    for f in sorted(mig_dir.glob("*.sql")):
        names.update(pat.findall(f.read_text("utf-8")))
    return names


def _prepare(section: str, item: dict) -> dict:
    out = dict(item)
    if section == "views":
        out["definition_norm"] = norm_text(item.get("definition"))
    if section == "policies":
        out["using_norm"] = norm_text(item.get("using"))
        out["check_norm"] = norm_text(item.get("with_check"))
        roles = item.get("roles")
        out["roles"] = sorted(roles) if isinstance(roles, list) else roles
    if section == "columns":
        out["default"] = norm_text(item.get("default"))
    if section == "functions":
        cfg = item.get("config")
        out["config"] = sorted(cfg) if isinstance(cfg, list) else cfg
    return out


def index(catalog: dict, section: str, schemas: set[str] | None) -> dict[tuple, dict]:
    keys, _ = SPECS[section]
    out: dict[tuple, dict] = {}
    for item in catalog.get(section) or []:
        if not isinstance(item, dict):
            continue
        if section == "functions" and item.get("extension"):
            continue  # fonctions d'extension (ex. pgvector installé dans public) : hors comparaison
        if section == "constraints" and item.get("type") == "n":
            continue  # NOT NULL dans pg_constraint (PostgreSQL 18+) : déjà comparé par columns.not_null
        schema = item.get("schema", item.get("name") if section == "schemas" else None)
        if schemas is not None and section != "extensions" and schema not in schemas:
            continue
        p = _prepare(section, item)
        out[tuple(p.get(k) for k in keys)] = p
    return out


def vector_equivalent(expected_type: str | None, actual_type: str | None) -> bool:
    """`real[]` (pgvector simulé) ≡ `vector(N)`, dans un sens ou dans l'autre."""
    if expected_type is None or actual_type is None:
        return False
    a, b = expected_type.strip(), actual_type.strip()
    return (a == "real[]" and b.startswith("vector")) or (b == "real[]" and a.startswith("vector"))


def is_vector_only(d: dict) -> bool:
    """Écart dû uniquement à pgvector simulé : type vector ↔ real[], index HNSW/ivfflat, extension vector."""
    if d["section"] == "columns" and d["kind"] == "different" and set(d.get("diff", {})) == {"type"}:
        t = d["diff"]["type"]
        return vector_equivalent(t["expected"], t["actual"])
    if d["section"] == "indexes":
        item = d.get("expected") or d.get("actual") or {}
        definition = (item.get("definition") or "").lower()
        return "using hnsw" in definition or "using ivfflat" in definition or "hnsw" in str(d["key"].get("name", ""))
    if d["section"] == "extensions":
        return d["key"].get("name") == "vector"
    return False


def compare(expected: dict, actual: dict, schemas: set[str], *, vector_stub: bool = True) -> list[dict]:
    """Écarts bruts (section, clé, nature, attendu, réel), sans classement métier."""
    out: list[dict] = []
    hnsw = hnsw_index_names() if vector_stub else set()
    for section, (keys, attrs) in SPECS.items():
        exp = index(expected, section, schemas)
        act = index(actual, section, schemas)
        for k in sorted(set(exp) | set(act), key=lambda t: tuple("" if v is None else str(v) for v in t)):
            e, a = exp.get(k), act.get(k)
            key = dict(zip(keys, k))
            if e is None:
                if section == "indexes" and key.get("name") in hnsw:
                    out.append({"section": section, "key": key, "kind": "present_unverified",
                                "note": "index HNSW : attendu, non vérifiable localement (pgvector simulé)"})
                    continue
                out.append({"section": section, "key": key, "kind": "extra", "actual": a})
            elif a is None:
                out.append({"section": section, "key": key, "kind": "missing", "expected": e})
            else:
                diffs = {}
                for attr in attrs:
                    ev, av = e.get(attr), a.get(attr)
                    if ev == av:
                        continue
                    if section == "columns" and attr == "type" and vector_stub and vector_equivalent(ev, av):
                        continue
                    diffs[attr] = {"expected": ev, "actual": av}
                if diffs:
                    out.append({"section": section, "key": key, "kind": "different", "diff": diffs})
    for name in sorted(hnsw):
        act_idx = {i.get("name") for i in actual.get("indexes") or [] if isinstance(i, dict)}
        if name not in act_idx:
            out.append({"section": "indexes", "key": {"name": name}, "kind": "missing",
                        "note": "index HNSW attendu (migrations) absent de la base"})
    return out


# --- Classement dans le vocabulaire de la mission (§4) ------------------------------------------------
def classify(raw: list[dict]) -> list[dict]:
    kinds = {
        ("tables", "missing"): "missing_table", ("tables", "extra"): "orphan_table",
        ("schemas", "missing"): "missing_schema", ("schemas", "extra"): "extra_schema",
        ("columns", "missing"): "missing_column", ("columns", "extra"): "extra_column",
        ("indexes", "missing"): "missing_index", ("indexes", "extra"): "extra_index",
        ("views", "missing"): "missing_view", ("views", "extra"): "extra_view",
        ("functions", "missing"): "missing_function", ("functions", "extra"): "extra_function",
        ("triggers", "missing"): "missing_trigger", ("triggers", "extra"): "extra_trigger",
        ("policies", "missing"): "missing_policy", ("policies", "extra"): "extra_policy",
        ("types", "missing"): "missing_type", ("types", "extra"): "extra_type",
        ("extensions", "missing"): "missing_extension", ("extensions", "extra"): "extra_extension",
        ("table_grants", "missing"): "missing_grant", ("table_grants", "extra"): "extra_grant",
        ("function_grants", "missing"): "missing_grant", ("function_grants", "extra"): "extra_grant",
    }
    out = []
    for d in raw:
        sec, kind = d["section"], d["kind"]
        if kind == "present_unverified":
            label = "unverified_vector_index"
        elif sec == "constraints" and kind in ("missing", "extra"):
            ctype = (d.get("expected") or d.get("actual") or {}).get("type")
            base = {"f": "foreign_key", "p": "primary_key", "u": "unique_constraint", "c": "check_constraint",
                    "x": "exclusion_constraint"}.get(ctype, "constraint")
            label = ("missing_" if kind == "missing" else "extra_") + base
        elif kind == "different":
            attrs = set(d.get("diff", {}))
            if sec == "columns" and "type" in attrs:
                label = "type_mismatch"
            elif sec == "tables" and attrs & {"rls_enabled", "rls_forced"}:
                label = "rls_mismatch"
            else:
                singular = {"policies": "policy", "indexes": "index", "functions": "function", "triggers": "trigger",
                            "columns": "column", "constraints": "constraint", "views": "view", "types": "type",
                            "tables": "table"}.get(sec, sec)
                label = f"{singular}_definition_mismatch"
        else:
            label = kinds.get((sec, kind), f"{sec}_{kind}")
        out.append({**d, "drift": label})
    return out


def duplicate_indexes(catalog: dict, schemas: set[str]) -> list[dict]:
    """Index redondants d'une même table : mêmes colonnes, même prédicat, même unicité (§4 duplicate_index)."""
    groups: dict[tuple, list[str]] = {}
    for i in catalog.get("indexes") or []:
        if i.get("schema") not in schemas:
            continue
        method = re.search(r"USING (\w+)", i.get("definition") or "")
        key = (i["schema"], i["table"], tuple(i.get("columns") or ()), i.get("predicate"), bool(i.get("unique")),
               method.group(1) if method else None)
        groups.setdefault(key, []).append(i["name"])
    return [{"drift": "duplicate_index", "key": {"schema": k[0], "table": k[1], "columns": list(k[2])},
             "indexes": sorted(v)} for k, v in groups.items() if len(v) > 1]


FUNC_CALL = re.compile(r"\b(?:([a-z_][a-z0-9_]*)\.)?([a-z_][a-z0-9_]*)\s*\(", re.IGNORECASE)
SQL_WORDS = {"select", "exists", "coalesce", "any", "all", "array", "in", "and", "or", "not", "case", "when", "cast",
             "nullif", "lower", "upper", "current_setting", "now", "count", "values", "row", "jsonb_build_object",
             "json_build_object", "least", "greatest", "length", "char_length", "btrim", "trim", "substring", "position",
             "array_length", "jsonb_typeof", "jsonb_array_length", "is_json_object", "md5", "encode", "digest",
             "gen_random_uuid", "date_trunc", "extract", "abs", "round", "format", "concat", "split_part", "regexp_like",
             "starts_with", "char",
             # mots-clés SQL suivis d'une parenthèse dans les expressions de policies (jamais des fonctions)
             "where", "from", "on", "join", "then", "else", "end", "as", "is", "like", "ilike", "some", "between",
             "distinct", "using", "with", "check", "filter", "over", "partition", "by", "order", "group", "having",
             "limit", "offset", "union", "intersect", "except", "returning", "lateral", "only", "true", "false",
             "null", "interval", "timestamp", "date", "time", "numeric", "text", "uuid", "jsonb", "json", "boolean"}


def invalid_policies(catalog: dict, schemas: set[str]) -> list[dict]:
    """Policies qui appellent une fonction absente, ou posées sur une table sans RLS (§4 invalid_policy)."""
    funcs = {(f.get("schema"), (f.get("name") or "").lower()) for f in catalog.get("functions") or []}
    builtins = {n.lower() for n in catalog.get("builtin_function_names") or []}
    funcs |= {("pg_catalog", n) for n in builtins}
    func_names = {name for _, name in funcs}
    rls = {(t["schema"], t["name"]): t.get("rls_enabled") for t in catalog.get("tables") or []}
    out = []
    for p in catalog.get("policies") or []:
        if p.get("schema") not in schemas:
            continue
        problems = []
        if rls.get((p["schema"], p["table"])) is False:
            problems.append("table sans RLS : la policy n'a aucun effet")
        for expr in (p.get("using"), p.get("with_check")):
            for schema, name in FUNC_CALL.findall(expr or ""):
                lname = name.lower()
                if lname in SQL_WORDS or (not schema and lname in func_names):
                    continue
                if schema and (schema.lower(), lname) in funcs:
                    continue
                if not schema and lname not in func_names:
                    problems.append(f"fonction introuvable : {name}()")
        if problems:
            out.append({"drift": "invalid_policy", "key": {"schema": p["schema"], "table": p["table"],
                                                           "name": p["name"]}, "problems": sorted(set(problems))})
    return out
