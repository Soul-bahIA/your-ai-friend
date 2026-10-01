"""Rédaction des secrets (LOT 6 — S8, critère « canari ») avant tout journal, évènement
ou rapport.

Trois niveaux, tous appliqués côté agent (le serveur ne doit JAMAIS recevoir un secret) :

  - `redact_text`  : masque dans une chaîne les motifs de secrets connus (clés d'API,
    jetons, JWT, clés privées PEM, `password=…`, en-têtes d'autorisation, longues
    chaînes hexadécimales) ainsi que des VALEURS connues : la clé agent courante
    (`SOULBAH_AGENT_KEY`) et la liste `SOULBAH_REDACT_VALUES` (séparateur `;`, par
    exemple un canari de test). Libellé : « [secret masqué] ».
  - `redact_obj`   : copie profonde d'une structure JSON ; les clés de texte libre des
    manifestes (`is_secret_text` : text, content) et les clés de secrets
    (password, secret, token, api_key, authorization, key_hash…) deviennent
    « [texte masqué : N car.] » — même libellé que le LOT 1 (skills.base.mask_text,
    backend/node-api/src/lib/redact.ts) ; toute autre chaîne passe par `redact_text`.
    Un champ déjà masqué n'est pas remasqué. Profondeur bornée.
  - `RedactingFormatter` : formateur logging qui applique `redact_text` au message
    FORMATÉ (arguments et trace compris) ; branché sur la console et le fichier
    agent.log par soulbah_agent._setup_logging.

Ce module n'importe que la bibliothèque standard et skills.manifests.
"""
from __future__ import annotations

import json
import logging
import os
import re
from typing import Any

from skills.manifests import secret_param_names

SECRET_MASK = "[secret masqué]"
TOO_DEEP_MASK = "[trop profond : masqué]"
MAX_DEPTH = 20
# Valeurs d'environnement : en dessous de cette longueur, une valeur n'est pas
# recherchée (masquer « a » ou « 12 » rendrait les journaux illisibles).
_MIN_VALUE_LEN = 4

# Libellé du LOT 1 (« [texte masqué : N car.] ») : reconnu pour ne pas remasquer.
_ALREADY_MASKED = re.compile(r"^\[texte masqué : \d+ car\.\]$")

# Clés de secrets, quelle que soit la casse ; `.*token` couvre access_token,
# approval_token… ; les paramètres `is_secret_text` des manifestes s'y ajoutent.
_SECRET_KEY_RE = re.compile(
    r"^(password|passwd|pwd|secret|client_secret|.*token|api[_-]?key|apikey|authorization|"
    r"key_hash|agent_key|x-agent-key|private_key)$",
    re.IGNORECASE,
)
_MANIFEST_SECRET_KEYS: frozenset[str] = secret_param_names()

# Motifs de secrets (ordre : les blocs PEM d'abord, les formes génériques ensuite).
_PATTERNS: tuple[re.Pattern[str], ...] = (
    # Clé privée PEM : du BEGIN jusqu'au END correspondant, ou jusqu'à la fin si END manque.
    re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?:.*?-----END [A-Z0-9 ]*PRIVATE KEY-----|.*)", re.DOTALL),
    # Clés d'API : OpenAI/Anthropic (sk-…), clés agent SoulBah (sbk_…), jetons d'approbation (sbap_…),
    # AWS (AKIA…), GitHub (ghp_/gho_/ghu_/ghs_/ghr_), Slack (xox[baprs]-…).
    re.compile(r"\bsk-[A-Za-z0-9_-]{8,}"),
    re.compile(r"\bsbk_[A-Za-z0-9_-]{8,}"),
    re.compile(r"\bsbap_[A-Za-z0-9_.-]{8,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"),
    # JWT : trois segments base64url dont le premier commence par eyJ (« {" »).
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]*)?"),
    # En-têtes d'autorisation.
    re.compile(r"(?i)(authorization\s*[:=]\s*(?:bearer|basic|token)\s+)(?!\[secret masqué\])\S+"),
    re.compile(r"(?i)(x-agent-key\s*[:=]\s*)(?!\[secret masqué\])\S+"),
    # Chaînes hexadécimales longues (≥ 40 : SHA-1, SHA-256, clés brutes).
    re.compile(r"\b[0-9a-fA-F]{40,}\b"),
)
# `password=…`, `passwd=…`, `secret=…`, `token=…`, `api_key=…` (séparateur = ou :, valeur
# éventuellement entre guillemets) : la clé est conservée, la valeur masquée. Une valeur
# déjà masquée n'est pas reprise (idempotence).
_KV_PATTERN = re.compile(
    r"(?i)\b((?:password|passwd|pwd|secret|client_secret|token|access_token|refresh_token|"
    r"api[_-]?key|apikey)\s*[=:]\s*)(?!\[secret masqué\])[\"']?([^\s\"'&;,]+)[\"']?"
)


def _env_values() -> list[str]:
    """Valeurs à masquer lues à CHAQUE appel (la clé peut être chargée après l'import,
    un test peut poser un canari) : clé agent + SOULBAH_REDACT_VALUES, les plus longues
    d'abord pour qu'un préfixe ne casse pas une valeur plus longue."""
    values: set[str] = set()
    key = os.environ.get("SOULBAH_AGENT_KEY", "").strip()
    if len(key) >= _MIN_VALUE_LEN:
        values.add(key)
    for raw in os.environ.get("SOULBAH_REDACT_VALUES", "").split(";"):
        v = raw.strip()
        if len(v) >= _MIN_VALUE_LEN:
            values.add(v)
    return sorted(values, key=len, reverse=True)


def redact_text(s: str) -> str:
    """Masque les secrets d'une chaîne (motifs connus + valeurs d'environnement).
    Idempotent : un texte déjà masqué ressort inchangé."""
    if not isinstance(s, str) or not s:
        return s
    out = s
    for value in _env_values():
        if value in out:
            out = out.replace(value, SECRET_MASK)
    for pattern in _PATTERNS:
        if pattern.groups:
            out = pattern.sub(lambda m: m.group(1) + SECRET_MASK, out)
        else:
            out = pattern.sub(SECRET_MASK, out)
    out = _KV_PATTERN.sub(lambda m: m.group(1) + SECRET_MASK, out)
    return out


def mask_label(value: Any) -> str:
    """« [texte masqué : N car.] » (LOT 1) ; N = longueur du texte (ou de son JSON)."""
    if isinstance(value, str):
        return f"[texte masqué : {len(value)} car.]"
    try:
        rendered = json.dumps(value, ensure_ascii=False, default=str)
    except (TypeError, ValueError):
        rendered = str(value)
    return f"[texte masqué : {len(rendered)} car.]"


def is_secret_key(key: Any, secret_keys: frozenset[str] | set[str] | None = None) -> bool:
    if not isinstance(key, str):
        return False
    keys = _MANIFEST_SECRET_KEYS if secret_keys is None else secret_keys
    return key in keys or bool(_SECRET_KEY_RE.match(key.strip()))


def redact_obj(value: Any, secret_keys: frozenset[str] | set[str] | None = None, depth: int = 0) -> Any:
    """Copie profonde rédigée de `value` (dict / list / tuple / scalaires).

    `secret_keys` : clés de texte libre à masquer entièrement (défaut : paramètres
    `is_secret_text` des manifestes) — s'ajoutent aux clés de secrets génériques."""
    if depth > MAX_DEPTH:
        return TOO_DEEP_MASK if isinstance(value, (dict, list, tuple)) else value
    if isinstance(value, dict):
        out: dict[Any, Any] = {}
        for k, v in value.items():
            if is_secret_key(k, secret_keys):
                if v is None or v == "":
                    out[k] = v
                elif isinstance(v, str) and (_ALREADY_MASKED.match(v) or v == SECRET_MASK):
                    out[k] = v
                else:
                    out[k] = mask_label(v)
            else:
                out[k] = redact_obj(v, secret_keys, depth + 1)
        return out
    if isinstance(value, (list, tuple)):
        return [redact_obj(v, secret_keys, depth + 1) for v in value]
    if isinstance(value, str):
        return redact_text(value)
    return value


class RedactingFormatter(logging.Formatter):
    """Formateur logging : le message FORMATÉ (gabarit, arguments, trace d'exception)
    passe par `redact_text`. Un secret glissé dans un argument de log ou dans une
    exception n'atteint donc ni la console ni agent.log."""

    def format(self, record: logging.LogRecord) -> str:  # noqa: A003 - API logging
        return redact_text(super().format(record))

    def formatException(self, ei) -> str:  # noqa: N802 - API logging
        return redact_text(super().formatException(ei))
