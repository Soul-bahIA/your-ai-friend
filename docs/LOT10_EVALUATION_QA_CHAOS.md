# LOT 10 — Évaluation, QA, chaos

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §9.8 (DSL de critères, niveaux de confiance, règles de
complétion), §9.9 (VALIDATING durable, reprise), §13 ligne « 10. Évaluation, QA, chaos » (critères : un run
simulé ou vide n'est jamais COMPLETED ; node tué en VALIDATING → une seule évaluation ; PG coupé → 0 doublon).

## 1. DSL de critères (`backend/node-api/src/v2/evaluation/criteria.ts`)

Les critères d'acceptation d'un nœud du plan (`acceptance_criteria`) sont évalués **sur les preuves** des
actions de la tentative (`soulbah.actions` : outil, paramètres masqués, preuves typées du LOT 9) — P1 ne voit
jamais le PC. Chaque critère a `required` (défaut `true`) et `min_confidence` (défaut `medium`, `low` pour
`llm_rubric`).

| Type | Paramètres | Passe si une étape exécutée prouve… |
|---|---|---|
| `file_exists` | `path` | `file_path` = chemin (normalisé : casse, `/` et `\`) |
| `file_contains` | `{path, sha256}` ou `{text}` | sha256 du fichier produit à ce chemin, ou texte vu dans une sortie |
| `command_succeeds` | `command?` | `run_command` (de cette commande) avec `exit_code` 0 |
| `tests_pass` | `command?` | `test_report` réussi, ou commande de tests (pytest, vitest, npm test…) avec code 0 |
| `http_status` | `status`, `url?` | preuve `http_status` |
| `git_branch_contains` | `branch`, `text` | sortie d'une commande git réussie mentionnant la branche et le texte |
| `video_valid` | `path?` | `video_probe` sans erreur, durée > 0 |
| `ui_element_state` | `name?`, `state?`, `window_title?` | preuve `ui_state` ou `window_title` |
| `artifact_hash` | `sha256` | une preuve porte exactement cette empreinte |
| `llm_rubric` | `rubric` | jugement d'un modèle (python-ia `/v2/models/complete`, rôle évaluateur) — confiance **low** |

**Verdict** (`assess`) : simulé → `not_evaluable` ; plan avec étapes mais aucune étape exécutée → `failure` ;
échec annoncé par le runtime → `failure` ; tâche L2/L3 sans preuve ≥ medium → `failure` ; tous les critères requis
passent → `success` (`partial` si un critère facultatif échoue).

## 2. Moteur d'évaluation (`engine.ts`) — VALIDATING durable

- `evaluateAndApply` s'exécute dans la transaction qui tient la ligne de la tâche : une ligne
  `soulbah.evaluations` (UNIQUE `task_id, attempt`) puis la transition, auditées ensemble.
- Issue : `success`/`partial` → COMPLETED ; `not_evaluable` → FAILED ; `failure` → **RETRYING seulement si toutes
  les étapes exécutées sont idempotentes** (rejouer ne double aucun effet) et qu'il reste des reprises, sinon FAILED
  (`failed_needs_human` : un humain relance avec `POST /api/v2/tasks/:id/retry`).
- Le résultat d'un runtime (`TASK_RESULT`) est évalué immédiatement quand seules des règles s'appliquent ; avec un
  `llm_rubric`, la tâche **reste en VALIDATING** et `runEvaluations` (après chaque tick du scheduler) la reprend :
  `FOR UPDATE SKIP LOCKED` (jamais deux évaluateurs), un jugement en échec annule la transaction (la tâche reste
  en VALIDATING), sans juge disponible la tâche attend — conclue en échec au-delà d'une heure.
- `GET /api/v2/tasks/:id` renvoie désormais les évaluations.

Correction au passage : un résultat qui se déclare simulé (`result.simulated: true`) ne peut plus être « blanchi »
par un drapeau de message à `false` (`bus/messages.ts`).

## 3. Relecteur QA exécuté par P1 (`reviewer.ts`)

Les tâches `qa_reviewer` (créées par `REVIEW_REQUEST`, dépendance dure vers la tâche relue) ne sont **jamais
confiées à un runtime** (`lease` les exclut). `runReviews` les exécute : READY → RUNNING (bail court `p1:qa_reviewer`),
lecture de la tâche relue et de sa dernière évaluation (approuvée si COMPLETED avec `success`/`partial`), grille
facultative jugée par un modèle, puis `REVIEW_RESULT {review_of, approved, evaluation_verdict, reasons}` et
`TASK_RESULT` → COMPLETED, dans une seule transaction.

## 4. Chaos

| Panne | Comportement | Preuve |
|---|---|---|
| node tué pendant une évaluation | transaction annulée, tâche toujours en VALIDATING, 0 ligne d'évaluation ; reprise → une seule évaluation | `v2Evaluation.pg.test.ts` : juge qui lève, puis 6 évaluateurs concurrents → 1 évaluation, 1 appel au juge, 1 transition auditée |
| Base (ou node) coupée | le reaper ne récupère **aucun bail** avant une durée de bail complète après le retour de la base ou le démarrage de node (`reapNotBefore`, `server.ts`) : les runtimes ont le temps de prolonger leurs baux | `v2Evaluation.pg.test.ts` (bail expiré non récupéré pendant la grâce, keepalive le prolonge ; après la grâce, une seule récupération, résultat tardif refusé 409) |
| Plan de contrôle injoignable côté runtime | le worker termine, toutes ses écritures partent dans l'outbox, état `finalizing`, **aucun nouveau bail** ; au retour : outbox rejouée **dans l'ordre par tâche**, un seul résultat, puis la tâche suivante | `agent/tests/test_lot10_chaos.py` |

Défaut trouvé par ce test et corrigé : l'outbox pouvait envoyer un résultat (backoff court) avant des actions
plus anciennes de la même tâche (backoff long) ; ces actions étaient ensuite refusées. Une écriture n'est
désormais due que si aucune écriture plus ancienne de la même tâche n'attend (`journal.outbox_claim_due`).

## 5. Critères de sortie (audit §13)

| Critère | Preuve |
|---|---|
| Un run simulé ou vide n'est jamais COMPLETED | `v2Evaluation.pg.test.ts` « un run simulé ou vide n'est JAMAIS COMPLETED » (tâche simulée, résultat se déclarant simulé, plan non joué) ; `v2Evaluation.test.ts` (`assess`) |
| node tué en VALIDATING → une seule évaluation | `v2Evaluation.pg.test.ts` « VALIDATING durable… » |
| PG coupé → 0 doublon | `v2Evaluation.pg.test.ts` « chaos… » (côté P1) ; `agent/tests/test_lot10_chaos.py` (côté runtime) |
| DSL de critères | `v2Evaluation.test.ts` : chaque type, confiance minimale, critères facultatifs, règle L2 |
| qa_reviewer | `v2Scheduler.pg.test.ts` (bus) : jamais attribué à un runtime, exécuté par P1, `REVIEW_RESULT` approuvé |

Les fichiers d'intégration tournent désormais l'un après l'autre (`npm run test:pg` : `--no-file-parallelism`),
les tests de charge ont un délai explicite (la garantie est « 0 double bail », pas une durée).
