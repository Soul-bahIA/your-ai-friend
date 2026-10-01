#!/usr/bin/env python3
"""Vérifie que docker-compose transmet aux services les variables qu'ils lisent (T26).

Une variable est EXIGÉE pour un service quand elle est :
  * documentée dans backend/.env.example (ligne « NOM=… ») ;
  * ET citée comme littéral de chaîne ("NOM" ou 'NOM') dans le code du service
    (os.getenv("NOM"), process.env.NOM, tables de profils, etc.).
Elle doit alors figurer dans `environment:` du service (ancres YAML et clés de fusion
`<<` résolues), sinon le service l'ignore silencieusement sous Docker.

Sources de la configuration compose :
  * par défaut : backend/docker-compose.yml lu avec PyYAML (pip install pyyaml) ;
  * --compose-json FICHIER : sortie de `docker compose config --format json` (CI : la
    fusion et l'interpolation sont alors celles de Docker lui-même).

Sortie : 0 si tout est transmis, 1 sinon (liste des variables manquantes).
Usage : python scripts/ci/check_compose_env.py [--compose FICHIER | --compose-json FICHIER]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENV_EXAMPLE = ROOT / "backend" / ".env.example"
COMPOSE = ROOT / "backend" / "docker-compose.yml"

# Service compose → (dossier du code, extensions lues).
SERVICES = {
    "python-ia": (ROOT / "backend" / "python-ia" / "app", (".py",)),
    "node-api": (ROOT / "backend" / "node-api" / "src", (".ts",)),
}

# Variables volontairement NON transmises : (service, variable) → raison.
EXCLUDED: dict[tuple[str, str], str] = {
    # AUTH_MODE=dev-local exige HOST en boucle locale ; le conteneur écoute sur 0.0.0.0 :
    # node-api refuserait de démarrer. Mode supabase imposé sous Docker (LOT 3).
    ("node-api", "AUTH_MODE"): "auth de dev hors Docker uniquement (HOST=0.0.0.0 dans le conteneur)",
    ("node-api", "DEV_LOCAL_USER_ID"): "auth de dev hors Docker uniquement",
    ("node-api", "DEV_LOCAL_TOKEN"): "auth de dev hors Docker uniquement",
}


def documented_vars() -> set[str]:
    text = ENV_EXAMPLE.read_text(encoding="utf-8")
    return set(re.findall(r"(?m)^([A-Z][A-Z0-9_]*)=", text))


def code_vars(folder: Path, exts: tuple[str, ...], candidates: set[str]) -> set[str]:
    found: set[str] = set()
    for f in folder.rglob("*"):
        if f.suffix in exts and f.is_file():
            code = f.read_text(encoding="utf-8")
            for name in re.findall(r"""["']([A-Z][A-Z0-9_]+)["']|process\.env\.([A-Z][A-Z0-9_]+)""", code):
                for n in name:
                    if n in candidates:
                        found.add(n)
    return found


def load_compose(args: argparse.Namespace) -> dict:
    if args.compose_json:
        return json.loads(Path(args.compose_json).read_text(encoding="utf-8"))
    try:
        import yaml  # type: ignore[import-untyped]
    except ImportError:
        raise SystemExit("PyYAML absent : pip install pyyaml, ou --compose-json (docker compose config --format json)")
    return yaml.safe_load(Path(args.compose).read_text(encoding="utf-8"))


def service_env(service: dict) -> set[str]:
    env = service.get("environment") or {}
    if isinstance(env, list):  # forme « - NOM=valeur »
        return {str(e).split("=", 1)[0] for e in env}
    return set(env)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--compose", default=str(COMPOSE), help="docker-compose.yml (lu avec PyYAML)")
    src.add_argument("--compose-json", help="sortie de `docker compose config --format json`")
    args = ap.parse_args()

    documented = documented_vars()
    services = load_compose(args).get("services") or {}
    missing: list[str] = []
    total = 0
    for name, (folder, exts) in SERVICES.items():
        if name not in services:
            missing.append(f"service « {name} » absent du compose")
            continue
        needed = code_vars(folder, exts, documented)
        present = service_env(services[name])
        total += len(needed)
        for var in sorted(needed - present):
            if (name, var) in EXCLUDED:
                print(f"ignoré : {name} {var} ({EXCLUDED[(name, var)]})")
                continue
            missing.append(f"{name} : {var} (documentée dans backend/.env.example, lue par le code)")
    if missing:
        for m in missing:
            print(f"ERREUR : variable non transmise par docker-compose — {m}", file=sys.stderr)
        return 1
    print(f"OK : {total} variables documentées et lues par python-ia / node-api, toutes transmises par compose.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
