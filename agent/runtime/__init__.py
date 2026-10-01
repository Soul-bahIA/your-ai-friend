"""Runtime V2 de l'agent local (LOT 8 — audit §9.2 P3 EXÉCUTION).

    python -m runtime.supervisor        # processus principal (bail, journal, workers)
    python -m runtime.worker --task …   # un processus enfant par tâche (lancé par le superviseur)

Modules : version (poignée de main), journal (SQLite WAL + outbox), rtclient (routes
/api/v2/runtime/*), worker (exécution d'une tâche avec état des actions), supervisor
(garde d'instance, baux, Job Object par tâche, réconciliation), legacy_adapter (boucle V1
quand le serveur n'a pas la V2), instance_lock (garde mutuelle agent V1 / runtime).
"""
