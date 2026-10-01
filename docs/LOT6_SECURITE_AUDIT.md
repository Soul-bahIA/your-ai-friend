# LOT 6 — Sécurité et audit

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §7 (S1, S3, S7, S8, S15, S20, S21, S22), §9.1
(bornes du risque « LLM à côté d'un contrôle d'entrées » : approbations HMAC liées au `payload_sha256`,
audit et rédaction dans P1), §9.10 (niveaux L0–L3), §13 ligne « 6. Sécurité et audit » (critères :
politique testée pour chaque outil du catalogue ; `verifyChain` détecte une altération ; le secret canari
est absent des lignes, des logs et des prompts). Notes détaillées des deux chantiers délégués :
`docs/LOT6_AGENT_NOTES.md` (agent local) et `docs/LOT6_FRONTEND_NOTES.md` (boîte d'approbations).

## 1. Vue d'ensemble

```
runtime / agent (P3)                 node-api (P1)                                  utilisateur (web)
──────────────────                  ─────────────────────────────────────────────  ───────────────────
étape L2/L3 à exécuter ─request──▶  POST /api/v2/approvals/request                 GET /api/v2/approvals
  (payload complet)                   politique L0–L3 (catalogue + deny-list)        ApprovalsInbox :
                                       → 403 si interdit, sinon permissions(pending)   payload COMPLET,
                                       + audit permission.requested                     niveau, échéance
poll GET /approvals/:id ◀──────────  statut ; jeton HMAC si approuvée      ◀─approve─ POST /:id/approve
                                       (recalculé, jamais stocké : token_hash)         { payload_sha256 AFFICHÉ }
                                       + audit permission.approved (même transaction)
POST /approvals/verify {token,payload} ▶ signature · expiration · empreinte du payload
                                       RÉELLEMENT exécuté · statut en base → ok / raison
exécution (uniquement si ok)         soulbah.audit_logs (ajout seul, chaîné)        GET /api/v2/audit/verify
```

Le runtime ne détient **ni le secret HMAC, ni l'audit, ni le pouvoir de s'auto-approuver** (§9.1) : il
présente un jeton que seul P1 sait émettre et vérifier, lié à l'empreinte exacte de ce que l'utilisateur
a vu et de ce qui sera exécuté.

## 2. node-api (plan de contrôle)

| Élément | Fichier |
|---|---|
| Politique L0–L3 (pure) | `backend/node-api/src/v2/security/policy.ts` |
| Jetons HMAC, JSON canonique, empreinte | `backend/node-api/src/v2/security/approvals.ts` |
| Rédaction des secrets | `backend/node-api/src/v2/security/redactSecrets.ts` |
| Audit (écriture, vérification, liste) | `backend/node-api/src/v2/audit.ts` |
| Routes approbations + audit | `backend/node-api/src/v2/routes/approvals.ts` |
| Tests | `test/v2Security.test.ts`, `test/v2ApprovalsRoutes.test.ts`, `test/integration/approvals.pg.test.ts` |

**Politique** (`decide`) : dérivée du catalogue d'outils (LOT 2) et de la deny-list par nom (miroir de
`agent/skills/safety.py` : `.git`, `.ssh`/`.gnupg`, `.env*`, clés privées, variantes Windows `::$DATA`,
espaces/points finaux). L0 → `allow` ; L1 → `allow` si la session est approuvée, sinon `session_grant` ;
L2 → `approve_each` si le catalogue exige la confirmation (`requires_confirmation`), sinon `allow` si un
grant de session couvre l'outil, sinon `approve_each` ; L3 → `approve_each`, payload complet, jamais en
lot. Plafonds : `user_settings.max_security_level` et `sessions.max_security_level` (minimum des deux) ;
au-dessus → `deny`. Outil inconnu → `deny`. Testée pour **chacun des 30 outils** et leurs alias
(`test/v2Security.test.ts`, bloc « politique L0–L3 : chaque outil du catalogue »).

**Jetons** : `sbap_<base64url(corps canonique)>.<HMAC-SHA256 hex>` ; corps `{v:1, id, sha, exp, lvl}`.
Secret `SOULBAH_APPROVAL_SECRET` (≥ 32 caractères, **obligatoire hors dev/test**, garde-fou de
démarrage) ; en dev sans secret : secret éphémère par processus avec avertissement. Seul
`sha256(jeton)` est stocké (`permissions.token_hash`) : `GET /approvals/:id` recalcule le jeton et
le renvoie seulement si le hash correspond (sinon « revoked »). `verify` contrôle signature, expiration,
empreinte du payload exécuté, statut et hash en base. JSON canonique = clés triées, compact, UTF-8,
identique à `json.dumps(sort_keys=True, separators=(",", ":"), ensure_ascii=False)` côté agent.

**Rédaction** (`redactSecrets`, `redactText`) : motifs (clés d'API `sk-`, `sbk_`, `sbap_`, AWS, GitHub,
Slack, JWT, `Bearer`, `clé=valeur` pour password/secret/token/api_key, blocs `PRIVATE KEY`), clés de
champs sensibles (valeur entière remplacée), et **valeurs déclarées** `SOULBAH_REDACT_VALUES` (canari).
Appliquée : évènements `agent_events` (`data` et `message`), résultats et `error_message` d'`agent_tasks`,
prompt de l'évaluateur (après le masquage LOT 1), données d'audit, payload présenté des approbations,
journaux (`redactingLogger` + `redact` pino sur les en-têtes d'authentification). Une empreinte sha256
(64 hex) n'est jamais rédigée : les hashs restent lisibles.

**Audit** : `audit()` écrit dans `soulbah.audit_logs` **dans la transaction** de la décision
(`permission.requested|approved|denied|refused`) ; `verifyChain()` appelle
`soulbah.verify_audit_chain()` (LOT 4) ; `GET /api/v2/audit/verify`, `GET /api/v2/audit`.

## 3. Agent local (P3)

Voir `docs/LOT6_AGENT_NOTES.md` : rédaction des secrets dans les journaux, évènements et rapports
(`agent/redaction.py`), stockage DPAPI de la clé agent (`agent/secrets.py`, `--store-key`),
approbations distantes (`agent/approvals.py`, `SOULBAH_APPROVAL_MODE=console|remote|both`), tests de
politique par outil et test canari côté agent.

## 4. Frontend

Voir `docs/LOT6_FRONTEND_NOTES.md` : `ApprovalsInbox` (page Sécurité, compteur dans la barre
latérale) affiche le **payload complet** (S7), le niveau, le compte à rebours ; approuve en renvoyant
l'empreinte affichée ; L3 exige la saisie de « AUTORISER » ; encart « Journal d'audit » avec
vérification de la chaîne. 30 tests ajoutés (157 → 187).

## 5. Critères de sortie (audit §13) et preuves

| Critère | Preuve |
|---|---|
| Politique testée pour chaque outil du catalogue | `test/v2Security.test.ts` : un test par outil (niveau, confirmation, grants, plafonds, alias, chemin interdit) ; côté agent : `agent/tests/test_lot6_policy.py` |
| `verifyChain` détecte une altération | `test/integration/approvals.pg.test.ts` : altération hors triggers → `ok=false`, `broken_at` = ligne modifiée ; `scripts/ci/schema_checks.sql` (LOT 4) ; route `GET /api/v2/audit/verify` |
| Le canari est absent des lignes, des logs et des prompts | lignes : `approvals.pg.test.ts` (payload présenté, audit, `agent_events.message/data`, `agent_tasks.result`) ; logs : `redactingLogger` + pino `redact` (test unitaire) ; prompts : `test/evaluation.test.ts` (résultat et étapes rédigés avant `evaluateGoal`) ; côté agent : `test_lot6_canary.py` |
| Approbations HMAC liées au payload | `v2Security.test.ts` (signature, expiration, `payload_mismatch`, forme) ; `approvals.pg.test.ts` (flux complet, empreinte différente → 409, jeton altéré → `signature`) |
| DPAPI | `agent/secrets.py` + tests Windows (`LOT6_AGENT_NOTES.md`) |
| ApprovalsInbox | `frontend/src/components/ApprovalsInbox.tsx` + tests |

## 6. Variables

| Variable | Service | Rôle |
|---|---|---|
| `SOULBAH_APPROVAL_SECRET` | node-api | secret HMAC (≥ 32 car.), obligatoire hors dev/test |
| `SOULBAH_REDACT_VALUES` | node-api | valeurs à rédiger partout (`;`), p. ex. canari |
| `SOULBAH_APPROVAL_MODE` | agent | `console` (défaut), `remote`, `both` |
| `SOULBAH_REDACT_VALUES` | agent | idem côté agent |
| `SOULBAH_SECRETS_DIR` | agent | dossier du fichier DPAPI (défaut `%LOCALAPPDATA%\Soulbah`) |

## 7. Limites et suites

- Les grants de session (L1/L2) existent dans la politique et le schéma (`permissions.kind='grant'`)
  mais aucune route ne les crée encore : c'est le LOT 7 (sessions) qui les posera à l'approbation du plan.
- La révocation d'un grant/jeton n'a pas de route dédiée ; tout changement de `token_hash` ou de statut
  rend le jeton inutilisable (`verify` → `revoked`).
- Le budget quotidien durable par utilisateur (lecture de `tool_calls`) est rattaché au LOT 7/10.
