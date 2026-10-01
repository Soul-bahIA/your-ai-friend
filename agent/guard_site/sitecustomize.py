"""Garde réseau des processus Python ENFANTS de l'agent en mode OFFLINE (V3).

Ce dossier (guard_site/) est placé en tête de PYTHONPATH par network_guard.child_env() : Python
importe ce sitecustomize au démarrage et installe la même garde que l'agent (connexions vers
Internet refusées). Hors OFFLINE, rien n'est fait. Source : shared/config/guard_site/.
"""
try:
    import os as _os

    if (_os.environ.get("SOULBAH_MODE") or "").strip().upper() == "OFFLINE":
        import network_guard as _ng
        import soulbah_settings as _ss

        _res = _ss.resolve({k: v for k, v in _os.environ.items() if k in _ss.ENV_KEYS})
        if not _res["errors"]:
            _ng.install(_res["settings"])
except Exception:  # noqa: BLE001 - une garde illisible ne doit pas empêcher le programme de démarrer
    pass
