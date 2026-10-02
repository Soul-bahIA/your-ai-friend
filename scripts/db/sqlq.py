"""Requête SQL en LECTURE SEULE sur une base PostgreSQL LOCALE (outil d'analyse, DB LOT 0).

    python scripts/db/sqlq.py <url-locale> "<sql>"
    python scripts/db/sqlq.py <url-locale> -f requete.sql

Refuse tout hôte autre que 127.0.0.1 / localhost / ::1 : la base Supabase restaurée n'est jamais
interrogée par cet outil (utiliser les catalogues de db/baseline/, ou la copie locale
postgresql://postgres@127.0.0.1:54329/soulbah_restored_copy). La transaction est READ ONLY :
toute écriture est refusée par le serveur. Sortie : lignes séparées par « | », avec en-têtes.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db_connect import DbError, parse, run_sql  # noqa: E402


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    try:
        conn = parse(argv[0])
    except DbError as e:
        print(f"✖ {e}", file=sys.stderr)
        return 2
    if not conn.is_local:
        print("✖ refus : seules les bases locales (127.0.0.1, localhost) sont autorisées", file=sys.stderr)
        return 3
    sql = Path(argv[2]).read_text("utf-8") if argv[1] == "-f" else argv[1]
    try:
        out = run_sql(conn, f"\\pset fieldsep '|'\n{sql}", tuples_only=False)
    except DbError as e:
        print(f"✖ {e}", file=sys.stderr)
        return 1
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
