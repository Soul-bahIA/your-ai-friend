# LOT 8 — Runtime V2 et packaging (et LOT 9 côté agent)

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §9.2 (P3 EXÉCUTION : superviseur, bail, journal
SQLite WAL + outbox, slots, un Job Object par tâche, legacy_adapter), §9.6 (slots), §9.8 (preuves), §9.9
(reprise après crash), §13 lignes « 8. Runtime + packaging » et « 9. Tool Gateway et preuves », §14 (instance
unique, breakaway pour `open_app`). Contrat serveur : `docs/LOT7_SESSIONS_SCHEDULER.md` et routes du LOT 8
(`/api/v2/runtime/tasks/:id/actions`, `/api/v2/runtime/reconcile`, poignée de main 426).

## 1. Architecture (`agent/runtime/`)

```
runtime.supervisor  (1 processus par PC, garde d'instance unique)
 ├─ register (version 2.0.0, protocole 1)      426 → sortie 4 · 404 → legacy_adapter (boucle V1)
 ├─ reconcile (tâches du journal)              resume → worker --resume · abandon/cancel → purge
 ├─ boucle : outbox · reap · keepalive · hangs · lease(slots = max − détenues ; 0 si outbox non vide)
 └─ worker × N  (python -m runtime.worker, chacun dans SON Job Object : KILL_ON_JOB_CLOSE + BREAKAWAY_OK)
      └─ Executor + PermissionGate existants (V1), état des actions, checkpoints, preuves, final
journal.db (SQLite WAL, partagé) : held_tasks · actions · checkpoints · outbox
```

| Module | Rôle |
|---|---|
| `version.py` | `RUNTIME_VERSION = "2.0.0"`, `PROTOCOL = 1` (poignée de main) |
| `instance_lock.py` | verrou exclusif `instance.lock` `{pid, kind}` ; périmé si le PID est mort ou n'est plus Python ; **mutuel** avec l'agent V1 (`soulbah_agent._serve` le prend aussi) |
| `journal.py` | SQLite WAL, `synchronous=FULL`, transactions `BEGIN IMMEDIATE` : une ligne est entière ou absente, même après un kill ; actions monotones (mêmes règles que node) ; outbox ordonnée avec backoff 2 s → 120 s et réclamation atomique |
| `rtclient.py` | client des routes runtime (hérite de `client.TaskClient`) ; écritures durables (result, message, checkpoint, actions, ack) mises en outbox sur erreur transitoire, 409/410/400 définitifs ; `request_approval` envoie `v2_task_id` ; `put_artifact` (LOT 9) |
| `worker.py` | exécute `spec.steps` avec l'executor existant ; état des actions `planned → attempted → executed → verified` (ou `failed` / `simulated`) écrit dans le journal **avant** l'envoi ; checkpoint après chaque étape ; reprise §9.9 ; final `result` ou message `ERROR {kind}` |
| `evidence.py` | preuves typées d'après les manifestes (LOT 9) ; captures → artefacts sha256 |
| `supervisor.py` | garde, poignée de main, réconciliation, baux, Job Object par tâche, keepalive, détection des blocages, reprise locale, arrêt propre |
| `legacy_adapter.py` | boucle V1 (`soulbah_agent._serve_locked`) dans le superviseur, un seul slot, sans dupliquer de code |

Modifications du code existant : `executor.run_task(on_step=…)` (observateur des phases d'une étape),
`skills/proctree.popen_in_job` (lancement suspendu dans un job, `breakaway_ok`), `skills/open_app`
(`CREATE_BREAKAWAY_FROM_JOB`, repli sans le drapeau), `soulbah_agent.build_executor` (contrôles de démarrage
partagés V1/V2) et garde d'instance dans `_serve`.

## 2. Reprise après crash (§9.9 appliqué)

| Situation | Comportement |
|---|---|
| Worker mort sans final (crash, kill) | relancé par le superviseur **avec la même tentative** depuis le journal (`--resume`), au plus 2 fois, puis message `ERROR crash` |
| Étape `verified` (ou skipped/simulated) | sautée, reportée dans le résultat avec `resumed: true` |
| Étape `executed` | actée `verified` sans ré-exécution (preuve brute déjà enregistrée) |
| Étape `attempted`, outil idempotent (`wait`, `read_file`…) | rejouée |
| Étape `attempted`, outil **non** idempotent (`move_file`, `type_text`, `run_command`…) | message `QUESTION` (« la rejouer ? »), tâche en WAITING, worker arrêté (code 5) ; le superviseur relance seulement à réception d'une réponse (keepalive) ; « oui » → rejouée une fois, autre réponse → échec |
| Superviseur tué | ses handles se ferment, le Job Object de chaque worker tue l'arbre ; au redémarrage : réconciliation **avant** tout nouveau bail |
| Final non accepté (réseau, 5xx) | outbox, état `finalizing` : bail maintenu par keepalive, **aucun nouveau bail** tant que l'outbox n'est pas vide |
| `control: stop` au keepalive | arbre du worker tué immédiatement (Job Object), journal purgé |
| Worker sans activité au-delà de `SOULBAH_STEP_TIMEOUT` + 60 s | arbre tué, `ERROR timeout` |
| Arrêt demandé (Ctrl+C / SIGTERM) | plus de bail, fichiers d'arrêt posés, workers interrompus sans final (8 s), arbres restants tués ; reprise au prochain démarrage |

## 3. Preuves et artefacts (LOT 9 côté agent)

`evidence.build_evidence(step_type, ok, detail, data)` lit les déclarations `evidence` du manifeste :
`returncode` → `exit_code` (high) ; `stdout`/`stderr` → `command_output` (borné, rédigé, sans blob) ; `path` →
`file_path` + `sha256` du fichier ; `content` (read_file) → **empreinte** du texte, jamais le texte ; `entries` →
nombre et échantillon ; `probe` / `frames` → `video_probe` / `video_stats` ; `image_b64` (capture) → **artefact**
`PUT /api/v2/artifacts/<sha256>` (le fichier PNG sur disque), preuve `{kind: screenshot, sha256, artifact_id}` —
l'empreinte seule si le téléversement échoue. Forme validée contre `shared/schemas/evidence.schema.json`.

## 4. Packaging

- `agent/Lancer_Runtime.bat` : lance `python -m runtime.supervisor` dans `agent\.venv`.
- `agent/scripts/install_autostart.ps1` : tâche planifiée « SoulbahRuntime » à l'ouverture de session de
  l'utilisateur (session interactive, `pythonw.exe`, 3 relances), `-Uninstall`, `-Console`.
- Variables : `SOULBAH_MAX_SLOTS` (6, 1–32), `SOULBAH_RUNTIME_DIR` (`%LOCALAPPDATA%\Soulbah\runtime`),
  `SOULBAH_RUNTIME_LEGACY`. Côté serveur : `SOULBAH_RUNTIME_MIN_VERSION`.

## 5. Critères de sortie (audit §13) et tests

| Critère | Test |
|---|---|
| Kill d'un worker → reprise sans rejouer d'étape non idempotente | `agent/tests/test_lot8_recovery.py::test_worker_killed_resumes_without_replaying_non_idempotent_step` : worker tué pendant l'étape 1 ; `move_file` (étape 0) envoyée `attempted` une seule fois, fichier déplacé une seule fois, `wait` rejouée, un bail, un résultat |
| (§9.9) étape non idempotente interrompue | `test_interrupted_non_idempotent_step_asks_before_replay` : QUESTION, rien de rejoué sans réponse, « oui » → une seule exécution |
| Kill du superviseur → 0 doublon | `test_supervisor_killed_then_restarted_no_duplicate` : superviseur réel tué (`kill`), le worker meurt avec lui (l'étape de 4 s ne se termine pas), redémarrage → réconciliation → un seul bail, un seul résultat, `move_file` jamais rejoué |
| Arbre bloqué tué en < 10 s | `test_lot8_runtime.py::test_blocked_tree_killed_under_10s` (enfant + petit-enfant dans le job) |
| Runtime de version incompatible refusé | serveur : `backend/node-api/test/integration/v2Runtime.pg.test.ts` (426 sans protocole, version < minimum, protocole 2) ; agent : `test_handshake_upgrade_required_exits_4` (sortie 4) |
| Serveur V1 → legacy | `test_handshake_404_switches_to_legacy` (404 et `SOULBAH_RUNTIME_LEGACY=1`) |
| Instance unique (§14) | `test_single_instance_guard_is_mutual` (runtime refuse si l'agent V1 tourne et inversement ; verrou périmé repris) |
| Preuves conformes, 0 base64 | `test_evidence_typed_and_schema_compliant`, `test_screenshot_becomes_artifact` ; serveur : `v2Gateway.pg.test.ts` |
| Journal | `test_journal_wal_actions_checkpoints_outbox` |

## 6. Limites

- La vérification fine des post-conditions (DSL de critères) reste au LOT 10 : une étape réussie est `verified`
  sur la foi du skill et de ses preuves typées.
- Les boucles LLM de rôle dans les workers (desktop_operator, codeur…) et le relais modèles par P1 sont aux
  LOTS 11–12 ; le worker exécute aujourd'hui les étapes du catalogue fournies par le plan.
- Le démarrage automatique repose sur le Planificateur de tâches Windows (pas de service : le runtime a besoin
  du bureau de l'utilisateur).
