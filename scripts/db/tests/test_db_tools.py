"""Tests de l'outillage base de données de Soulbah (DB LOT 0) : gestionnaire de migrations, comparaison de
catalogues, analyse de risque.

Les tests qui touchent une base utilisent le PostgreSQL LOCAL de développement (SOULBAH_TEST_PG, défaut
postgresql://postgres@127.0.0.1:54329/postgres) et créent puis suppriment leurs propres bases
`soulbah_test_scratch_*`. Sans PostgreSQL local joignable, ils sont ignorés.

    agent/.venv/Scripts/python.exe -m pytest scripts/db/tests -q
"""
from __future__ import annotations

import importlib
import json
import os
import shutil
import sys
import threading
import uuid
from pathlib import Path
from types import SimpleNamespace

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import catalog_diff as CD  # noqa: E402
import db_connect  # noqa: E402

ADMIN_URL = os.environ.get("SOULBAH_TEST_PG", "postgresql://postgres@127.0.0.1:54329/postgres")
BOOTSTRAP = HERE.parents[2] / "supabase" / "migrations_pending" / "20261002100000_db00_migration_history.sql"


def pg_available() -> bool:
    try:
        db_connect.run_sql(db_connect.parse(ADMIN_URL), "SELECT 1", timeout_s=15)
        return True
    except Exception:  # noqa: BLE001
        return False


needs_pg = pytest.mark.skipif(not pg_available(), reason="PostgreSQL local de test injoignable")


@pytest.fixture()
def scratch_db():
    admin = db_connect.parse(ADMIN_URL)
    name = f"soulbah_test_scratch_{uuid.uuid4().hex[:10]}"
    db_connect.run_sql(admin, f'CREATE DATABASE "{name}"', read_only=False)
    url = f"postgresql://{admin.user}@{admin.host}:{admin.port}/{name}"
    try:
        yield url
    finally:
        db_connect.run_sql(admin, f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)', read_only=False)


@pytest.fixture()
def migrations(tmp_path, monkeypatch):
    """Dossiers de migrations de test : l'historique (vraie migration DB LOT 0b) + deux migrations."""
    repo, pending = tmp_path / "repo", tmp_path / "pending"
    repo.mkdir()
    pending.mkdir()
    shutil.copy(BOOTSTRAP, pending / BOOTSTRAP.name)
    (repo / "20990101000000_first.sql").write_text(
        "-- soulbah:rollback=YES\nCREATE TABLE IF NOT EXISTS public.t_first (id int PRIMARY KEY);\n", "utf-8")
    (repo / "20990101000100_second.sql").write_text(
        "CREATE TABLE IF NOT EXISTS public.t_second (id int PRIMARY KEY REFERENCES public.t_first(id));\n", "utf-8")
    monkeypatch.setenv("SOULBAH_MIGRATIONS_DIR", str(repo))
    monkeypatch.setenv("SOULBAH_MIGRATIONS_PENDING_DIR", str(pending))
    import migrate
    importlib.reload(migrate)
    yield SimpleNamespace(repo=repo, pending=pending, migrate=migrate)
    monkeypatch.delenv("SOULBAH_MIGRATIONS_DIR")
    monkeypatch.delenv("SOULBAH_MIGRATIONS_PENDING_DIR")
    importlib.reload(migrate)


def q(url: str, sql: str) -> str:
    return db_connect.run_sql(db_connect.parse(url), sql).strip()


def run(mig, *args: str) -> int:
    return mig.migrate.main(list(args))


# --- Gestionnaire de migrations -----------------------------------------------------------------------
@needs_pg
def test_apply_records_history_checksums_and_is_idempotent(scratch_db, migrations):
    assert run(migrations, "apply", "--target", scratch_db, "--pending") == 0
    rows = json.loads(q(scratch_db, "SELECT json_agg(row_to_json(m) ORDER BY version) FROM soulbah.schema_migrations m"))
    assert [r["version"] for r in rows] == ["20261002100000", "20990101000000", "20990101000100"]
    assert all(r["status"] == "applied" and len(r["checksum"]) == 64 for r in rows)
    assert rows[1]["rollback"] == "YES" and rows[2]["rollback"] == "NO"
    assert q(scratch_db, "SELECT count(*) FROM soulbah.schema_migration_runs WHERE status = 'succeeded'") == "3"
    # Deuxième passage : rien à faire.
    assert run(migrations, "apply", "--target", scratch_db, "--pending") == 0
    assert q(scratch_db, "SELECT count(*) FROM soulbah.schema_migration_runs") == "3"
    assert run(migrations, "verify", "--target", scratch_db, "--pending") == 0


@needs_pg
def test_modified_file_after_apply_is_detected_and_blocks(scratch_db, migrations):
    assert run(migrations, "apply", "--target", scratch_db, "--pending") == 0
    f = migrations.repo / "20990101000000_first.sql"
    f.write_text(f.read_text("utf-8") + "-- modifié\nSELECT 1;\n", "utf-8")
    assert run(migrations, "verify", "--target", scratch_db, "--pending") == 1
    assert run(migrations, "apply", "--target", scratch_db, "--pending") == 1


@needs_pg
def test_crlf_checkout_does_not_change_the_checksum(migrations):
    f = migrations.repo / "20990101000000_first.sql"
    m1 = next(m for m in migrations.migrate.discover(True) if m.version == "20990101000000")
    f.write_bytes(f.read_bytes().replace(b"\n", b"\r\n"))
    m2 = next(m for m in migrations.migrate.discover(True) if m.version == "20990101000000")
    assert m1.checksum == m2.checksum


@needs_pg
def test_failed_migration_rolls_back_and_failure_is_logged(scratch_db, migrations):
    (migrations.repo / "20990101000200_broken.sql").write_text(
        "CREATE TABLE public.t_partial (id int);\nSELECT * FROM table_qui_n_existe_pas;\n", "utf-8")
    assert run(migrations, "apply", "--target", scratch_db, "--pending") == 1
    assert q(scratch_db, "SELECT to_regclass('public.t_partial') IS NULL") == "t"  # rien à moitié appliqué
    assert q(scratch_db, "SELECT count(*) FROM soulbah.schema_migrations WHERE version = '20990101000200'") == "0"
    err = q(scratch_db, "SELECT error FROM soulbah.schema_migration_runs WHERE version = '20990101000200' AND status = 'failed'")
    assert "table_qui_n_existe_pas" in err
    # Les migrations précédentes restent appliquées et tracées.
    assert q(scratch_db, "SELECT count(*) FROM soulbah.schema_migrations WHERE status = 'applied'") == "3"


@needs_pg
def test_dry_run_is_cumulative_and_writes_nothing(scratch_db, migrations, tmp_path):
    report = tmp_path / "dry.json"
    assert run(migrations, "apply", "--target", scratch_db, "--pending", "--dry-run", "--report", str(report)) == 0
    assert json.loads(report.read_text("utf-8"))["ok"] is True  # second dépend du premier : vu dans la même transaction
    assert q(scratch_db, "SELECT to_regclass('public.t_first') IS NULL AND to_regclass('soulbah.schema_migrations') IS NULL") == "t"


@needs_pg
def test_dry_run_reports_the_failing_migration(scratch_db, migrations, tmp_path):
    (migrations.repo / "20990101000200_broken.sql").write_text("SELECT * FROM table_qui_n_existe_pas;\n", "utf-8")
    report = tmp_path / "dry.json"
    assert run(migrations, "apply", "--target", scratch_db, "--pending", "--dry-run", "--report", str(report)) == 1
    out = json.loads(report.read_text("utf-8"))
    assert out["ok"] is False and out["failed_at"] == "20990101000200"


@needs_pg
def test_run_log_is_append_only(scratch_db, migrations):
    assert run(migrations, "apply", "--target", scratch_db, "--pending") == 0
    conn = db_connect.parse(scratch_db)
    for sql in ("UPDATE soulbah.schema_migration_runs SET status = 'failed'",
                "DELETE FROM soulbah.schema_migration_runs",
                "TRUNCATE soulbah.schema_migration_runs"):
        with pytest.raises(db_connect.DbError, match="ajout seul"):
            db_connect.run_sql(conn, sql, read_only=False)


@needs_pg
def test_concurrent_runs_never_apply_twice(scratch_db, migrations):
    assert run(migrations, "apply", "--target", scratch_db, "--pending", "--until", "20261002100000") == 0
    results: list[int] = []
    threads = [threading.Thread(target=lambda: results.append(run(migrations, "apply", "--target", scratch_db, "--pending")))
               for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(results) == [0, 0]
    assert q(scratch_db, "SELECT count(*) FROM soulbah.schema_migration_runs WHERE action = 'apply' AND status = 'succeeded'") == "3"


@needs_pg
def test_baseline_requires_evidence_and_refuses_unverified(scratch_db, migrations, tmp_path):
    with pytest.raises(db_connect.DbError, match="preuve"):
        run(migrations, "baseline", "--target", scratch_db, "--versions", "20990101000000")
    evidence = tmp_path / "state.json"
    evidence.write_text(json.dumps([{"version": "20990101000000", "verdict": "NOT_APPLIED"}]), "utf-8")
    with pytest.raises(db_connect.DbError, match="NOT_APPLIED"):
        run(migrations, "baseline", "--target", scratch_db, "--versions", "20990101000000", "--evidence", str(evidence))
    # Base « restaurée » : l'objet de la première migration existe déjà (créé hors historique).
    db_connect.run_sql(db_connect.parse(scratch_db), "CREATE TABLE public.t_first (id int PRIMARY KEY)", read_only=False)
    evidence.write_text(json.dumps([{"version": "20990101000000", "verdict": "APPLIED"}]), "utf-8")
    assert run(migrations, "baseline", "--target", scratch_db, "--versions", "20990101000000", "--evidence", str(evidence)) == 0
    assert q(scratch_db, "SELECT status FROM soulbah.schema_migrations WHERE version = '20990101000000'") == "baselined"
    # La migration inscrite n'est pas rejouée : seule la seconde reste à appliquer.
    assert run(migrations, "apply", "--target", scratch_db, "--pending") == 0
    assert q(scratch_db, "SELECT string_agg(version || ':' || action, ',' ORDER BY id) FROM soulbah.schema_migration_runs "
                         "WHERE version LIKE '2099%'") == "20990101000000:baseline,20990101000100:apply"


def test_remote_write_requires_three_keys(monkeypatch, migrations):
    remote = db_connect.parse("postgresql://postgres:pw@db.example.supabase.co:5432/postgres")
    args = SimpleNamespace(allow_remote=False, approval=None)
    with pytest.raises(db_connect.DbError, match="distante"):
        migrations.migrate.guard_write(remote, args, "abc")
    args = SimpleNamespace(allow_remote=True, approval="abc")
    monkeypatch.delenv("SOULBAH_MIGRATION_ALLOW_REMOTE", raising=False)
    with pytest.raises(db_connect.DbError, match="distante"):
        migrations.migrate.guard_write(remote, args, "abc")
    monkeypatch.setenv("SOULBAH_MIGRATION_ALLOW_REMOTE", "1")
    with pytest.raises(db_connect.DbError, match="empreinte"):
        migrations.migrate.guard_write(remote, SimpleNamespace(allow_remote=True, approval="autre"), "abc")
    migrations.migrate.guard_write(remote, args, "abc")  # les trois clés : autorisé
    migrations.migrate.guard_write(db_connect.parse("postgresql://postgres@127.0.0.1:54329/x"),
                                   SimpleNamespace(allow_remote=False, approval=None), None)  # local : libre


def test_stub_vector_refused_on_remote_targets(migrations, monkeypatch):
    monkeypatch.setattr(migrations.migrate, "connect",
                        lambda t: db_connect.parse("postgresql://postgres:pw@db.example.supabase.co:5432/postgres"))
    with pytest.raises(db_connect.DbError, match="réservé aux bases locales"):
        migrations.migrate.main(["status", "--target", "x", "--stub-vector"])


# --- Analyse statique des risques ----------------------------------------------------------------------
def test_risk_analysis_patterns(migrations):
    def risk(sql: str) -> str:
        f = migrations.repo / "20990101000900_tmp.sql"
        f.write_text(sql, "utf-8")
        m = next(x for x in migrations.migrate.discover(True) if x.version == "20990101000900")
        out = migrations.migrate.analyse(m)["risk"]
        f.unlink()
        return out

    assert risk("DELETE FROM public.t;") == "HIGH"
    assert risk("DELETE FROM public.t WHERE id = 1;") == "MEDIUM"
    assert risk("ALTER TABLE public.t DROP COLUMN x;") == "HIGH"
    assert risk("TRUNCATE public.t;") == "HIGH"
    # Le mot TRUNCATE d'un trigger qui l'INTERDIT n'est pas une suppression.
    assert risk("CREATE TRIGGER no_trunc BEFORE TRUNCATE ON public.t FOR EACH STATEMENT EXECUTE FUNCTION f();") == "NONE"
    # Le corps d'une fonction ne s'exécute pas pendant la migration…
    assert risk("CREATE OR REPLACE FUNCTION f() RETURNS void LANGUAGE sql AS $$ DELETE FROM t $$;") == "NONE"
    # … un bloc DO, si.
    assert risk("DO $$ BEGIN DELETE FROM t; END $$;") == "HIGH"
    assert risk("CREATE INDEX IF NOT EXISTS i ON public.t (x);") == "LOW"
    assert risk("CREATE INDEX CONCURRENTLY IF NOT EXISTS i ON public.t (x);") == "NONE"


# --- Comparaison de catalogues --------------------------------------------------------------------------
def test_vector_equivalence_is_symmetric_and_vector_only_diffs_are_recognised():
    assert CD.vector_equivalent("real[]", "vector(1536)") and CD.vector_equivalent("vector(768)", "real[]")
    assert not CD.vector_equivalent("text", "vector(3)")
    d = {"section": "columns", "kind": "different", "key": {}, "diff": {"type": {"expected": "vector(1536)", "actual": "real[]"}}}
    assert CD.is_vector_only(d)
    assert CD.is_vector_only({"section": "indexes", "kind": "missing", "key": {"name": "i"},
                              "expected": {"definition": "CREATE INDEX i ON t USING hnsw (e vector_cosine_ops)"}})
    assert not CD.is_vector_only({"section": "indexes", "kind": "missing", "key": {"name": "i"},
                                  "expected": {"definition": "CREATE INDEX i ON t USING btree (x)"}})


def test_compare_and_classify_drift():
    expected = {"tables": [{"schema": "public", "name": "a", "kind": "r", "rls_enabled": True}],
                "columns": [{"schema": "public", "table": "a", "name": "x", "type": "integer", "not_null": True},
                            {"schema": "public", "table": "a", "name": "y", "type": "text", "not_null": False}],
                "constraints": [{"schema": "public", "table": "a", "name": "a_fk", "type": "f", "definition": "FOREIGN KEY (x) REFERENCES b(id)"},
                                {"schema": "public", "table": "a", "name": "a_x_not_null", "type": "n", "definition": "NOT NULL x"}]}
    actual = {"tables": [{"schema": "public", "name": "a", "kind": "r", "rls_enabled": False},
                         {"schema": "public", "name": "z", "kind": "r", "rls_enabled": True}],
              "columns": [{"schema": "public", "table": "a", "name": "x", "type": "bigint", "not_null": True},
                          {"schema": "public", "table": "a", "name": "w", "type": "text", "not_null": False}],
              "constraints": []}
    items = CD.classify(CD.compare(expected, actual, {"public"}, vector_stub=False))
    kinds = sorted(i["drift"] for i in items)
    assert kinds == ["extra_column", "missing_column", "missing_foreign_key", "orphan_table", "rls_mismatch",
                     "type_mismatch"]  # la contrainte NOT NULL (PG 18) n'est pas un écart


def test_duplicate_indexes_and_invalid_policies():
    cat = {"indexes": [{"schema": "public", "table": "t", "name": "i1", "columns": ["a"], "definition": "CREATE INDEX i1 ON t USING btree (a)"},
                       {"schema": "public", "table": "t", "name": "i2", "columns": ["a"], "definition": "CREATE INDEX i2 ON t USING btree (a)"},
                       {"schema": "public", "table": "t", "name": "i3", "columns": ["a"], "definition": "CREATE INDEX i3 ON t USING gin (a)"}],
           "tables": [{"schema": "public", "name": "t", "rls_enabled": True}, {"schema": "public", "name": "u", "rls_enabled": False}],
           "functions": [{"schema": "auth", "name": "uid"}, {"schema": "public", "name": "is_admin"}],
           "builtin_function_names": ["lower", "now"],
           "policies": [
               {"schema": "public", "table": "t", "name": "ok", "using": "(EXISTS ( SELECT 1 FROM x WHERE (x.a = auth.uid())))"},
               {"schema": "public", "table": "t", "name": "absente", "using": "has_role(auth.uid(), 'admin'::app_role)"},
               {"schema": "public", "table": "u", "name": "sans_rls", "using": "is_admin()"}]}
    dup = CD.duplicate_indexes(cat, {"public"})
    assert len(dup) == 1 and dup[0]["indexes"] == ["i1", "i2"]  # i3 : autre méthode d'index
    bad = {p["key"]["name"]: p["problems"] for p in CD.invalid_policies(cat, {"public"})}
    assert set(bad) == {"absente", "sans_rls"}
    assert any("has_role" in x for x in bad["absente"]) and any("sans RLS" in x for x in bad["sans_rls"])


def test_local_query_tool_refuses_remote_hosts(capsys):
    import sqlq
    assert sqlq.main(["postgresql://postgres:pw@db.example.supabase.co:5432/postgres", "select 1"]) == 3
    assert sqlq.main(["supabase", "select 1"]) == 2


def test_catalog_redacts_passwords_and_verifiers_in_query_texts():
    """Incident du DB LOT 0 : pg_stat_statements garde en clair les instructions utilitaires
    (ALTER ROLE … PASSWORD 'SCRAM-SHA-256$…') ; le catalogue ne doit jamais les recopier."""
    import db_catalog
    verifier = "SCRAM-SHA-256$4096:c2FsdA==$c3RvcmVk:c2VydmVy"
    cat = {"top_queries": [{"query": f"ALTER ROLE supabase_replication_admin WITH PASSWORD '{verifier}'"},
                           {"query": f"SELECT '{verifier}' AS v"},
                           {"query": "ALTER USER x PASSWORD 'en clair'"},
                           {"query": "SELECT * FROM t WHERE id = $1"}]}
    out = db_catalog.redact_catalog(cat)
    text = json.dumps(out)
    assert verifier not in text and "en clair" not in text
    assert out["top_queries"][3]["query"] == "SELECT * FROM t WHERE id = $1"


@needs_pg
def test_rollback_needs_down_file_and_header_and_records_history(scratch_db, migrations):
    assert run(migrations, "apply", "--target", scratch_db, "--pending") == 0
    # second : pas d'en-tête rollback → NO → refus avec le plan de reprise
    with pytest.raises(db_connect.DbError, match="rollback=NO"):
        run(migrations, "rollback", "--target", scratch_db, "--pending", "--versions", "20990101000100")
    # first : rollback=YES mais pas de fichier .down.sql → refus
    with pytest.raises(db_connect.DbError, match="absent"):
        run(migrations, "rollback", "--target", scratch_db, "--pending", "--versions", "20990101000000")
    (migrations.repo / "20990101000100_second.sql").write_text(
        "-- soulbah:rollback=YES\nCREATE TABLE IF NOT EXISTS public.t_second (id int PRIMARY KEY REFERENCES public.t_first(id));\n", "utf-8")
    # L'empreinte du fichier a changé après application : verify le voit, l'annulation doit l'ignorer ? Non :
    # la cohérence prime — on remet le fichier d'origine pour ce test.
    (migrations.repo / "20990101000100_second.sql").write_text(
        "CREATE TABLE IF NOT EXISTS public.t_second (id int PRIMARY KEY REFERENCES public.t_first(id));\n", "utf-8")
    (migrations.repo / "20990101000000_first.down.sql").write_text("DROP TABLE IF EXISTS public.t_first CASCADE;\n", "utf-8")
    assert run(migrations, "rollback", "--target", scratch_db, "--pending", "--versions", "20990101000000") == 0
    assert q(scratch_db, "SELECT to_regclass('public.t_first') IS NULL") == "t"
    assert q(scratch_db, "SELECT status FROM soulbah.schema_migrations WHERE version = '20990101000000'") == "rolled_back"
    assert q(scratch_db, "SELECT count(*) FROM soulbah.schema_migration_runs WHERE version = '20990101000000' AND action = 'rollback' AND status = 'succeeded'") == "1"
    # Une migration annulée redevient applicable.
    assert run(migrations, "apply", "--target", scratch_db, "--pending", "--until", "20990101000000") == 0
    assert q(scratch_db, "SELECT status FROM soulbah.schema_migrations WHERE version = '20990101000000'") == "applied"
    assert q(scratch_db, "SELECT to_regclass('public.t_first') IS NOT NULL") == "t"
