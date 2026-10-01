#!/usr/bin/env python3
"""Génère le catalogue d'outils unique (LOT 2) depuis agent/skills/manifests.py.

Sorties (contenu identique, JSON aux clés triées, outils triés par nom, fins de ligne LF) :
  shared/tools/catalog.json                          catalogue de référence
  backend/node-api/src/generated/tool_catalog.json   copie lue par node-api (agentSteps.ts)
  backend/python-ia/app/generated/tool_catalog.json  copie lue par python-ia (reasoning.py)

docker compose construit chaque service dans son propre dossier : les images ne voient
pas shared/, d'où les deux copies, vérifiées octet par octet comme le catalogue.
Le catalogue est validé contre shared/schemas/tool_catalog.schema.json.

Usage :
  python scripts/gen_catalog.py           (ré)écrit les trois fichiers
  python scripts/gen_catalog.py --check   0 = à jour ; 1 = dérive (diff affiché) ;
                                          2 = manifestes ou schéma invalides
Options :
  --root DIR          racine des sorties et du schéma (défaut : ce dépôt)
  --manifests FICHIER manifestes à charger (défaut : agent/skills/manifests.py de ce dépôt)

Bibliothèque standard uniquement : les manifestes sont chargés par leur chemin, sans
importer le paquet skills (ni aucune bibliothèque graphique).
"""
from __future__ import annotations

import argparse
import difflib
import importlib.util
import json
import re
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

REPO = Path(__file__).resolve().parents[1]
DEFAULT_MANIFESTS = REPO / "agent" / "skills" / "manifests.py"
SCHEMA = Path("shared/schemas/tool_catalog.schema.json")
CATALOG = Path("shared/tools/catalog.json")
COPIES = (
    Path("backend/node-api/src/generated/tool_catalog.json"),
    Path("backend/python-ia/app/generated/tool_catalog.json"),
)
MAX_DIFF_LINES = 150


# --- Chargement --------------------------------------------------------------------
def load_manifests(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("soulbah_tool_manifests", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"manifestes introuvables : {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def render(catalog: dict[str, Any]) -> str:
    """Forme canonique : clés triées, indentation 2, UTF-8 lisible, LF final."""
    return json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


# --- Validation JSON Schema (sous-ensemble utilisé par le schéma du catalogue) -------
_ANNOTATIONS = {"$schema", "$id", "$defs", "title", "description"}
_KEYWORDS = {
    "type", "enum", "const", "pattern", "required", "properties", "additionalProperties", "items",
    "minItems", "maxItems", "uniqueItems", "minLength", "minimum", "exclusiveMinimum", "anyOf", "$ref",
}


def _is_type(value: Any, name: str) -> bool:
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "string":
        return isinstance(value, str)
    if name == "array":
        return isinstance(value, list)
    if name == "object":
        return isinstance(value, dict)
    raise ValueError(f"type JSON Schema inconnu : {name}")


def _resolve(ref: str, root: dict[str, Any]) -> dict[str, Any]:
    if not ref.startswith("#/"):
        raise ValueError(f"$ref non local non supporté : {ref}")
    node: Any = root
    for part in ref[2:].split("/"):
        node = node[part]
    return node


def validate(value: Any, schema: dict[str, Any], root: dict[str, Any], where: str = "$") -> list[str]:
    """Erreurs de `value` vis-à-vis de `schema` (mots-clés inconnus = erreur du schéma)."""
    unknown = set(schema) - _KEYWORDS - _ANNOTATIONS
    if unknown:
        raise ValueError(f"mot-clé de schéma non supporté par gen_catalog.py : {sorted(unknown)} ({where})")
    if "$ref" in schema:
        return validate(value, _resolve(schema["$ref"], root), root, where)
    errors: list[str] = []
    if "anyOf" in schema:
        if all(validate(value, sub, root, where) for sub in schema["anyOf"]):
            errors.append(f"{where} : aucune des formes admises (anyOf)")
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, t) for t in types):
            return errors + [f"{where} : type {'/'.join(types)} attendu"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{where} : valeur {schema['const']!r} attendue")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{where} : {value!r} hors de {schema['enum']}")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{where} : texte trop court")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append(f"{where} : {value!r} ne respecte pas {schema['pattern']}")
    if _is_type(value, "number"):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{where} : < {schema['minimum']}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            errors.append(f"{where} : ≤ {schema['exclusiveMinimum']}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{where} : au moins {schema['minItems']} élément(s)")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{where} : au plus {schema['maxItems']} élément(s)")
        if schema.get("uniqueItems"):
            dumped = [json.dumps(v, sort_keys=True) for v in value]
            if len(set(dumped)) != len(dumped):
                errors.append(f"{where} : éléments en double")
        if "items" in schema:
            for i, item in enumerate(value):
                errors.extend(validate(item, schema["items"], root, f"{where}[{i}]"))
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{where} : clé obligatoire absente « {key} »")
        props = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for key, item in value.items():
            if key in props:
                errors.extend(validate(item, props[key], root, f"{where}.{key}"))
            elif extra is False:
                errors.append(f"{where} : clé non prévue « {key} »")
            elif isinstance(extra, dict):
                errors.extend(validate(item, extra, root, f"{where}.{key}"))
    return errors


# --- Génération / contrôle ---------------------------------------------------------
def build(manifests_path: Path, root: Path) -> tuple[str | None, list[str]]:
    """(texte du catalogue, erreurs). Texte None si les manifestes ou le schéma sont invalides."""
    try:
        module = load_manifests(manifests_path)
    except Exception as e:  # noqa: BLE001 - erreur d'import/syntaxe des manifestes
        return None, [f"chargement des manifestes impossible ({manifests_path}) : {e}"]
    problems = list(module.manifest_problems())
    if problems:
        return None, [f"manifeste invalide : {p}" for p in problems]
    catalog = module.build_catalog()
    schema_path = root / SCHEMA
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        errors = validate(catalog, schema, schema)
    except (OSError, ValueError, KeyError) as e:
        return None, [f"schéma inutilisable ({schema_path}) : {e}"]
    if errors:
        return None, [f"catalogue non conforme au schéma : {e}" for e in errors]
    return render(catalog), []


def _diff(rel: Path, actual: str, expected: str) -> list[str]:
    lines = list(difflib.unified_diff(
        actual.splitlines(keepends=True), expected.splitlines(keepends=True),
        fromfile=f"{rel.as_posix()} (versionné)", tofile=f"{rel.as_posix()} (attendu d'après les manifestes)", n=2,
    ))
    if len(lines) > MAX_DIFF_LINES:
        lines = lines[:MAX_DIFF_LINES] + [f"… {len(lines) - MAX_DIFF_LINES} ligne(s) de diff non affichée(s)\n"]
    return [ln if ln.endswith("\n") else ln + "\n" for ln in lines]


def check(text: str, root: Path) -> int:
    drift = 0
    for rel in (CATALOG, *COPIES):
        path = root / rel
        try:
            actual = path.read_text(encoding="utf-8").replace("\r\n", "\n")
        except FileNotFoundError:
            print(f"✖ {rel.as_posix()} : fichier absent")
            drift += 1
            continue
        if actual != text:
            print(f"✖ {rel.as_posix()} : différent des manifestes")
            sys.stdout.writelines(_diff(rel, actual, text))
            drift += 1
    if drift:
        print(f"Dérive du catalogue d'outils ({drift} fichier(s)) : lancez « python scripts/gen_catalog.py » "
              "puis versionnez les fichiers générés (docs/CATALOGUE_OUTILS.md).")
        return 1
    print(f"Catalogue d'outils à jour ({1 + len(COPIES)} fichiers conformes aux manifestes).")
    return 0


def write(text: str, root: Path) -> int:
    for rel in (CATALOG, *COPIES):
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(f"écrit : {rel.as_posix()}")
    return 0


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
        except (AttributeError, ValueError):
            pass
    parser = argparse.ArgumentParser(description="Catalogue d'outils SoulBah (LOT 2)")
    parser.add_argument("--check", action="store_true", help="vérifie sans écrire (1 = dérive)")
    parser.add_argument("--root", type=Path, default=REPO, help="racine des sorties et du schéma")
    parser.add_argument("--manifests", type=Path, default=DEFAULT_MANIFESTS, help="fichier des manifestes")
    args = parser.parse_args(argv)

    text, errors = build(args.manifests, args.root)
    if text is None:
        for e in errors:
            print(f"✖ {e}")
        return 2
    return check(text, args.root) if args.check else write(text, args.root)


if __name__ == "__main__":
    sys.exit(main())
