"""Catalogue complet d'une base PostgreSQL, en LECTURE SEULE — SoulbahDatabaseBaseline (DB LOT 0).

    python scripts/db/db_catalog.py <cible> --out <dossier> [--no-counts] [--label NOM]

Cibles : supabase | dev | URL postgresql:// (voir db_connect.py). Chaque section est lue dans sa propre
transaction READ ONLY : une section refusée (droits) est notée en erreur sans arrêter les autres.

Écrit dans <dossier> :
  catalog.json      tous les objets (schémas, tables, colonnes, PK/FK/UNIQUE/CHECK, index, vues, vues
                    matérialisées, séquences, types énumérés, fonctions et procédures, triggers, policies,
                    RLS, rôles, droits, extensions, publications), statistiques d'usage, volumes
  functions.sql     définitions des fonctions des schémas applicatifs (relecture, diff)
  baseline.json     résumé : version, empreintes du schéma (globale et par schéma), état des migrations,
                    volumes, horodatage

Aucune donnée de ligne n'est lue : seulement des comptes (`count(*)`) et le catalogue.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db_connect import Conn, DbError, connect, run_sql  # noqa: E402

# Schémas gérés par Supabase ou par une extension : inventoriés, jamais modifiés par Soulbah.
MANAGED_SCHEMAS = ("auth", "storage", "realtime", "_realtime", "vault", "graphql", "graphql_public", "extensions",
                   "pgbouncer", "supabase_functions", "supabase_migrations", "net", "cron", "pgsodium",
                   "pgsodium_masks", "_analytics", "pgtle", "topology", "tiger", "tiger_data")
SYSTEM_FILTER = "n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema'"


def _arr(values) -> str:
    return "ARRAY[" + ",".join("'" + v.replace("'", "''") + "'" for v in values) + "]::text[]"


SECTIONS: dict[str, str] = {
    "meta": """
SELECT json_build_object(
  'server_version', current_setting('server_version'),
  'server_version_num', current_setting('server_version_num')::int,
  'database', current_database(),
  'size_bytes', pg_database_size(current_database()),
  'encoding', pg_encoding_to_char((SELECT encoding FROM pg_database WHERE datname = current_database())),
  'collation', (SELECT datcollate FROM pg_database WHERE datname = current_database()),
  'timezone', current_setting('TimeZone'),
  'current_user', current_user,
  'is_superuser', (SELECT rolsuper FROM pg_roles WHERE rolname = current_user),
  'settings', (SELECT json_object_agg(name, setting) FROM pg_settings WHERE name IN
     ('max_connections','shared_buffers','work_mem','maintenance_work_mem','statement_timeout',
      'idle_in_transaction_session_timeout','default_transaction_read_only','wal_level','max_wal_size',
      'effective_cache_size','random_page_cost','search_path','row_security','password_encryption')))""",
    "extensions": """
SELECT coalesce(json_agg(json_build_object('name', e.extname, 'version', e.extversion, 'schema', n.nspname)
  ORDER BY e.extname), '[]') FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace""",
    "available_extensions": """
SELECT coalesce(json_agg(json_build_object('name', name, 'default_version', default_version,
  'installed_version', installed_version) ORDER BY name), '[]')
FROM pg_available_extensions WHERE name IN ('vector','pg_trgm','pgcrypto','uuid-ossp','pg_stat_statements',
  'pg_cron','pgsodium','supabase_vault','pg_net','pg_graphql','pgaudit','pg_partman','hypopg','index_advisor',
  'pg_repack','btree_gin','btree_gist','unaccent','citext','ltree','postgis')""",
    "schemas": f"""
SELECT coalesce(json_agg(json_build_object('name', n.nspname, 'owner', pg_get_userbyid(n.nspowner),
  'acl', n.nspacl::text[], 'comment', obj_description(n.oid, 'pg_namespace')) ORDER BY n.nspname), '[]')
FROM pg_namespace n WHERE {SYSTEM_FILTER}""",
    "tables": f"""
SELECT coalesce(json_agg(json_build_object(
  'schema', n.nspname, 'name', c.relname, 'kind', c.relkind, 'owner', pg_get_userbyid(c.relowner),
  'rls_enabled', c.relrowsecurity, 'rls_forced', c.relforcerowsecurity, 'persistence', c.relpersistence,
  'is_partition', c.relispartition, 'reltuples', c.reltuples::bigint,
  'total_bytes', pg_total_relation_size(c.oid), 'table_bytes', pg_relation_size(c.oid),
  'reloptions', c.reloptions, 'acl', c.relacl::text[], 'comment', obj_description(c.oid, 'pg_class'))
  ORDER BY n.nspname, c.relname), '[]')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p','f') AND {SYSTEM_FILTER}""",
    "columns": f"""
SELECT coalesce(json_agg(json_build_object(
  'schema', n.nspname, 'table', c.relname, 'name', a.attname, 'position', a.attnum,
  'type', format_type(a.atttypid, a.atttypmod), 'not_null', a.attnotnull,
  'default', pg_get_expr(d.adbin, d.adrelid), 'identity', nullif(a.attidentity, ''),
  'generated', nullif(a.attgenerated, ''),
  'collation', CASE WHEN a.attcollation <> t.typcollation THEN (SELECT collname FROM pg_collation WHERE oid = a.attcollation) END,
  'comment', col_description(c.oid, a.attnum))
  ORDER BY n.nspname, c.relname, a.attnum), '[]')
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_type t ON t.oid = a.atttypid
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r','p','v','m','f') AND {SYSTEM_FILTER}""",
    "constraints": f"""
SELECT coalesce(json_agg(json_build_object(
  'schema', n.nspname, 'table', c.relname, 'name', k.conname, 'type', k.contype,
  'definition', pg_get_constraintdef(k.oid, true), 'validated', k.convalidated,
  'deferrable', k.condeferrable, 'columns', (SELECT array_agg(attname ORDER BY attnum) FROM pg_attribute
     WHERE attrelid = k.conrelid AND attnum = ANY(k.conkey)),
  'ref_table', CASE WHEN k.contype = 'f' THEN k.confrelid::regclass::text END,
  'ref_columns', CASE WHEN k.contype = 'f' THEN (SELECT array_agg(attname ORDER BY attnum) FROM pg_attribute
     WHERE attrelid = k.confrelid AND attnum = ANY(k.confkey)) END,
  'on_delete', CASE WHEN k.contype = 'f' THEN k.confdeltype END,
  'on_update', CASE WHEN k.contype = 'f' THEN k.confupdtype END)
  ORDER BY n.nspname, c.relname, k.conname), '[]')
FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE {SYSTEM_FILTER}""",
    "indexes": f"""
SELECT coalesce(json_agg(json_build_object(
  'schema', n.nspname, 'table', t.relname, 'name', i.relname, 'definition', pg_get_indexdef(x.indexrelid),
  'unique', x.indisunique, 'primary', x.indisprimary, 'valid', x.indisvalid, 'ready', x.indisready,
  'columns', (SELECT array_agg(pg_get_indexdef(x.indexrelid, k, true) ORDER BY k)
              FROM generate_subscripts(x.indkey, 1) AS k),
  'predicate', pg_get_expr(x.indpred, x.indrelid), 'bytes', pg_relation_size(i.oid),
  'constraint', (SELECT conname FROM pg_constraint WHERE conindid = x.indexrelid LIMIT 1),
  'scans', s.idx_scan)
  ORDER BY n.nspname, t.relname, i.relname), '[]')
FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class t ON t.oid = x.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
LEFT JOIN pg_stat_all_indexes s ON s.indexrelid = x.indexrelid
WHERE {SYSTEM_FILTER}""",
    "views": f"""
SELECT coalesce(json_agg(json_build_object(
  'schema', n.nspname, 'name', c.relname, 'kind', c.relkind, 'owner', pg_get_userbyid(c.relowner),
  'definition_md5', md5(pg_get_viewdef(c.oid, true)), 'definition', pg_get_viewdef(c.oid, true),
  'options', c.reloptions, 'acl', c.relacl::text[], 'populated', c.relispopulated)
  ORDER BY n.nspname, c.relname), '[]')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('v','m') AND {SYSTEM_FILTER}""",
    "sequences": f"""
SELECT coalesce(json_agg(json_build_object(
  'schema', s.schemaname, 'name', s.sequencename, 'type', s.data_type::text, 'last_value', s.last_value,
  'owned_by', (SELECT d.refobjid::regclass::text || '.' || a.attname FROM pg_depend d
               JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
               WHERE d.objid = (quote_ident(s.schemaname) || '.' || quote_ident(s.sequencename))::regclass
                 AND d.deptype IN ('a','i') LIMIT 1))
  ORDER BY s.schemaname, s.sequencename), '[]')
FROM pg_sequences s JOIN pg_namespace n ON n.nspname = s.schemaname WHERE {SYSTEM_FILTER}""",
    "types": f"""
SELECT coalesce(json_agg(json_build_object(
  'schema', n.nspname, 'name', t.typname, 'kind', t.typtype,
  'labels', CASE WHEN t.typtype = 'e' THEN (SELECT array_agg(enumlabel ORDER BY enumsortorder) FROM pg_enum
                                           WHERE enumtypid = t.oid) END,
  'base', CASE WHEN t.typtype = 'd' THEN format_type(t.typbasetype, t.typtypmod) END,
  'domain_check', CASE WHEN t.typtype = 'd' THEN (SELECT string_agg(pg_get_constraintdef(oid), ' AND ')
                                                 FROM pg_constraint WHERE contypid = t.oid) END)
  ORDER BY n.nspname, t.typname), '[]')
FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE t.typtype IN ('e','d') AND {SYSTEM_FILTER}""",
    "functions": f"""
SELECT coalesce(json_agg(json_build_object(
  'schema', n.nspname, 'name', p.proname, 'kind', p.prokind,
  'args', pg_get_function_identity_arguments(p.oid), 'returns', pg_get_function_result(p.oid),
  'language', l.lanname, 'security_definer', p.prosecdef, 'volatility', p.provolatile,
  'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner), 'acl', p.proacl::text[],
  'source_md5', md5(btrim(regexp_replace(regexp_replace(coalesce(p.prosrc, ''), '\\s+', ' ', 'g'),
                                         '\\s*([(),;=])\\s*', '\\1', 'g'))),
  'source_md5_raw', md5(coalesce(p.prosrc, '')),
  'source_has_crlf', position(chr(13) IN coalesce(p.prosrc, '')) > 0, 'leakproof', p.proleakproof,
  'extension', (SELECT e.extname FROM pg_depend d JOIN pg_extension e ON e.oid = d.refobjid
                WHERE d.objid = p.oid AND d.deptype = 'e' LIMIT 1))
  ORDER BY n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)), '[]')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
WHERE {SYSTEM_FILTER}""",
    "triggers": f"""
SELECT coalesce(json_agg(json_build_object(
  'schema', n.nspname, 'table', c.relname, 'name', g.tgname, 'definition', pg_get_triggerdef(g.oid, true),
  'enabled', g.tgenabled, 'function', g.tgfoid::regprocedure::text)
  ORDER BY n.nspname, c.relname, g.tgname), '[]')
FROM pg_trigger g JOIN pg_class c ON c.oid = g.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT g.tgisinternal AND {SYSTEM_FILTER}""",
    "builtin_function_names": """
SELECT coalesce(json_agg(DISTINCT proname), '[]') FROM pg_proc WHERE pronamespace = 'pg_catalog'::regnamespace""",
    "event_triggers": """
SELECT coalesce(json_agg(json_build_object('name', evtname, 'event', evtevent, 'enabled', evtenabled,
  'function', evtfoid::regprocedure::text, 'tags', evttags) ORDER BY evtname), '[]') FROM pg_event_trigger""",
    "policies": """
SELECT coalesce(json_agg(json_build_object(
  'schema', schemaname, 'table', tablename, 'name', policyname, 'permissive', permissive, 'roles', roles,
  'cmd', cmd, 'using', qual, 'with_check', with_check) ORDER BY schemaname, tablename, policyname), '[]')
FROM pg_policies""",
    "roles": """
SELECT coalesce(json_agg(json_build_object(
  'name', r.rolname, 'superuser', r.rolsuper, 'inherit', r.rolinherit, 'create_role', r.rolcreaterole,
  'create_db', r.rolcreatedb, 'login', r.rolcanlogin, 'replication', r.rolreplication,
  'bypass_rls', r.rolbypassrls, 'connection_limit', r.rolconnlimit, 'valid_until', r.rolvaliduntil,
  'config', r.rolconfig,
  'member_of', (SELECT array_agg(g.rolname ORDER BY g.rolname) FROM pg_auth_members m
                JOIN pg_roles g ON g.oid = m.roleid WHERE m.member = r.oid))
  ORDER BY r.rolname), '[]')
FROM pg_roles r WHERE r.rolname NOT LIKE 'pg\\_%'""",
    "table_grants": f"""
SELECT coalesce(json_agg(json_build_object('schema', n.nspname, 'table', c.relname,
  'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
  'privilege', a.privilege_type, 'grantable', a.is_grantable)
  ORDER BY n.nspname, c.relname, 3, a.privilege_type), '[]')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
     LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
WHERE c.relkind IN ('r','p','v','m','f') AND {SYSTEM_FILTER}""",
    "function_grants": f"""
SELECT coalesce(json_agg(json_build_object('schema', n.nspname, 'function',
  p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
  'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
  'privilege', a.privilege_type) ORDER BY n.nspname, 2, 3), '[]')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
     LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
WHERE {SYSTEM_FILTER} AND n.nspname NOT IN ('extensions','graphql','graphql_public','pgbouncer','vault','realtime','storage','auth')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')""",
    "default_privileges": """
SELECT coalesce(json_agg(json_build_object('role', pg_get_userbyid(d.defaclrole),
  'schema', (SELECT nspname FROM pg_namespace WHERE oid = d.defaclnamespace), 'object_type', d.defaclobjtype,
  'acl', d.defaclacl::text[]) ORDER BY 1, 2, 3), '[]') FROM pg_default_acl d""",
    "publications": """
SELECT coalesce(json_agg(json_build_object('publication', pubname, 'schema', schemaname, 'table', tablename)
  ORDER BY 1, 2, 3), '[]') FROM pg_publication_tables""",
    "table_stats": f"""
SELECT coalesce(json_agg(json_build_object('schema', s.schemaname, 'table', s.relname,
  'seq_scan', s.seq_scan, 'seq_tup_read', s.seq_tup_read, 'idx_scan', s.idx_scan,
  'n_live_tup', s.n_live_tup, 'n_dead_tup', s.n_dead_tup, 'n_mod_since_analyze', s.n_mod_since_analyze,
  'last_vacuum', s.last_vacuum, 'last_autovacuum', s.last_autovacuum, 'last_analyze', s.last_analyze,
  'last_autoanalyze', s.last_autoanalyze) ORDER BY 1, 2), '[]')
FROM pg_stat_all_tables s
WHERE s.schemaname NOT LIKE 'pg\\_%' AND s.schemaname <> 'information_schema'""",
    "activity": """
SELECT json_build_object('connections', (SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()),
  'by_state', (SELECT json_object_agg(coalesce(state, 'null'), n) FROM
     (SELECT state, count(*) AS n FROM pg_stat_activity WHERE datname = current_database() GROUP BY 1) x),
  'locks_waiting', (SELECT count(*) FROM pg_locks WHERE NOT granted))""",
}

# Historiques de migrations : lus seulement si la table existe (sinon : absent, sans erreur).
HISTORY_SECTIONS: dict[str, tuple[str, str]] = {
    "supabase_migrations": ("supabase_migrations.schema_migrations", """
SELECT coalesce(json_agg(json_build_object('version', version, 'name', name) ORDER BY version), '[]')
FROM supabase_migrations.schema_migrations"""),
    "soulbah_migrations": ("soulbah.schema_migrations", """
SELECT coalesce(json_agg(row_to_json(m) ORDER BY m.version), '[]') FROM soulbah.schema_migrations m"""),
}

# Lus séparément : extensions et droits parfois absents ; une erreur n'arrête pas le catalogue.
OPTIONAL_SECTIONS: dict[str, str] = {
    "top_queries": """
SELECT coalesce(json_agg(q), '[]') FROM (
  SELECT json_build_object('calls', calls, 'total_ms', round(total_exec_time::numeric, 1),
    'mean_ms', round(mean_exec_time::numeric, 2), 'rows', rows,
    'query', left(regexp_replace(query, '\\s+', ' ', 'g'), 400)) AS q
  FROM extensions.pg_stat_statements
  WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  ORDER BY total_exec_time DESC LIMIT 30) s""",
}


def row_count_sql(schemas: list[str]) -> str:
    return f"""
SELECT coalesce(json_agg(json_build_object('schema', n.nspname, 'table', c.relname,
  'rows', (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM %I.%I', n.nspname, c.relname),
           false, true, '')))[1]::text::bigint) ORDER BY n.nspname, c.relname), '[]')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND n.nspname = ANY({_arr(schemas)})"""


SECRET_PATTERNS = [
    (re.compile(r"(PASSWORD\s+)'[^']*'", re.IGNORECASE), r"\1'***'"),
    (re.compile(r"SCRAM-SHA-256\$[^\s'\"]+"), "SCRAM-SHA-256$***"),
    (re.compile(r"\bmd5[0-9a-f]{32}\b"), "md5***"),
    (re.compile(r"(\b(?:secret|token|api[_-]?key|apikey)\b\s*[:=]\s*)'[^']*'", re.IGNORECASE), r"\1'***'"),
]


def redact_text(text: str | None) -> str | None:
    """Masque mots de passe, vérificateurs SCRAM/MD5 et jetons dans un texte de requête (pg_stat_statements ne
    normalise pas les instructions utilitaires : ALTER ROLE … PASSWORD y apparaît en clair)."""
    if not text:
        return text
    for pattern, repl in SECRET_PATTERNS:
        text = pattern.sub(repl, text)
    return text


def redact_catalog(catalog: dict) -> dict:
    for q in catalog.get("top_queries") or []:
        if isinstance(q, dict):
            q["query"] = redact_text(q.get("query"))
    return catalog


def fetch(conn: Conn, name: str, sql: str) -> object:
    out = run_sql(conn, sql).strip()
    try:
        return json.loads(out) if out else None
    except json.JSONDecodeError as e:
        raise DbError(f"section {name} : JSON illisible ({e})") from e


def canonical_hash(obj: object) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"),
                                     default=str).encode("utf-8")).hexdigest()


STRUCTURAL = ("schemas", "tables", "columns", "constraints", "indexes", "views", "sequences", "types", "functions",
              "triggers", "policies", "extensions")
VOLATILE_KEYS = {"reltuples", "total_bytes", "table_bytes", "bytes", "scans", "last_value", "populated"}


def structural_view(catalog: dict, schema: str | None = None) -> dict:
    """Partie structurelle du catalogue (sans statistiques ni volumes), pour l'empreinte."""
    out: dict = {}
    for section in STRUCTURAL:
        items = catalog.get(section) or []
        if not isinstance(items, list):
            continue
        rows = []
        for item in items:
            if not isinstance(item, dict):
                continue
            if schema is not None and item.get("schema", item.get("name") if section == "schemas" else None) != schema:
                continue
            rows.append({k: v for k, v in item.items() if k not in VOLATILE_KEYS})
        out[section] = rows
    return out


STRUCTURAL_SECTIONS = ("meta", "extensions", "schemas", "tables", "columns", "constraints", "indexes", "views",
                       "sequences", "types", "functions", "builtin_function_names", "triggers", "policies",
                       "table_grants", "function_grants", "publications")


def build(conn: Conn, counts: bool = True, sections: tuple[str, ...] | None = None) -> dict:
    """`sections` : sous-ensemble de SECTIONS (ex. STRUCTURAL_SECTIONS pour un instantané rapide)."""
    catalog: dict = {"_errors": {}}
    for name, sql in SECTIONS.items():
        if sections is not None and name not in sections:
            continue
        try:
            catalog[name] = fetch(conn, name, sql)
        except DbError as e:
            catalog[name] = None
            catalog["_errors"][name] = str(e)[:500]
    for name, (relation, sql) in HISTORY_SECTIONS.items():
        if sections is not None:
            break
        try:
            present = run_sql(conn, f"SELECT to_regclass('{relation}') IS NOT NULL").strip() == "t"
            catalog[name] = fetch(conn, name, sql) if present else None
        except DbError as e:
            catalog[name] = None
            catalog["_errors"][name] = str(e)[:500]
    for name, sql in OPTIONAL_SECTIONS.items():
        if sections is not None:
            break
        try:
            catalog[name] = fetch(conn, name, sql)
        except DbError as e:
            catalog[name] = None
            catalog["_errors"][name] = str(e)[:300]
    schemas = [s["name"] for s in (catalog.get("schemas") or [])]
    app = [s for s in schemas if s not in MANAGED_SCHEMAS]
    catalog["app_schemas"] = app
    catalog["managed_schemas"] = [s for s in schemas if s in MANAGED_SCHEMAS]
    if counts:
        for group, names in (("row_counts", app), ("managed_row_counts", ["auth", "storage"])):
            names = [s for s in names if s in schemas]
            if not names:
                catalog[group] = []
                continue
            try:
                catalog[group] = fetch(conn, group, row_count_sql(names))
            except DbError as e:
                catalog[group] = None
                catalog["_errors"][group] = str(e)[:300]
    return catalog


def function_definitions(conn: Conn, schemas: list[str]) -> str:
    if not schemas:
        return ""
    sql = f"""
SELECT string_agg('-- ' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  || chr(10) || pg_get_functiondef(p.oid) || ';', chr(10) || chr(10) ORDER BY n.nspname, p.proname,
  pg_get_function_identity_arguments(p.oid))
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prokind IN ('f','p','w') AND n.nspname = ANY({_arr(schemas)})
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')"""
    return run_sql(conn, sql)


def summary(catalog: dict, label: str, conn_label: str) -> dict:
    meta = catalog.get("meta") or {}
    app = catalog.get("app_schemas") or []
    per_schema = {s: canonical_hash(structural_view(catalog, s)) for s in sorted(
        set(app) | set(catalog.get("managed_schemas") or []))}

    def count(section: str, schema_filter=None) -> int:
        items = catalog.get(section) or []
        return sum(1 for i in items if isinstance(i, dict) and (schema_filter is None or i.get("schema") in schema_filter)
                   and not i.get("extension"))  # fonctions d'extension (ex. pgvector dans public) exclues

    return {
        "baseline": "SoulbahDatabaseBaseline",
        "label": label,
        "taken_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "connection": conn_label,
        "server_version": meta.get("server_version"),
        "database": meta.get("database"),
        "size_bytes": meta.get("size_bytes"),
        "schema_hash": canonical_hash(structural_view(catalog)),
        "schema_hash_app": canonical_hash({s: structural_view(catalog, s) for s in sorted(app)}),
        "schema_hash_by_schema": per_schema,
        "app_schemas": app,
        "managed_schemas": catalog.get("managed_schemas"),
        "migration_state": {
            "supabase_migrations": "absent" if catalog.get("supabase_migrations") is None
            else len(catalog["supabase_migrations"]),
            "soulbah_migrations": "absent" if catalog.get("soulbah_migrations") is None
            else len(catalog["soulbah_migrations"]),
        },
        "objects_app": {k: count(k, app) for k in ("tables", "columns", "constraints", "indexes", "views", "sequences",
                                                   "types", "functions", "triggers", "policies")},
        "objects_all": {k: count(k) for k in ("tables", "indexes", "functions", "triggers", "policies")},
        "extension_functions_in_app_schemas": sum(1 for f in (catalog.get("functions") or [])
                                                  if f.get("extension") and f.get("schema") in app),
        "extensions": [f"{e['name']} {e['version']} ({e['schema']})" for e in (catalog.get("extensions") or [])],
        "row_counts": {f"{r['schema']}.{r['table']}": r["rows"] for r in (catalog.get("row_counts") or [])},
        "managed_row_counts": {f"{r['schema']}.{r['table']}": r["rows"] for r in (catalog.get("managed_row_counts") or [])},
        "errors": catalog.get("_errors"),
    }


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target")
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="")
    ap.add_argument("--no-counts", action="store_true")
    a = ap.parse_args(argv)
    conn = connect(a.target)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    catalog = redact_catalog(build(conn, counts=not a.no_counts))
    (out / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=1, sort_keys=True, default=str),
                                      "utf-8")
    try:
        (out / "functions.sql").write_text(function_definitions(conn, catalog.get("app_schemas") or []), "utf-8")
    except DbError as e:
        catalog["_errors"]["function_definitions"] = str(e)[:300]
    base = summary(catalog, a.label or a.target, conn.label())
    (out / "baseline.json").write_text(json.dumps(base, ensure_ascii=False, indent=1, sort_keys=False, default=str),
                                       "utf-8")
    print(json.dumps({k: base[k] for k in ("label", "server_version", "schema_hash", "app_schemas", "objects_app",
                                           "migration_state", "errors")}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except DbError as e:
        print(f"✖ {e}", file=sys.stderr)
        sys.exit(1)
