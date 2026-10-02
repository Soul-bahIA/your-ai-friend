"""Inventaire lisible d'un catalogue (db_catalog.py) — partie « inventaire » du Database Baseline (DB LOT 0).

    python scripts/db/baseline_report.py <dossier contenant catalog.json et baseline.json>

Écrit INVENTORY.md dans le même dossier : moteur, version, schémas, extensions, tables (volumes, taille, RLS,
nombre de colonnes, de policies, d'index), clés primaires et étrangères, contraintes, index, vues, fonctions,
triggers, policies, rôles, droits des rôles clients sur les tables, publications, historique des migrations.
Aucune donnée de ligne : seulement le catalogue et des comptes.
"""
from __future__ import annotations

import collections
import json
import sys
from pathlib import Path

CLIENT_ROLES = ("anon", "authenticated", "PUBLIC", "service_role", "soulbah_api")
CONSTRAINT_TYPES = {"p": "PK", "f": "FK", "u": "UNIQUE", "c": "CHECK", "x": "EXCLUDE", "n": "NOT NULL"}


def md_escape(text) -> str:
    return str(text if text is not None else "").replace("|", "\\|").replace("\n", " ")


def main(argv: list[str]) -> int:
    folder = Path(argv[0])
    cat = json.loads((folder / "catalog.json").read_text("utf-8"))
    base = json.loads((folder / "baseline.json").read_text("utf-8"))
    app = set(cat.get("app_schemas") or [])
    meta = cat.get("meta") or {}
    rows = {(r["schema"], r["table"]): r["rows"] for r in (cat.get("row_counts") or []) + (cat.get("managed_row_counts") or [])}
    out: list[str] = [f"# Inventaire — {base.get('label')}", "",
                      f"Relevé le {base.get('taken_at')} en lecture seule (`{base.get('connection')}`).", "",
                      "## Moteur", "", "| Élément | Valeur |", "|---|---|"]
    out += [f"| Version | PostgreSQL {meta.get('server_version')} |",
            f"| Base | {meta.get('database')} ({(meta.get('size_bytes') or 0) / 1e6:.1f} Mo) |",
            f"| Encodage, collation | {meta.get('encoding')}, {meta.get('collation')} |",
            f"| Fuseau | {meta.get('timezone')} |",
            f"| Empreinte du schéma (tout) | `{base.get('schema_hash')}` |",
            f"| Empreinte des schémas applicatifs | `{base.get('schema_hash_app')}` |"]
    for k, v in sorted((meta.get("settings") or {}).items()):
        out.append(f"| {k} | {md_escape(v)} |")
    out += ["", "## Schémas", "", "| Schéma | Géré par | Propriétaire | Empreinte |", "|---|---|---|---|"]
    for s in cat.get("schemas") or []:
        owner = "Soulbah" if s["name"] in app else "Supabase / extension"
        out.append(f"| {s['name']} | {owner} | {s.get('owner')} | `{(base.get('schema_hash_by_schema') or {}).get(s['name'], '')[:16]}…` |")
    out += ["", "## Extensions", "", "| Extension | Version | Schéma |", "|---|---|---|"]
    out += [f"| {e['name']} | {e['version']} | {e['schema']} |" for e in cat.get("extensions") or []]
    pol_by_table = collections.Counter((p["schema"], p["table"]) for p in cat.get("policies") or [])
    idx_by_table = collections.Counter((i["schema"], i["table"]) for i in cat.get("indexes") or [])
    col_by_table = collections.Counter((c["schema"], c["table"]) for c in cat.get("columns") or [])
    out += ["", "## Tables des schémas applicatifs", "",
            "| Table | Lignes | Taille | RLS | Colonnes | Policies | Index |", "|---|---|---|---|---|---|---|"]
    for t in cat.get("tables") or []:
        if t["schema"] not in app:
            continue
        k = (t["schema"], t["name"])
        out.append(f"| {t['schema']}.{t['name']} | {rows.get(k, '?')} | {(t.get('total_bytes') or 0) / 1024:.0f} Ko | "
                   f"{'oui' if t.get('rls_enabled') else '**non**'} | {col_by_table[k]} | {pol_by_table[k]} | {idx_by_table[k]} |")
    managed = collections.Counter(t["schema"] for t in cat.get("tables") or [] if t["schema"] not in app)
    out += ["", "Tables des schémas gérés (jamais modifiées par Soulbah) : " +
            ", ".join(f"{s} {n}" for s, n in sorted(managed.items())) + ".", "",
            "Volumes des schémas gérés (comptes) : " + ", ".join(
                f"{k} {v}" for k, v in sorted((base.get('managed_row_counts') or {}).items()) if v) + "."]
    out += ["", "## Colonnes", "", "| Table | Colonne | Type | NOT NULL | Défaut |", "|---|---|---|---|---|"]
    for c in cat.get("columns") or []:
        if c["schema"] in app:
            out.append(f"| {c['schema']}.{c['table']} | {c['name']} | {md_escape(c['type'])} | "
                       f"{'oui' if c.get('not_null') else ''} | {md_escape(c.get('default'))[:60]} |")
    out += ["", "## Contraintes (PK, FK, UNIQUE, CHECK)", "", "| Table | Nom | Type | Validée | Définition |",
            "|---|---|---|---|---|"]
    for k in cat.get("constraints") or []:
        if k["schema"] in app and k["type"] != "n":
            out.append(f"| {k['schema']}.{k['table']} | {k['name']} | {CONSTRAINT_TYPES.get(k['type'], k['type'])} | "
                       f"{'oui' if k.get('validated') else '**NOT VALID**'} | {md_escape(k.get('definition'))[:160]} |")
    out += ["", "## Index", "", "| Table | Index | Unique | Lectures (idx_scan) | Définition |", "|---|---|---|---|---|"]
    for i in cat.get("indexes") or []:
        if i["schema"] in app:
            out.append(f"| {i['schema']}.{i['table']} | {i['name']} | {'oui' if i.get('unique') else ''} | "
                       f"{i.get('scans')} | {md_escape(i.get('definition'))[:150]} |")
    views = [v for v in cat.get("views") or [] if v["schema"] in app]
    out += ["", "## Vues et vues matérialisées", ""]
    out += [f"- {v['schema']}.{v['name']} ({'matérialisée' if v['kind'] == 'm' else 'vue'})" for v in views] or ["Aucune."]
    out += ["", "## Fonctions (hors extensions)", "", "| Fonction | Langage | SECURITY DEFINER | search_path | Fins de ligne CRLF |",
            "|---|---|---|---|---|"]
    for f in cat.get("functions") or []:
        if f["schema"] in app and not f.get("extension"):
            out.append(f"| {f['schema']}.{f['name']}({md_escape(f['args'])}) | {f['language']} | "
                       f"{'**oui**' if f.get('security_definer') else ''} | {md_escape(f.get('config'))} | "
                       f"{'oui' if f.get('source_has_crlf') else ''} |")
    ext_count = sum(1 for f in cat.get("functions") or [] if f["schema"] in app and f.get("extension"))
    out.append(f"\nFonctions d'extensions installées dans un schéma applicatif : {ext_count} (pgvector dans public).")
    out += ["", "## Triggers", ""]
    out += [f"- {t['schema']}.{t['table']} : `{md_escape(t['definition'])}`" for t in cat.get("triggers") or []
            if t["schema"] in app] or ["Aucun."]
    out += ["", f"Triggers d'événement : {', '.join(e['name'] + ' → ' + e['function'] for e in cat.get('event_triggers') or []) or 'aucun'}."]
    out += ["", "## Policies (RLS)", "", "| Table | Policy | Commande | Rôles | USING | WITH CHECK |", "|---|---|---|---|---|---|"]
    for p in cat.get("policies") or []:
        if p["schema"] in app:
            out.append(f"| {p['schema']}.{p['table']} | {md_escape(p['name'])} | {p['cmd']} | {md_escape(p.get('roles'))} | "
                       f"{md_escape(p.get('using'))[:120]} | {md_escape(p.get('with_check'))[:120]} |")
    out += ["", "## Rôles", "", "| Rôle | Connexion | Superuser | BYPASSRLS | Membre de |", "|---|---|---|---|---|"]
    for r in cat.get("roles") or []:
        out.append(f"| {r['name']} | {'oui' if r.get('login') else ''} | {'**oui**' if r.get('superuser') else ''} | "
                   f"{'oui' if r.get('bypass_rls') else ''} | {md_escape(', '.join(r.get('member_of') or []))[:80]} |")
    out += ["", "## Droits des rôles clients sur les tables applicatives", "", "| Table | " + " | ".join(CLIENT_ROLES) + " |",
            "|---|" + "---|" * len(CLIENT_ROLES)]
    grants: dict[tuple, dict[str, set]] = collections.defaultdict(lambda: collections.defaultdict(set))
    for g in cat.get("table_grants") or []:
        if g["schema"] in app and g["grantee"] in CLIENT_ROLES:
            grants[(g["schema"], g["table"])][g["grantee"]].add(g["privilege"][:3])
    for t in cat.get("tables") or []:
        k = (t["schema"], t["name"])
        if t["schema"] in app:
            out.append(f"| {k[0]}.{k[1]} | " + " | ".join(",".join(sorted(grants[k][r])) for r in CLIENT_ROLES) + " |")
    out += ["", "## Publications temps réel", ""]
    out += [f"- {p['publication']} : {p['schema']}.{p['table']}" for p in cat.get("publications") or []
            if p["schema"] in app] or ["Aucune."]
    ms = base.get("migration_state") or {}
    out += ["", "## Historique des migrations", "",
            f"- `supabase_migrations.schema_migrations` : {ms.get('supabase_migrations')}",
            f"- `soulbah.schema_migrations` : {ms.get('soulbah_migrations')}"]
    if (folder / "migration_state.json").exists():
        state = json.loads((folder / "migration_state.json").read_text("utf-8"))
        out += ["", "État réel déduit des objets (`migration_state.json`) :", "",
                "| Migration | Verdict | Objets présents | Absents | Différents |", "|---|---|---|---|---|"]
        out += [f"| {m['file']} | {m['verdict']} | {m['present']} | {m['absent']} | {m['differs']} |" for m in state]
    tq = cat.get("top_queries") or []
    out += ["", "## Requêtes les plus coûteuses (pg_stat_statements, normalisées)", ""]
    out += [f"- {q['calls']} appels, {q['total_ms']} ms au total, {q['mean_ms']} ms en moyenne : `{md_escape(q['query'])[:200]}`"
            for q in tq[:15]] or ["Indisponible."]
    act = cat.get("activity") or {}
    out += ["", f"Connexions ouvertes au relevé : {act.get('connections')} ({act.get('by_state')}) ; verrous en attente : "
                f"{act.get('locks_waiting')}."]
    (folder / "INVENTORY.md").write_text("\n".join(out) + "\n", "utf-8")
    print(f"INVENTORY.md : {len(out)} lignes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
