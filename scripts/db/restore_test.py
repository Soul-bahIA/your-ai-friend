"""Test de restauration d'une sauvegarde chiffrée dans une base LOCALE isolée (DB LOT 0, §12).

    python scripts/db/restore_test.py --backup backups/soulbah_<date>.sql.gpg \
        --dump backups/soulbah_<date>.dump.gpg --passphrase-file %USERPROFILE%\\.soulbah\\backup_passphrase.txt \
        --source-catalog <catalog.json de la base sauvegardée> --target postgresql://postgres@127.0.0.1:54329/<nom> \
        --out <dossier>

Étapes, toutes prouvées dans restore_test.json :
  1. déchiffrement dans un dossier temporaire (supprimé à la fin, même en cas d'erreur) ;
  2. lisibilité du dump custom : `pg_restore -l` (nombre d'entrées de la table des matières) ;
  3. base cible recréée (garde-fou : hôte local et nom contenant « restore » ou « copy ») ; rôles Supabase
     absents créés NOLOGIN (droits restaurés tels quels) ; pgvector simulé comme en CI (vector(N) → real[])
     si l'extension manque localement ;
  4. restauration du dump texte avec psql ; erreurs comptées et listées ;
  5. preuve : catalogue de la copie comparé à celui de la base d'origine (structure du schéma public) et
     comptes de lignes identiques table par table.
Une restauration n'est déclarée réussie que si les étapes 2 à 5 passent.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_diff as CD  # noqa: E402
from db_catalog import build  # noqa: E402
from db_connect import DbError, client_env, parse, psql_path, run_sql  # noqa: E402
from migration_state import stub_vector  # noqa: E402

SUPABASE_ONLY_EXTENSIONS = {"pg_stat_statements", "supabase_vault", "pg_graphql", "pgsodium", "pg_net", "pg_cron",
                            "pgjwt", "pg_tle", "vector"}


def gpg_decrypt(src: Path, dest: Path, passphrase_file: Path) -> None:
    p = subprocess.run(["gpg", "--batch", "--yes", "--quiet", "--pinentry-mode", "loopback", "--passphrase-file",
                        str(passphrase_file), "--output", str(dest), "--decrypt", str(src)],
                       capture_output=True, text=True)
    if p.returncode != 0 or not dest.exists() or dest.stat().st_size == 0:
        raise DbError(f"déchiffrement impossible ({src.name}) : {p.stderr.strip()[:300]}")


def pg_tool(name: str) -> str:
    return str(Path(psql_path()).with_name(name + (".exe" if psql_path().endswith(".exe") else "")))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backup", required=True, help="dump texte chiffré (.sql.gpg)")
    ap.add_argument("--dump", help="dump custom chiffré (.dump.gpg), pour pg_restore -l")
    ap.add_argument("--passphrase-file", required=True)
    ap.add_argument("--source-catalog", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--schemas", default="public")
    a = ap.parse_args(argv)
    conn = parse(a.target)
    if not conn.is_local or not re.search(r"restore|copy", conn.dbname):
        raise DbError("--target doit être une base LOCALE dont le nom contient « restore » ou « copy »")
    source = json.loads(Path(a.source_catalog).read_text("utf-8"))
    schemas = set(a.schemas.split(","))
    report: dict = {"backup": Path(a.backup).name, "target": conn.label(), "steps": {}}
    tmp = Path(tempfile.mkdtemp(prefix="soulbah_restore_"))
    try:
        # 1-2. Déchiffrement et lisibilité
        if a.dump:
            dump = tmp / "backup.dump"
            gpg_decrypt(Path(a.dump), dump, Path(a.passphrase_file))
            p = subprocess.run([pg_tool("pg_restore"), "-l", str(dump)], capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
            entries = [l for l in p.stdout.splitlines() if l and not l.startswith(";")]
            report["steps"]["dump_readable"] = {"ok": p.returncode == 0 and len(entries) > 0, "toc_entries": len(entries)}
        sql_file = tmp / "backup.sql"
        gpg_decrypt(Path(a.backup), sql_file, Path(a.passphrase_file))
        sql = sql_file.read_bytes().decode("utf-8")  # sans conversion des fins de ligne (corps de fonctions)
        report["steps"]["decrypted"] = {"ok": True, "sql_bytes": len(sql.encode("utf-8"))}
        # Le schéma public existe déjà dans toute base neuve : seule erreur attendue, retirée.
        sql = re.sub(r"^CREATE SCHEMA public;$", "-- schéma public déjà présent dans la base neuve", sql,
                     flags=re.MULTILINE)

        # 3. Base cible recréée, rôles, pgvector
        admin = parse(f"postgresql://{conn.user}@{conn.host}:{conn.port}/postgres")
        run_sql(admin, f'DROP DATABASE IF EXISTS "{conn.dbname}" WITH (FORCE)', read_only=False)
        run_sql(admin, f'CREATE DATABASE "{conn.dbname}"', read_only=False)
        roles = set(re.findall(r"^(?:GRANT|REVOKE|ALTER DEFAULT PRIVILEGES)\b[^;]*?\b(?:TO|FROM|FOR ROLE)\s+"
                               r"\"?([a-z_][a-z0-9_]*)\"?", sql, flags=re.MULTILINE))
        roles |= set(re.findall(r"FOR ROLE \"?([a-z_][a-z0-9_]*)\"?", sql))
        roles -= {"public", "postgres", "stdin", "stdout"}
        existing = set(run_sql(admin, "SELECT rolname FROM pg_roles").split())
        created = sorted(r for r in roles if r not in existing)
        for r in created:
            run_sql(admin, f'CREATE ROLE "{r}" NOLOGIN', read_only=False)
        has_vector = run_sql(conn, "SELECT count(*) FROM pg_available_extensions WHERE name = 'vector'").strip() == "1"
        if not has_vector:
            sql = re.sub(r"CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA (\w+);",
                         r"-- [stub-vector] CREATE EXTENSION vector (\1) : extension absente localement", sql)
            sql = re.sub(r"\b(?:public|extensions)\.vector\((\d+)\)", r"real[] /* vector(\1) */", sql)
            sql = stub_vector(sql)
            sql = re.sub(r"CREATE INDEX (\w+) ON [\w.]+ USING hnsw [^;]*;", r"-- [stub-vector] index HNSW \1 sauté", sql)
        for ext in ("pgcrypto", "uuid-ossp"):
            run_sql(conn, f'CREATE SCHEMA IF NOT EXISTS extensions; CREATE EXTENSION IF NOT EXISTS "{ext}" '
                          f'WITH SCHEMA extensions', read_only=False)
        report["steps"]["target_prepared"] = {"ok": True, "roles_created_nologin": created,
                                               "vector": "natif" if has_vector else "simulé (real[])"}

        # 4. Restauration
        restored_sql = tmp / "restore.sql"
        restored_sql.write_bytes(sql.encode("utf-8"))  # octets tels quels : jamais de conversion en CRLF
        p = subprocess.run([psql_path(), "-w", "-X", "-q", "-v", "ON_ERROR_STOP=0", "-f", str(restored_sql)],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", env=client_env(conn),
                           timeout=1800)
        errors = [l for l in p.stderr.splitlines() if "ERROR" in l or "ERREUR" in l]
        report["steps"]["restore"] = {"ok": p.returncode == 0 and not errors, "errors": len(errors),
                                      "error_lines": errors[:80]}

        # 5. Preuves : structure et volumes
        copy = build(conn, counts=True)
        known, diffs, grant_diffs = [], [], []
        for d in CD.compare(source, copy, schemas, vector_stub=False):
            if d["section"] in ("table_grants", "function_grants"):
                grant_diffs.append(d)
            elif not has_vector and CD.is_vector_only(d):
                known.append({**d, "known": "pgvector simulé localement"})
            elif d["section"] == "extensions" and d["kind"] == "missing" and \
                    d["key"].get("name") in SUPABASE_ONLY_EXTENSIONS:
                known.append({**d, "known": "extension propre à Supabase, non restaurée localement"})
            elif d["section"] == "publications" and d["kind"] == "missing":
                known.append({**d, "known": "publication non incluse dans une sauvegarde filtrée par schéma : "
                                            "rejouer ALTER PUBLICATION … ADD TABLE (migrations idempotentes)"})
                report.setdefault("warnings", []).append(
                    f"publication {d['key']['publication']} : {d['key']['schema']}.{d['key']['table']} à rajouter "
                    "après restauration (temps réel)")
            else:
                diffs.append(d)
        report["steps"]["known_differences"] = {"ok": True, "items": known}
        src_rows = {f"{r['schema']}.{r['table']}": r["rows"] for r in source.get("row_counts") or []
                    if r["schema"] in schemas}
        cpy_rows = {f"{r['schema']}.{r['table']}": r["rows"] for r in copy.get("row_counts") or []
                    if r["schema"] in schemas}
        row_mismatch = {t: {"source": n, "copy": cpy_rows.get(t)} for t, n in src_rows.items() if cpy_rows.get(t) != n}
        report["steps"]["structure"] = {"ok": not diffs, "differences": diffs[:100]}
        report["steps"]["grants"] = {"ok": not grant_diffs, "differences": grant_diffs[:100]}
        report["steps"]["rows"] = {"ok": not row_mismatch, "tables": len(src_rows), "rows_total": sum(src_rows.values()),
                                   "mismatch": row_mismatch}
        report["restore_verified"] = all(report["steps"][k]["ok"] for k in ("restore", "structure", "rows")) and \
            report["steps"].get("dump_readable", {"ok": True})["ok"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)  # aucun déchiffré ne reste sur le disque
        report["plaintext_removed"] = not tmp.exists()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "restore_test.json").write_text(json.dumps(report, ensure_ascii=False, indent=1, default=str), "utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "steps"} | {
        "steps": {k: {kk: vv for kk, vv in v.items() if kk not in ("differences", "error_lines")}
                  for k, v in report["steps"].items()}}, ensure_ascii=False, indent=1, default=str))
    return 0 if report.get("restore_verified") else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except DbError as e:
        print(f"✖ {e}", file=sys.stderr)
        sys.exit(1)
