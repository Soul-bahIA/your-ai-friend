"""Analyse robuste des valeurs renvoyées par les LLM ou lues dans l'environnement."""
from __future__ import annotations

_TRUE = {"true", "1", "yes", "y", "oui", "vrai", "on"}
_FALSE = {"false", "0", "no", "n", "non", "faux", "off", "none", "null", ""}


def parse_bool(value, default: bool = False) -> bool:
    """Booléen strict : bool("false") vaut True en Python, pas ici (T43).

    - bool -> tel quel ; None -> `default` ;
    - int/float -> 0 = False, sinon True ;
    - chaîne -> true/1/yes/oui/vrai/on = True, false/0/no/non/faux/off/null/"" = False ;
    - toute autre valeur (liste, dict, chaîne inconnue) -> `default`.
    """
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        v = value.strip().lower()
        if v in _TRUE:
            return True
        if v in _FALSE:
            return False
    return default
