#!/usr/bin/env python3
"""Vérifie que scripts/sql/soulbah_api_grants.sql couvre TOUT le SQL de node-api (T54, S4).

Inventaire statique de backend/node-api/src/**/*.ts : seules les chaînes du code
(littéraux '…', "…" et `…`) sont analysées, jamais les commentaires. Pour chaque
instruction :
  INSERT INTO t            → INSERT sur t (+ SELECT si RETURNING,
                             + UPDATE si ON CONFLICT … DO UPDATE)
  UPDATE t [alias] SET     → UPDATE + SELECT sur t (WHERE / RETURNING)
  DELETE FROM t            → DELETE + SELECT sur t
  FROM t / JOIN t          → SELECT sur t
  [public.]has_role( / is_admin(   → EXECUTE sur la fonction
Seules les tables du schéma public créées par les migrations (ou backend/postgres/
init.sql) sont prises en compte : alias, CTE, fonctions et catalogues sont ignorés.
Les noms de table dynamiques (`UPDATE ${table}`) doivent être déclarés dans DYNAMIC.

Sortie : 0 si tout est accordé, 1 s'il manque un droit (liste détaillée).
Les droits accordés mais inutilisés sont signalés (avertissement ; erreur avec --strict).

Usage : python scripts/ci/check_api_grants.py [--strict] [--verbose] [--grants FICHIER]
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "backend" / "node-api" / "src"
GRANTS = ROOT / "scripts" / "sql" / "soulbah_api_grants.sql"
SCHEMA_SOURCES = [*sorted((ROOT / "supabase" / "migrations").glob("*.sql")),
                  ROOT / "backend" / "postgres" / "init.sql"]

# Sites à nom de table dynamique : (fichier relatif à src, motif) → droits par table.
DYNAMIC = {
    ("services/maintenance.ts", "UPDATE ${table}"): {
        "formations": {"UPDATE", "SELECT"},
        "applications": {"UPDATE", "SELECT"},
    },
}
FUNCTIONS = ("has_role", "is_admin")

IDENT = r"(?:public\.)?([a-z_][a-z0-9_]*)"


def known_tables() -> set[str]:
    tables: set[str] = set()
    pat = re.compile(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?([a-z_][a-z0-9_]*)\s*\(",
                     re.IGNORECASE)
    for f in SCHEMA_SOURCES:
        if f.exists():
            tables.update(m.group(1).lower() for m in pat.finditer(f.read_text(encoding="utf-8")))
    return tables


def string_literals(code: str) -> list[str]:
    """Contenu des littéraux de chaîne d'un fichier TS (commentaires exclus).

    Les ${…} des gabarits sont remplacés par « ${} » (le texte de l'expression n'est pas
    du SQL) ; les gabarits imbriqués dans une expression sont ignorés.
    """
    out: list[str] = []
    i, n = 0, len(code)
    while i < n:
        c = code[i]
        if code.startswith("//", i):
            j = code.find("\n", i)
            i = n if j < 0 else j
        elif code.startswith("/*", i):
            j = code.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif c in "'\"":
            j, buf = i + 1, []
            while j < n and code[j] != c and code[j] != "\n":
                if code[j] == "\\" and j + 1 < n:
                    buf.append(code[j + 1])
                    j += 2
                    continue
                buf.append(code[j])
                j += 1
            out.append("".join(buf))
            i = j + 1
        elif c == "`":
            j, buf = i + 1, []
            while j < n and code[j] != "`":
                if code[j] == "\\" and j + 1 < n:
                    buf.append(code[j + 1])
                    j += 2
                elif code.startswith("${", j):
                    depth, j = 1, j + 2
                    while j < n and depth:
                        depth += {"{": 1, "}": -1}.get(code[j], 0)
                        j += 1
                    buf.append("${}")
                else:
                    buf.append(code[j])
                    j += 1
            out.append("".join(buf))
            i = j + 1
        else:
            i += 1
    return out


def required_privileges(tables: set[str]) -> tuple[dict[str, set[str]], set[str], list[str]]:
    need: dict[str, set[str]] = defaultdict(set)
    funcs: set[str] = set()
    where: list[str] = []
    for f in sorted(SRC.rglob("*.ts")):
        rel = f.relative_to(SRC).as_posix()
        code = f.read_text(encoding="utf-8")
        for (dyn_file, marker), grants in DYNAMIC.items():
            if rel == dyn_file and marker in code:
                for t, privs in grants.items():
                    need[t] |= privs
        for s in string_literals(code):
            # Statements one by one (several may share a literal).
            for stmt in re.split(r";", s):
                found: list[tuple[str, str]] = []
                for m in re.finditer(rf"\bINSERT\s+INTO\s+{IDENT}", stmt):
                    found.append((m.group(1), "INSERT"))
                    if re.search(r"\bRETURNING\b", stmt):
                        found.append((m.group(1), "SELECT"))
                    if re.search(r"\bON\s+CONFLICT\b[^;]*?\bDO\s+UPDATE\b", stmt, re.S):
                        found.append((m.group(1), "UPDATE"))
                for m in re.finditer(rf"\bUPDATE\s+{IDENT}(?:\s+(?:AS\s+)?[a-z_][a-z0-9_]*)?\s+SET\b", stmt):
                    found += [(m.group(1), "UPDATE"), (m.group(1), "SELECT")]
                for m in re.finditer(rf"\bDELETE\s+FROM\s+{IDENT}", stmt):
                    found += [(m.group(1), "DELETE"), (m.group(1), "SELECT")]
                for m in re.finditer(rf"\b(?:FROM|JOIN|USING)\s+{IDENT}", stmt):
                    found.append((m.group(1), "SELECT"))
                for t, p in found:
                    if t in tables:
                        if p not in need[t]:
                            where.append(f"{rel}: {p} {t}")
                        need[t].add(p)
                for fn in FUNCTIONS:
                    if re.search(rf"(?:public\.)?\b{fn}\s*\(", stmt):
                        funcs.add(fn)
    # Les sites dynamiques déclarés doivent exister (sinon DYNAMIC est périmé).
    for (dyn_file, marker) in DYNAMIC:
        p = SRC / dyn_file
        if not p.exists() or marker not in p.read_text(encoding="utf-8"):
            raise SystemExit(f"DYNAMIC périmé : « {marker} » introuvable dans src/{dyn_file}")
    return need, funcs, where


def granted_privileges(path: Path) -> tuple[dict[str, set[str]], set[str]]:
    sql = re.sub(r"--[^\n]*", "", path.read_text(encoding="utf-8"))
    have: dict[str, set[str]] = defaultdict(set)
    funcs: set[str] = set()
    for m in re.finditer(r"GRANT\s+([A-Z ,]+?)\s+ON\s+(?:TABLE\s+)?((?:public\.[a-z_0-9]+\s*,?\s*)+)\s+TO\s+soulbah_api",
                         sql, re.IGNORECASE):
        privs = {p.strip().upper() for p in m.group(1).split(",")}
        for t in re.findall(r"public\.([a-z_0-9]+)", m.group(2)):
            have[t] |= privs
    for m in re.finditer(r"GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+public\.([a-z_0-9]+)\s*\([^)]*\)\s+TO\s+soulbah_api",
                         sql, re.IGNORECASE):
        funcs.add(m.group(1))
    return have, funcs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--strict", action="store_true", help="les droits inutilisés sont des erreurs")
    ap.add_argument("--verbose", action="store_true", help="affiche l'inventaire complet")
    ap.add_argument("--grants", type=Path, default=GRANTS, help="fichier de GRANT à vérifier (tests)")
    args = ap.parse_args()

    tables = known_tables()
    if not tables:
        print("ERREUR : aucune table trouvée dans les migrations", file=sys.stderr)
        return 1
    need, need_funcs, where = required_privileges(tables)
    have, have_funcs = granted_privileges(args.grants)

    if args.verbose:
        print("Inventaire node-api (table : droits requis)")
        for t in sorted(need):
            print(f"  {t:20} {', '.join(sorted(need[t]))}")
        print("  fonctions :", ", ".join(sorted(need_funcs)) or "-")
        for w in where:
            print("   ·", w)

    missing = [(t, p) for t in sorted(need) for p in sorted(need[t] - have.get(t, set()))]
    missing += [("fonction " + f, "EXECUTE") for f in sorted(need_funcs - have_funcs)]
    unused = [(t, p) for t in sorted(have) for p in sorted(have[t] - need.get(t, set()))]
    unused += [("fonction " + f, "EXECUTE") for f in sorted(have_funcs - need_funcs)]

    grants = args.grants.resolve()
    rel = grants.relative_to(ROOT).as_posix() if grants.is_relative_to(ROOT) else grants.as_posix()
    for t, p in unused:
        print(f"{'ERREUR' if args.strict else 'AVERTISSEMENT'} : {p} sur {t} accordé mais inutilisé par node-api ({rel})")
    if missing:
        for t, p in missing:
            print(f"ERREUR : node-api utilise {p} sur {t}, absent de {rel}", file=sys.stderr)
        return 1
    if args.strict and unused:
        return 1
    print(f"OK : {sum(len(v) for v in need.values())} droits sur {len(need)} tables et "
          f"{len(need_funcs)} fonctions, tous accordés par {rel}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
