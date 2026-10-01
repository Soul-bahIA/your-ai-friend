"""Configuration centrale de Soulbah (V3 LOT 1) — implémentation Python de référence.

SOURCE UNIQUE : shared/config/soulbah_settings.py. Copies à l'identique (test de non-dérive) :
agent/soulbah_settings.py et backend/python-ia/app/soulbah_settings.py — `python
scripts/sync_shared.py` les réécrit. Le plan de contrôle a l'équivalent TypeScript
(backend/node-api/src/lib/soulbahSettings.ts) ; les trois passent les mêmes cas
(shared/config/resolution_cases.json).

Résolution : valeurs par défaut < fichier JSON < variables d'environnement SOULBAH_*.
  - fichier : SOULBAH_CONFIG (chemin explicite : absent = erreur), sinon
    <racine du dépôt>/soulbah.config.json s'il existe (jamais versionné) ;
  - toute valeur invalide est une ERREUR (le service refuse de démarrer) : une faute de
    frappe dans SOULBAH_MODE ne doit jamais ouvrir le cloud ni le réseau en silence.

Modes (mission V3 §8) :
  OFFLINE         aucune connexion externe ; modèles, données et outils locaux uniquement ;
  LOCAL_INTERNET  modèles locaux ; Internet pour la recherche, la documentation, git, les
                  téléchargements autorisés — jamais pour le raisonnement ;
  HYBRID          local prioritaire, fournisseurs cloud configurés autorisés (défaut :
                  comportement historique de Soulbah V2).

Bibliothèque standard uniquement.
"""
from __future__ import annotations

import json
import os
import re
from typing import Any, Mapping

MODES = ("OFFLINE", "LOCAL_INTERNET", "HYBRID")
MODE_LABELS = {"OFFLINE": "OFFLINE — 100% LOCAL", "LOCAL_INTERNET": "LOCAL + INTERNET", "HYBRID": "HYBRID"}
RESOURCE_PROFILES = ("ECO", "BALANCED", "MAX")
ECO_MAX_AGENTS = 2
MAX_AGENTS_RANGE = (1, 32)
MAX_ALLOW_HOSTS = 32
CONFIG_FILE_NAME = "soulbah.config.json"

DEFAULTS: dict[str, Any] = {
    "mode": "HYBRID",
    "max_agents": 6,
    "resource_profile": "BALANCED",
    "model_policy": "auto",
    "network": {"allow_hosts": []},
    "computer_control": True,
    "recording": True,
    "self_improvement": False,
}

ENV_KEYS: dict[str, str] = {
    "SOULBAH_MODE": "mode",
    "SOULBAH_MAX_PARALLEL_AGENTS": "max_agents",
    "SOULBAH_RESOURCE_PROFILE": "resource_profile",
    "SOULBAH_MODEL_POLICY": "model_policy",
    "SOULBAH_NETWORK_ALLOW_HOSTS": "network.allow_hosts",
    "SOULBAH_COMPUTER_CONTROL": "computer_control",
    "SOULBAH_RECORDING": "recording",
    "SOULBAH_SELF_IMPROVEMENT": "self_improvement",
}

_TRUE = ("1", "true", "yes", "on", "oui")
_FALSE = ("0", "false", "no", "off", "non")
_MODEL_POLICY_RE = re.compile(r"^[A-Za-z0-9_.:/-]{1,100}$")
_HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$|^[0-9a-f:.]{2,45}$")
_TOP_KEYS = tuple(DEFAULTS)


def _mode(value: Any) -> tuple[str | None, str | None]:
    if not isinstance(value, str):
        return None, "mode : texte attendu (OFFLINE | LOCAL_INTERNET | HYBRID)"
    norm = re.sub(r"[\s+\-]+", "_", value.strip().upper())
    if norm not in MODES:
        return None, f"mode inconnu « {value.strip()[:40]} » (OFFLINE | LOCAL_INTERNET | HYBRID)"
    return norm, None


def _profile(value: Any) -> tuple[str | None, str | None]:
    if not isinstance(value, str) or value.strip().upper() not in RESOURCE_PROFILES:
        return None, f"resource_profile inconnu « {str(value)[:40]} » (ECO | BALANCED | MAX)"
    return value.strip().upper(), None


def _max_agents(value: Any) -> tuple[int | None, str | None]:
    lo, hi = MAX_AGENTS_RANGE
    if isinstance(value, str) and re.fullmatch(r"\s*\d+\s*", value):
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int) or not lo <= value <= hi:
        return None, f"max_agents : entier de {lo} à {hi} attendu (reçu « {str(value)[:20]} »)"
    return value, None


def _model_policy(value: Any) -> tuple[str | None, str | None]:
    if not isinstance(value, str) or not _MODEL_POLICY_RE.match(value.strip()):
        return None, "model_policy : « auto » ou identifiant de modèle (lettres, chiffres, _ . : / -)"
    return value.strip(), None


def _bool(name: str, value: Any) -> tuple[bool | None, str | None]:
    if isinstance(value, bool):
        return value, None
    if isinstance(value, str):
        v = value.strip().lower()
        if v in _TRUE:
            return True, None
        if v in _FALSE:
            return False, None
    return None, f"{name} : booléen attendu (true / false)"


def _hosts(value: Any) -> tuple[list[str] | None, str | None]:
    if isinstance(value, str):
        value = [h for h in (p.strip() for p in value.split(",")) if h]
    if not isinstance(value, list) or len(value) > MAX_ALLOW_HOSTS:
        return None, f"network.allow_hosts : liste de {MAX_ALLOW_HOSTS} hôtes au plus attendue"
    out: list[str] = []
    for h in value:
        if not isinstance(h, str):
            return None, "network.allow_hosts : chaque hôte est un texte"
        host = h.strip().lower()
        if host.startswith("[") and host.endswith("]"):
            host = host[1:-1]
        if not host or not _HOST_RE.match(host) or "/" in host:
            return None, f"network.allow_hosts : hôte invalide « {h[:60]} » (nom ou adresse IP, sans schéma ni port)"
        if host not in out:
            out.append(host)
    return out, None


_VALIDATORS = {
    "mode": _mode,
    "max_agents": _max_agents,
    "resource_profile": _profile,
    "model_policy": _model_policy,
    "network.allow_hosts": _hosts,
    "computer_control": lambda v: _bool("computer_control", v),
    "recording": lambda v: _bool("recording", v),
    "self_improvement": lambda v: _bool("self_improvement", v),
}


def _set(settings: dict[str, Any], key: str, value: Any) -> None:
    if key == "network.allow_hosts":
        settings["network"] = {"allow_hosts": value}
    else:
        settings[key] = value


def _apply_file(settings: dict[str, Any], data: Any, errors: list[str]) -> None:
    if not isinstance(data, dict):
        errors.append("fichier de configuration : objet JSON attendu")
        return
    for key, value in data.items():
        if key.startswith("$") or key == "description":
            continue  # $schema, commentaires
        if key not in _TOP_KEYS:
            errors.append(f"fichier de configuration : clé inconnue « {key} »")
            continue
        if key == "network":
            if not isinstance(value, dict) or set(value) - {"allow_hosts"}:
                errors.append("fichier de configuration : network = {\"allow_hosts\": [...]} attendu")
                continue
            if "allow_hosts" not in value:
                continue
            key, value = "network.allow_hosts", value["allow_hosts"]
        parsed, err = _VALIDATORS[key](value)
        if err:
            errors.append(f"fichier de configuration : {err}")
        else:
            _set(settings, key, parsed)


def default_config_path(repo_root: str | None) -> str | None:
    if not repo_root:
        return None
    path = os.path.join(repo_root, CONFIG_FILE_NAME)
    return path if os.path.isfile(path) else None


def resolve(env: Mapping[str, str] | None = None, file_data: Any = None, file_path: str | None = None
            ) -> dict[str, Any]:
    """{"settings", "errors", "source"} — fonction pure (fichier déjà lu, ou None)."""
    env = os.environ if env is None else env
    settings: dict[str, Any] = json.loads(json.dumps(DEFAULTS))
    errors: list[str] = []
    if file_data is not None:
        _apply_file(settings, file_data, errors)
    env_used: list[str] = []
    for var, key in ENV_KEYS.items():
        raw = env.get(var)
        if raw is None or not str(raw).strip():
            continue
        parsed, err = _VALIDATORS[key](str(raw))
        if err:
            errors.append(f"{var} : {err}")
        else:
            _set(settings, key, parsed)
            env_used.append(var)
    return {"settings": settings, "errors": errors, "source": {"file": file_path, "env": env_used}}


def load(repo_root: str | None = None, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """Lit SOULBAH_CONFIG ou <repo_root>/soulbah.config.json, puis résout."""
    env = os.environ if env is None else env
    explicit = (env.get("SOULBAH_CONFIG") or "").strip()
    path = explicit or default_config_path(repo_root)
    data: Any = None
    errors: list[str] = []
    if path:
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except FileNotFoundError:
            errors.append(f"SOULBAH_CONFIG : fichier introuvable « {path} »")
            path = None
        except (OSError, ValueError) as e:
            errors.append(f"fichier de configuration illisible « {path} » : {e}")
            data = None
    out = resolve(env, data, path)
    out["errors"] = errors + out["errors"]
    return out


# --- Politique dérivée (mêmes règles en TypeScript) --------------------------------------
def cloud_models_allowed(settings: Mapping[str, Any]) -> bool:
    """Fournisseurs de modèles cloud (API) : HYBRID seulement."""
    return settings.get("mode") == "HYBRID"


def internet_allowed(settings: Mapping[str, Any]) -> bool:
    """Accès Internet (recherche, documentation, git distant, téléchargements) : hors OFFLINE."""
    return settings.get("mode") != "OFFLINE"


def is_loopback_host(host: str) -> bool:
    h = host.strip().lower().strip("[]")
    return h in ("localhost", "::1", "0:0:0:0:0:0:0:1") or h.startswith("127.") or h.endswith(".localhost")


def is_local_name(host: str) -> bool:
    """Nom sans point ni « : » (service Docker « python-ia », machine du réseau local) : jamais
    un hôte d'Internet."""
    h = host.strip().lower().strip("[]")
    return bool(h) and "." not in h and ":" not in h


def host_allowed(settings: Mapping[str, Any], host: str) -> bool:
    """Connexion vers `host` permise ? Bouclage et noms locaux sans point toujours ; hôtes
    déclarés (machine de l'utilisateur, ex. serveur de modèles du réseau local) toujours ;
    le reste hors OFFLINE seulement."""
    h = host.strip().lower().strip("[]")
    if is_loopback_host(h) or is_local_name(h):
        return True
    if h in (settings.get("network") or {}).get("allow_hosts", []):
        return True
    return internet_allowed(settings)


def is_local_endpoint(settings: Mapping[str, Any], host: str) -> bool:
    """Machine de l'utilisateur : bouclage, nom local sans point, ou hôte déclaré. Un serveur de
    modèle « local » (LOCAL_LLM_URL) doit l'être hors HYBRID, même en LOCAL_INTERNET : sinon
    ce serait un modèle distant."""
    h = host.strip().lower().strip("[]")
    return is_loopback_host(h) or is_local_name(h) or h in (settings.get("network") or {}).get("allow_hosts", [])


def effective_max_agents(settings: Mapping[str, Any]) -> int:
    """Profil ECO : 2 agents au plus (mission V3 §76) ; BALANCED et MAX : max_agents."""
    n = int(settings.get("max_agents") or DEFAULTS["max_agents"])
    return min(n, ECO_MAX_AGENTS) if settings.get("resource_profile") == "ECO" else n


def mode_label(settings: Mapping[str, Any]) -> str:
    return MODE_LABELS.get(str(settings.get("mode")), str(settings.get("mode")))


def public_view(settings: Mapping[str, Any]) -> dict[str, Any]:
    """Vue exposée par les API (aucun secret dans la configuration)."""
    return {
        **json.loads(json.dumps(dict(settings))),
        "label": mode_label(settings),
        "cloud_models_allowed": cloud_models_allowed(settings),
        "internet_allowed": internet_allowed(settings),
        "effective_max_agents": effective_max_agents(settings),
    }
