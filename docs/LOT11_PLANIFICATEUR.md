# LOT 11 — Planificateur et orchestrateur

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §9.3 (Orchestrator, Planner : gabarits + proposition
LLM → `validateDag` → approbation ; nœud *observe* avant toute tâche écran), §11 (`shared/roles`), §13 ligne « 11.
Planner et orchestrateur » (critères : tests golden — cycles, rôles inconnus, niveaux trop élevés, chemins hors
workspace et critères manquants refusés ; modules de formation exécutés en parallèle, horodatages qui se
chevauchent).

## 1. Chaîne de planification

```
objectif ──► gabarit (desktop_goal | formation | demo_video)           ──┐
        └──► python-ia POST /v2/planner/propose (le modèle PROPOSE)     ──┤
                                                                          ▼
                     validateDag (rôles, outils, niveaux, chemins, critères, observer avant d'agir)
                       │ refus → 422 { errors[] } : rien n'est posé
                       ▼
                     setPlan → session AWAITING_APPROVAL → approbation de l'utilisateur → RUNNING
                       │                                         (+ grant L1 de session, LOT 7)
                       ▼
          scheduler : runtimes (rôles « runtime ») · P1 (qa_reviewer, content_writer)
```

| Élément | Fichier |
|---|---|
| Rôles versionnés (source) | `backend/node-api/src/v2/planner/roles.ts` → publié dans `shared/roles/roles.json` (test de non-dérive) |
| Validation métier | `src/v2/planner/validateDag.ts` |
| Gabarits | `src/v2/planner/templates.ts` |
| Proposition par modèle, pose du plan | `src/v2/planner/planner.ts` ; python-ia `app/v2/planner.py` |
| Rédaction par P1 (parallèle) | `src/v2/planner/contentRunner.ts` |
| Ponts V1 → V2 | `src/v2/planner/bridge.ts` (`/api/agent/goal`, `/api/formations/:id/demos`) |

## 2. Rôles (`shared/roles/roles.json`, v1.0.0)

| Rôle | Exécuté par | Plafond | Outils |
|---|---|---|---|
| `desktop_operator` | runtime | L2 | bureau (capture, souris, clavier, fenêtres, applications), lecture de fichiers, enregistrement |
| `coder` | runtime | L2 | `run_command`, fichiers (lecture, écriture, déplacement, dossiers), `wait` |
| `researcher` | runtime | L1 | lecture de fichiers, capture, `wait` |
| `video_editor` | runtime | L2 | enregistrement, montage, fichiers |
| `phone_operator` | runtime | L2 | téléphone Android |
| `qa_reviewer` | **P1** | L0 | aucun (relecture, LOT 10) |
| `content_writer` | **P1** | L0 | aucun (rédaction via python-ia) |

## 3. validateDag — règles (toutes les violations sont listées)

1. Forme et absence de cycle (`sessions/dag.ts`).
2. Rôle connu ; un rôle exécuté par P1 n'a pas d'étapes.
3. Chaque étape : outil du catalogue, **autorisé pour le rôle**, paramètres valides (`validateSteps`).
4. Niveaux : niveau du nœud ≥ niveau de chacun de ses outils, ≤ plafond du rôle, ≤ plafond de la mission.
5. Chemins : absolus, dans les dossiers autorisés (PC de l'utilisateur), hors deny-list (`.env`, `.git`, clés…).
6. Critères valides (DSL du LOT 10) ; un nœud **à effet** (L2+, ou outil à confirmation) exige au moins un critère
   **requis**.
7. **Observer avant d'agir** : un nœud qui pilote le bureau commence par une capture ou dépend (dépendance dure,
   même indirecte) d'un nœud qui en fait une.
8. Ressource exclusive `desktop.input:<utilisateur>` ajoutée aux nœuds qui pilotent le bureau : un seul agent bureau
   à la fois (§9.6).

Tout plan posé passe par validateDag : `POST /api/v2/sessions` (avec `plan`), `POST /sessions/:id/plan`,
`POST /sessions/:id/propose`, les ponts.

## 4. Gabarits

| Gabarit | Paramètres | Plan |
|---|---|---|
| `desktop_goal` | `goal`, `steps` | [observe (capture)] → act (rôle déduit des outils, niveau minimal couvrant, critères déduits : `file_exists`, `command_succeeds`, `video_valid`, sinon grille `llm_rubric` sur l'objectif) |
| `formation` | `topic`, `modules[]`, `program_title?` | N modules `content_writer` **sans dépendance entre eux** → `assemble` (dépend de tous) |
| `demo_video` | `title`, `output_dir`, `steps` | observe → record (`start_recording_bg` … actions … `stop_recording_bg`, critère `file_exists`) → montage (`edit_video`, critère `video_valid`) |

## 5. API

- `POST /api/v2/sessions/:id/propose` `{template, params}` ou `{goal?, context?}` → 200 `{session, tasks, source,
  understanding?}` ; 422 `{errors, plan, source}` si validateDag refuse ; 422 `{reason}` si le modèle juge l'objectif
  irréalisable.
- python-ia `POST /v2/planner/propose` `{goal, roles, allowed_dirs, max_security_level, context?}` → `{plan,
  understanding, feasible, reason, usage}` (forme nettoyée seulement ; jamais faisable sans nœud).
- `/api/agent/goal` avec `SOULBAH_V2_GOAL_BRIDGE=1` : planificateur V1 (dossiers du PC ciblé) → gabarit
  `desktop_goal` → mission V2 en attente d'approbation (`{v2: true, session_id, status, tasks}`) ; aucune tâche V1.
  Sans la variable : comportement V1 inchangé.
- `/api/formations/:id/demos` `{demo, title?, output_dir?, agent_key_id?}` → 201 mission `demo_video` (remplace le 501
  du LOT 1 ; jamais de tâche sans étapes).

## 6. Rédaction par P1 en parallèle

`runContentTasks` (après chaque tick) réserve les tâches `content_writer` prêtes (READY → RUNNING, bail
`p1:content_writer` de 15 min, SKIP LOCKED), génère **toutes en même temps** hors transaction, puis dépose
`TASK_RESULT` (→ COMPLETED) ou `ERROR` (→ RETRYING) seulement si la tâche est toujours la sienne. Un contenu de
plus de 32 Ko est stocké comme artefact JSON (sha256, `soulbah.artifacts`) et seul sa référence va dans le résultat.
Si node meurt pendant la génération, le bail expire et la rédaction (idempotente) est relancée.

## 7. Critères de sortie (audit §13) et preuves

| Critère | Preuve |
|---|---|
| Tests golden : cycles, rôles inconnus, niveaux trop élevés, chemins hors workspace, critères manquants refusés | `backend/node-api/test/fixtures/plans/golden.json` (18 cas, dont deny-list, outil interdit pour le rôle, observation manquante, dépendance douce, rôle P1 avec étapes, violations multiples) exécutés par `test/v2Planner.test.ts` |
| Modules de formation exécutés en parallèle (horodatages qui se chevauchent) | `test/integration/v2Planner.pg.test.ts` : 3 modules en vol simultanément (`maxInFlight = 3`), `max(started_at) < min(finished_at)`, puis assemblage et session COMPLETED |
| Plans proposés par un modèle validés | `v2Planner.pg.test.ts` : plan sans observation ni critère → 422 et aucune tâche ; plan conforme → AWAITING_APPROVAL ; infaisable → 422 ; python-ia : `tests/test_lot11_planner.py` |
| Pont `/api/agent/goal`, `/demos` via gabarit | `v2Planner.pg.test.ts` (mission V2, aucune tâche V1, dossiers du PC ciblé ; démo observer → filmer → monter avec ressource bureau) |

Les plans des tests des lots 7 à 10 ont été mis en conformité (dossiers autorisés déclarés, observation avant
d'agir, critères des nœuds à effet, outils permis par rôle) : la validation s'applique désormais partout.

## 8. Limites

- Les boucles LLM des rôles dans les workers (desktop_operator qui observe → décide → agit, codeur en worktree)
  sont au LOT 12 ; aujourd'hui un nœud runtime exécute les étapes du catalogue fournies par le plan.
- Le patch de plan (`TASK_REQUEST` → `plan_version + 1` pendant l'exécution) reste stocké sans effet.
- Le budget de mission n'est pas encore estimé à la planification.
