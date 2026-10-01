# LOT 9 — Tool Gateway et preuves

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §9.8 (preuves, niveaux de confiance, artefacts sha256,
« plus aucun base64 en base »), §9.4 (RUNNING → WAITING pour une approbation L2/L3), §13 ligne « 9. Tool Gateway
et preuves » (critères : preuve conforme au schéma pour chaque outil ; 0 base64 en base ; un appel L2 sans grant
passe en WAITING, puis reprend une seule fois).

## 1. Contrat de preuve

`shared/schemas/evidence.schema.json` : `{kind, confidence, description?, value?, artifact_id?, sha256?,
step_index?, at?}` et rien d'autre. Types : ceux du catalogue d'outils (`exit_code`, `command_output`,
`file_path`, `file_content`, `dir_listing`, `device_list`, `process`, `screenshot`, `self_report`,
`video_probe`, `video_stats`, `window_title`) plus `http_status`, `sha256`, `test_report`, `ui_state`.
Confiances `high | medium | low | none` (§9.8). Une capture ou une vidéo référence un artefact (`artifact_id`
ou `sha256`), jamais son contenu.

| Côté | Fichier | Rôle |
|---|---|---|
| node-api | `src/v2/evidence.ts` | validation (même liste que le schéma, test de cohérence), détection de blob base64 / data URI, meilleure confiance, règle « L2+ exige ≥ medium » |
| node-api | `src/v2/routes/artifacts.ts` | `PUT /api/v2/artifacts/:sha256` (clé agent, corps binaire, empreinte vérifiée, écriture atomique sous `MEDIA_DIR/artifacts/<user>/<sha>`, idempotent) ; `GET /api/v2/artifacts/:id|:sha` (JWT ou clé agent) ; liste |
| node-api | `src/v2/routes/runtime.ts` | actions, messages EVIDENCE et résultats : preuves validées, tout blob → 400 |
| node-api | `src/v2/routes/approvals.ts` | `v2_task_id` : la tâche RUNNING passe WAITING pendant l'approbation, reprend UNE fois (CAS) à l'approbation, BLOCKED au refus |
| agent | `runtime/evidence.py` | preuves typées d'après les déclarations `evidence` des manifestes ; captures téléversées comme artefacts ; contenu lu jamais transmis (empreinte) ; fichiers produits → sha256 |
| agent | `runtime/rtclient.py` | `put_artifact`, `request_approval` → `v2_task_id` |

## 2. Critères de sortie et preuves

| Critère | Test |
|---|---|
| Preuve conforme au schéma pour chaque outil | `backend/node-api/test/v2Evidence.test.ts` (schéma ↔ validateur) ; `agent/tests/test_lot8_runtime.py::test_evidence_typed_and_schema_compliant`, `test_screenshot_becomes_artifact` (forme vérifiée contre le schéma) |
| 0 base64 en base | `backend/node-api/test/integration/v2Gateway.pg.test.ts` : preuves, paramètres, messages EVIDENCE et résultats contenant un blob → 400, aucune ligne d'`actions`, `messages`, `tasks`, `audit_logs` ne le contient |
| Appel L2 sans grant → WAITING → reprise unique | `v2Gateway.pg.test.ts` : demande L2 avec `v2_task_id` → WAITING (keepalive `continue`) ; approbation → RUNNING, une seule transition WAITING → RUNNING auditée, rejeu de l'approbation → 409 ; refus → BLOCKED (keepalive `stop`) |
| Artefacts | `v2Gateway.pg.test.ts` : PUT idempotent (201 puis 200, même id), empreinte fausse → 400, JSON → 415, GET par id et par sha (JWT et clé agent), 401 sans authentification |

## 3. Limites

- La vérification des post-conditions par critères (DSL) est le LOT 10 ; ici les preuves sont collectées et
  validées dans leur forme.
- Les nouveaux outils (navigateur Playwright, `sandbox_exec`, VS Code, worktrees git) sont au LOT 12.
