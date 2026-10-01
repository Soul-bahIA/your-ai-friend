# SoulBah IA : LOT 0, état réel, écarts et architecture V2

> **Base auditée** : `main` @ `d542f65`, arbre propre (revérifié le 2026-10-01 : `git status --porcelain` vide, `main...origin/main [ahead 2]`). **Sources** : 8 cartes d'audit vérifiées (agent-core, agent-skills, node-orchestration, node-features, python-ia, database, frontend, infra-security). **Travaux « en cours »** : les changements annoncés sur `backend/node-api` et `src/` sont déjà dans `d542f65`. Aucun fichier à moitié édité n'a été vu, donc rien n'est classé « cassé » pour cause de chantier inachevé.

> **Note (après fusion de `restructure`, commit a24b7bd)** : l'application web est désormais dans `frontend/` (les références `src/…` de ce rapport correspondent à `frontend/src/…`) et l'ancienne console de test `frontend/` est devenue `backend/console/`. Les numéros de ligne sont ceux de `d542f65`.

## 0. Résumé exécutif

- **État réel** : un seul agent sur un seul PC. Le LLM externe (python-ia, Anthropic en pratique) transforme un objectif en liste plate d'étapes. node-api met cette liste en file (`agent_tasks`), puis l'agent local l'exécute dans l'ordre avec confirmation console.
- **Santé** : 297 tests verts (agent 156, python-ia 55, node-api 38, front 48), `tsc` et `eslint` propres. Supabase est en pause, donc aucun parcours de bout en bout n'a été vérifié.
- **Matrice C01–C38** : aucune capacité ne fonctionne au niveau V2, 28 sont incomplètes, 5 défectueuses (C18, C26, C27, C31, C37) et 5 absentes (C02, C05, C07, C13, C25).
- **Écart principal avec la V2** : Soulbah n'a pas de cerveau propre (ni DAG, ni scheduler, ni pool, ni machine à états, ni preuves). « Réussi » est un verdict du LLM, accordé même à un dry-run ou à un plan vide, puis mémorisé comme « solution validée ».
- **Urgences** :
  - le code n'est pas sur `origin` ;
  - aucune sauvegarde n'existe ;
  - la whitelist de l'agent est la racine du dépôt (secrets lisibles, gate réinscriptible) ;
  - le garde `.git` est contournable ;
  - node-api se connecte en rôle `postgres`, ce qui contourne la RLS.
- **Recommandation** : architecture à trois plans (« Split-Plane », §9).
  - node-api devient le plan de contrôle et le seul écrivain d'un schéma `soulbah` additif.
  - `agent/` devient un runtime à N sous-processus clôturés par bail.
  - python-ia devient le seul routeur de modèles.
  - Une tâche n'est terminée que sur preuves.

  Livraison en 15 lots, sans migration destructive, après deux préalables : pousser le dépôt et sauvegarder la base.

## 1. Architecture actuelle

### 1.1 Processus réels (ce PC Windows 10 + Supabase)

```
 Navigateur : app React/Vite (src/)                    frontend/ : console de test (401 permanent depuis d542f65)
   │ REST + JWT Supabase (/api/*)       ▲ Realtime : agent_tasks, agent_events, formations, system_logs
   │ + PostgREST direct : knowledge_base, chat_*, formations, applications, system_logs, DELETE agent_tasks
   ▼                                    │
 ┌──────────────────────────────────────┴───────────────┐   pg (rôle postgres, TLS sans CA)
 │ node-api  Fastify 5 / tsx  :3000  (HOST=0.0.0.0 .env) ├───────────────────────────────► Supabase Postgres
 │ file agent_tasks · boucle d'objectif · mémoire · KB ·  │                                 + Auth + Realtime
 │ recherche · formations · chat SSE · clés agent         │                                 + pgvector   [EN PAUSE]
 └──────┬────────────────────────────────▲────────────────┘
        │ HTTP (x-ia-token absent → ouvert)│ HTTP x-agent-key : announce · poll (≤5 tâches) · claim · event · update · control
        ▼                                  │
 ┌─────────────────────────────┐   ┌──────┴────────────────────────────────────────────────┐
 │ python-ia FastAPI :8000      │   │ agent/  Python 3.11 global (pas de venv), 1 worker      │
 │ prompts plan/éval/routage,   │   │ executor + PermissionGate (confirmation console 120 s)  │
 │ providers/ (Anthropic seul   │   │ 17 skills : pyautogui · mss · cv2 · moviepy · adb ·     │
 │ en pratique), vidéo, PDF     │   │ Resolve ; outbox .pending_updates.json ; logs/agent.log │
 └──────┬──────────────────────┘   └─────────────────────────────────────────────────────────┘
        │ /infer uniquement
        ▼
  rust-compute (démo axum, jamais compilé ici : ni Docker ni cargo)
```

### 1.2 Flux d'une tâche agent de bout en bout

1. **Objectif.** `AgentTasksPanel` appelle `POST /api/agent/goal` (JWT). `planAndQueueGoal` (agentGoal.ts:172-235) assemble deux éléments :
   - la mémoire, via `getMemoryContext` (ILIKE sur ≤ 6 mots, entrées rejetées incluses) ;
   - l'**union** des `allowed_dirs` de toutes les clés agent de l'utilisateur.
2. **Plan.** python-ia `/agent/plan` (reasoning.py:138-149) appelle le LLM en texte seul, sans voir l'écran. Il renvoie ≤ 8 étapes, avec des coordonnées devinées. Côté node, le plan passe trois filtres :
   - `compactStep`, qui perd notamment le `path` de `start/stop_recording_bg` ;
   - `clampAndValidatePlanSteps` (forme, bornes) ;
   - `findInvalidStep` (`REQUIRED_FIELDS`, sans `cwd` pour run_command).

   Vient ensuite l'`INSERT agent_tasks` (`pending`, priorité 3, `goal_meta{attempt:1,max_attempts:3}`). L'UI n'affiche que le nombre d'étapes.
3. **Poll.** `GET /api/agent-tasks/poll` remet d'abord en file les tâches `in_progress` **de cet utilisateur** muettes depuis 180 s (3 fois au plus, puis `failed`). Il renvoie ensuite ≤ 5 tâches `pending` triées par priorité puis par date.
4. **Claim.** L'agent envoie `POST /update in_progress` avec `attempt = requeue_count`. L'UPDATE est gardé par `status='pending' AND requeue_count=attempt` (agentTaskSql.ts:53-66) et répond 200 ou 409.
5. **Exécution** (executor.py:98-250). Pour chaque étape, l'agent lit `control`, puis appelle `gate.authorize` (permissions.py:151-213), qui applique dans l'ordre :
   1. whitelist des chemins ;
   2. `skill.validate` ;
   3. dry-run ;
   4. shell toujours confirmé ;
   5. **passage non sensible** : screenshot, wait et phone_list_devices ne sont jamais confirmés (origine de S17) ;
   6. verrou input (souris, clavier, fenêtres, apps ; pas le téléphone) ;
   7. mode auto ;
   8. confirmation console (120 s, refus par défaut).

   La skill tourne dans un thread avec timeout. Les événements `step_*` et `screenshot` (base64) vont dans `agent_events`, puis vers Realtime et `AgentCockpit`. Un heartbeat part toutes les 30 s, et l'exécution s'arrête au premier échec.
6. **Final.** `POST /update completed|failed`, gardé par `attempt`. En cas d'erreur réseau, de 5xx ou de 401/403/408/425/429, le résultat passe par l'outbox `pending.py` (backoff 2–120 s, 10 min au maximum).
7. **Évaluation.** `maybeEvaluateGoalTask` (agentGoal.ts:268-345) est lancée sans être attendue. Elle envoie le rapport et les **3 premières** captures à `/agent/evaluate`, puis :
   - `success` : écrit une mémoire « solution » `validated` ;
   - `retry` : crée une nouvelle tâche, non liée à la première ;
   - sinon : écrit une mémoire « error ».

   Un stop utilisateur arrive ici avec le statut `failed`.

**Autres flux**
- **Formation** : FormationEngine séquentiel ; la progression est écrite dans `agent_events`.
- **Vidéo** : slides + TTS vers un MP4, appel synchrone ≤ 900 s.
- **Chat** : 50 entrées KB collées dans le prompt ; les tool calls sont exécutés automatiquement par le navigateur.
- **Recherche** : la KB d'abord, puis une synthèse LLM pure (aucune clé web).

## 2. Fichiers et composants importants

| Composant | Fichiers | Rôle |
|---|---|---|
| Boucle agent | agent/soulbah_agent.py, client.py, pending.py, config.py | poll, claim, heartbeat, backoff, outbox durable |
| Exécuteur, gate | agent/executor.py, permissions.py | étapes séquentielles, timeout, pause/stop ; whitelist, confirm/auto, verrou input |
| Skills (17 classes, 48 types) | agent/skills/*.py | entrées, fenêtres, apps, fichiers, commandes, capture, enregistrement, montage, Resolve, téléphone |
| File serveur | node-api routes/agentTasks.ts, lib/agentTaskSql.ts, lib/agentSteps.ts | remise en file, claim CAS, transitions gardées, événements, control, validation |
| Objectif, Chief Agent | routes/agentGoal.ts, orchestrator.ts, python-ia agents.py, reasoning.py | plan, filtres, évaluation, correction ; 15 étiquettes |
| Mémoire, KB, recherche | routes/agentMemory.ts, services/knowledge/*, services/research/* | récupération ILIKE ; KnowledgeStore versionné ; KB puis web |
| Génération, chat | routes/generate.ts, formationVideo.ts, chat.ts ; python-ia generation.py, video.py, pdf.py | formations, applications JSON, MP4, PDF, démos, SSE |
| Routeur de modèles | python-ia app/providers/*, llm.py | LLMProvider, 7 fournisseurs cloud + 1 local |
| Auth, serveur | auth.ts, services/agentKeys.ts, server.ts, db.ts, services/maintenance.ts | JWT (cache 60 s), clés hachées, rate limit, purge à 3 jours |
| Schéma | supabase/migrations (17), RESTAURATION_BASE.sql, backend/postgres/init.sql | 19 tables RLS, hardening idempotente |
| UI | src/pages/Automation.tsx, AgentTasksPanel.tsx, AgentCockpit.tsx, Sidebar.tsx, KnowledgeBase.tsx, lib/api.ts | objectif, tâches, live ; KB écrite en direct ; métriques factices |
| Démo Rust | backend/rust-compute, python-ia rust_client.py | `/infer` jouet ; aucun rôle en V2 (§9.2) |
| Infra | backend/docker-compose.yml, .github/workflows/ci.yml, scripts/backup_db.*, build_restore_sql.sh | compose, CI et sauvegardes jamais exécutés |

## 3. Capacités déjà fonctionnelles

### 3.1 Matrice des capacités (référence des sections 3 à 5)

Quand les audits divergent, la capacité est notée dans son ensemble (mention « Réconcilié »). Abréviations : INCOMPLET = EXISTE MAIS INCOMPLET ; DÉFECTUEUX = EXISTE MAIS DÉFECTUEUX.

| id | capacité | statut | preuve (fichier:ligne) | note |
|---|---|---|---|---|
| C01 | Orchestrateur / planification | INCOMPLET | orchestrator.ts:15-72 ; agentGoal.ts:172-235 ; reasoning.py:138-149 | Le LLM externe décide et produit une liste plate. Les `subtasks` sont seulement affichées ; l'UI n'envoie jamais `execute`. |
| C02 | Task graph / DAG | ABSENT | docs/SOULBAH_AI_ARCHITECTURE.md:107 ; executor.py:135-224 | Recherche négative dans tout le dépôt. Correctifs non liés à leur parent (agentGoal.ts:324). |
| C03 | File de tâches | INCOMPLET | agentTaskSql.ts:41-80 ; agentTasks.ts:34-71,120-124 ; pending.py | Claim CAS testé. 2 doubles exécutions reproduites. Pas de propriétaire de bail ni de RETRYING/BLOCKED. Remise en file seulement dans le poll du propriétaire. |
| C04 | Sessions / checkpoints | INCOMPLET | agentTasks.ts:34-71 ; pending.py:24 ; maintenance.ts:15-30 | La reprise redémarre à l'étape 0. Ni session_id ni checkpoint. |
| C05 | Pool parallèle | ABSENT | soulbah_agent.py:270-273 ; skills/base.py:16 | Réconcilié : node-orchestration note INCOMPLET (consommateurs concurrents via 409), 5 audits notent ABSENT. Ni pool ni max_parallel. |
| C06 | Rôles dynamiques | INCOMPLET | agents.py:14-30 ; orchestrator.ts:43-65 | 15 étiquettes statiques, dont 2 dispatchées. Aucune instance d'agent. |
| C07 | Messages inter-agents | ABSENT | recherche des 9 types négative ; agentTasks.ts:217-227 | agent_events n'est que de la télémétrie agent → UI. |
| C08 | Model router | INCOMPLET | router.py:21-105 ; openai_compat.py:26 ; chatProvider.ts:55-109 | Tout part vers Anthropic (fallback jamais déclenché). Vision=True par défaut, usage jeté, 2 registres. Front : ABSENT. |
| C09 | Souris / clavier | INCOMPLET | mouse.py:22-52 ; hotkey.py:17-44 ; type_text.py:87-114 | Aveugle. « Ctrl+S » envoie Ctrl+Shift+S ; une touche inconnue renvoie ok. |
| C10 | Capture + vision | INCOMPLET | screenshot.py:22-33 ; agentGoal.ts:136-148 ; reasoning.py:195-204 | Vision a posteriori sur les 3 premières captures. Ni OCR, ni UIA, ni localisation. |
| C11 | Boucle observer → vérifier | INCOMPLET | agentGoal.ts:268-345 | Au niveau de la tâche, jugée par un LLM, ≤ 3 tentatives. Rien par action. |
| C12 | Fenêtres / apps | INCOMPLET | open_app.py:130-247 ; window.py:26-58 | Popen sans argument ; aucune vérification. |
| C13 | Navigateur | ABSENT | recherche playwright/selenium/cdp négative | open_app lance un navigateur sans URL. |
| C14 | Terminal | INCOMPLET | run_command.py:31-63,257-343 | Allowlist stricte, code de sortie. Pas de sandbox ; le timeout ne tue pas l'arbre. |
| C15 | Fichiers | INCOMPLET | filesystem.py:30-87 ; move_file.py:11-44 | Ni delete, copy, hash ni écriture atomique. Troncature silencieuse. |
| C16 | VS Code | INCOMPLET | open_app.py:25-28,84-87 | Lancement seul ; le CLI `code` n'est pas utilisé. |
| C17 | Git | INCOMPLET | run_command.py:33-39,121-134 | Ni worktree ni verrou. `branch -D` et `init --separate-git-dir` acceptés. |
| C18 | Enregistrement écran | DÉFECTUEUX | agentGoal.ts:27-96 ; record_bg.py:114-141 | Réconcilié sur trois avis. agent-core note DÉFECTUEUX pour le chemin planifié et délègue la note de la skill à agent-skills, qui la note INCOMPLET (elle marche en tâche manuelle) ; frontend note ABSENT (pas d'UI). Retenu DÉFECTUEUX : le flux recommandé par le planner échoue toujours. |
| C19 | Montage / export | INCOMPLET | edit_video.py:53-92 ; resolve_montage.py:171-197 | edit_video produit une vidéo sans son. Resolve n'a jamais été exécuté. Aucune vérification de sortie. |
| C20 | Vidéo TTS / slides | INCOMPLET | video.py:134-285 ; formationVideo.ts:18-86 ; demoTasks.ts:42-55 | 2 MP4 réels produits. Sous-fonction /demos **défectueuse** (tâches sans étapes). Synchrone ≤ 900 s. |
| C21 | Sécurité / permissions | INCOMPLET | permissions.py:169-213 ; auth.ts:88-151 | Binaire, console seule. Pas de L0–L3 ; le téléphone échappe au verrou. |
| C22 | Secrets | INCOMPLET | agentKeys.ts:9-21 ; python-ia main.py:28-35 | .env en clair, token IA absent. Les textes tapés sont divulgués. |
| C23 | Sandbox / environnements | INCOMPLET | config.py:23-24,67 ; executor.py:184-185 ; AppPreview.tsx:341-347 | Fragments seulement, dont un dry-run **défectueux**. Aucune séparation dev/test/prod. Front : ABSENT. |
| C24 | Journal d'audit | INCOMPLET | logs.ts:4-17 ; migration 20260218031213:104 ; maintenance.ts:37-46 | Texte libre, falsifiable par le client, purgé à 3 jours. |
| C25 | Mémoire de mission | ABSENT | agentMemory.ts:51-59,113 | Réconcilié : agent-core et node-features notent INCOMPLET (goal_meta, historique de chat), 4 audits notent ABSENT. Rien à l'échelle d'une mission. |
| C26 | Mémoire long terme | DÉFECTUEUX | agentMemory.ts:13-47,63-77 ; agentGoal.ts:303-310 | Réconcilié : node-orchestration note DÉFECTUEUX ; node-features, python-ia et database notent INCOMPLET ; frontend note ABSENT (UI). Le dry-run est stocké « SOLUTION VALIDÉE » et les rejets sont réinjectés. |
| C27 | Base de connaissances | DÉFECTUEUX | supabaseStore.ts:125-217 ; KnowledgeBase.tsx:49-103 ; chatActions.ts:105-108 | Réconcilié : node-features et database notent INCOMPLET (le service est sain), frontend note DÉFECTUEUX. Retenu DÉFECTUEUX car l'écrivain principal, l'UI, contourne le service. |
| C28 | RAG | INCOMPLET | embeddings.ts:5,16 ; supabaseStore.ts:259-282 | Sémantique OU FTS, jamais les deux. Ni chunks, ni BM25, ni rerank. Front : ABSENT. |
| C29 | Agent de recherche | INCOMPLET | research/index.ts:32-96 ; research.py:13-91 | Synthèse LLM mise en cache comme connaissance ; ni dates ni URL vérifiées. Front : ABSENT. |
| C30 | QA / preuves | INCOMPLET | agentGoal.ts:296-301 ; reasoning.py:113-125 | Verdict LLM seul. Un dry-run ou un plan vide compte comme succès. |
| C31 | Auto-amélioration | DÉFECTUEUX | agentMemory.ts:24-32,156-207 | Réconcilié : node-orchestration et database notent DÉFECTUEUX, python-ia note INCOMPLET, frontend note ABSENT. Les propositions validées ne sont jamais injectées. |
| C32 | Bibliothèque de skills | INCOMPLET | skills/__init__.py:21-44 ; agentSteps.ts:6-34 ; reasoning.py:17-79 | 4 copies manuelles ; les champs ont dérivé. Aucun versionnage. Front : ABSENT. |
| C33 | Adaptateurs | INCOMPLET | resolve_montage.py:37-68 ; phone.py:34-60 | Réconcilié : agent-core note ABSENT. Adaptateurs écrits à la main, jamais validés sur matériel. |
| C34 | Dashboard | INCOMPLET | AgentCockpit.tsx:68-127 ; Sidebar.tsx:80-90 | Vue d'une seule tâche. CPU et RAM factices. |
| C35 | Métriques perf / coûts | INCOMPLET | executor.py:182-193 ; agentMemory.ts:155-185 | Seulement duration_s ; ni tokens ni coûts. Front : ABSENT. |
| C36 | UI mission | INCOMPLET | Automation.tsx ; AgentTasksPanel.tsx:105-128 | Pas d'objet mission ; le plan n'est jamais affiché. |
| C37 | Tests / CI | DÉFECTUEUX | ci.yml ; pdf.py:26-33 ; test_service.py:104-114 | Réconcilié : seul python-ia note DÉFECTUEUX ; agent-core, agent-skills, node-orchestration, node-features, database, frontend et infra notent INCOMPLET. Retenu DÉFECTUEUX car le défaut est démontré : `ci.yml` n'a jamais tourné et son job python-ia échouera. |
| C38 | Agent codeur | INCOMPLET | generation.py:41-119 ; generate.ts:115-174 | Produit un JSON d'architecture ; rien n'est exécuté. |

**Bilan** : 0 EXISTE ET FONCTIONNE, 28 EXISTE MAIS INCOMPLET, 5 EXISTE MAIS DÉFECTUEUX, 5 ABSENT.

### 3.2 Capacités au statut EXISTE ET FONCTIONNE

**Aucune** n'atteint le niveau V2 de bout en bout.

### 3.3 Briques vérifiées qui fonctionnent (socle de réutilisation)

- **File** : claim CAS avec jeton de clôture et 409 (agentTaskSql.ts:41-80, 7 tests), remise en file plafonnée, trigger qui préserve le heartbeat (hardening.sql:212-233).
- **Exécution** : thread d'étape avec timeout et délai de grâce (executor.py:38-96), outbox atomique (pending.py:57-69), allowlist run_command, `path_inside`.
- **Services** : clés agent hachées ; KnowledgeStore versionné (supabaseStore.ts:125-217) ; LLMProvider sans fuite de clé (test_service.py:257-355).
- **Médias** : pipeline slides + TTS vers MP4 (2 MP4 réels) ; record_screen, record_bg et edit_video produisent des fichiers lisibles.
- **Base et tests** : hardening.sql idempotente ; RESTAURATION_BASE.sql synchronisé ; 297 tests verts.

## 4. Capacités partielles

### 4.1 EXISTE MAIS INCOMPLET (28)

- **Orchestration** : C01, C03, C04, C06, C36. La planification est déléguée au LLM, la file garde des doubles exécutions résiduelles, la reprise repart de zéro, les rôles sont des étiquettes et il n'y a pas d'objet mission.
- **Contrôle de l'ordinateur** :
  - C09–C12 : actions aveugles, vision a posteriori ;
  - C14–C17 : sûrs mais étroits, sans sandbox ni worktree ;
  - C19 : montage rudimentaire ;
  - C20 : vidéo correcte, mais /demos est **défectueux**.
- **Modèles et connaissance** : C08, C28, C29, C32, C33, C38.
- **Sécurité et exploitation** : C21, C22, C23 (dry-run **défectueux**), C24, C30, C34, C35.

### 4.2 EXISTE MAIS DÉFECTUEUX (5, à corriger avant de construire dessus)

- **C18** : tout enregistrement de fond planifié est refusé, car compactStep perd `path`. La vidéo est plus courte que le temps réel, et `start_recording_bg` annonce un succès sur un chemin invalide.
- **C26** : des plans jamais exécutés sont stockés comme « solutions validées », les rejets sont réinjectés et les leçons générales ne sont jamais récupérées. C'est aussi une voie d'injection persistante.
- **C27** : la page KnowledgeBase et `save_knowledge` écrivent sans embedding, sans hash et sans version. Ces entrées sont exclues de deux recherches :
  - la recherche sémantique (`embedding IS NOT NULL`) ;
  - la recherche « KB d'abord » du service de recherche (filtre `maxAgeDays=90` sur `last_verified_at`, qui vaut NULL pour elles).

  La recherche web n'est pas en cause.
- **C31** : les propositions sont stockées sous `goal='(général)'` et ne sont donc jamais récupérées par l'ILIKE sur l'objectif. Aucune UI ne permet de les déclencher ou de les valider.
- **C37** : la CI n'a jamais tourné, son job python-ia échouera (PDF), et le workflow conda distant est cassé.

## 5. Capacités absentes

| id | Absent | Fondation existante |
|---|---|---|
| C02 | DAG, dépendances, parent_task_id | FormationEngine (recherche → programme → modules indépendants) |
| C05 | Pool, max_parallel_agents | claim atomique et 409 |
| C07 | 9 types de messages | canal `event`, table agent_events |
| C13 | Automatisation navigateur | rien |
| C25 | Mémoire de mission | niveau 'working' déclaré, goal_meta |

## 6. Problèmes techniques

Tous les problèmes ci-dessous sont **ouverts** dans `d542f65` ; aucun n'est « en cours » sur disque. (R) = reproduit en scratch ; (L) = latent, sans appelant dans l'UI.

**Déjà corrigés et vérifiés dans `d542f65`**
- Agent : allowlist run_command, injection open_app, chemins de capture, confirmation des commandes, timeouts, attempt/409, outbox, backoff, logs rotatifs.
- python-ia : x-ia-token (optionnel), validation des UUID, mapping d'erreurs.
- Base : migration hardening, script de restauration.
- node-api : timeouts, rate limit, CORS, initDb non fatal.
- Front : helper api, strictNullChecks.

| # | Sév. | Problème | Emplacement |
|---|---|---|---|
| T1 | Haute | Code seulement en local : `origin/main` n'a ni `backend/` ni `agent/`. Le workflow conda distant est cassé. | git ; .github |
| T2 | Haute | Un seul environnement (Supabase, en pause) et aucune sauvegarde. Le Postgres compose ne contient qu'analysis_requests. | docker-compose.yml ; postgres/init.sql ; auth.ts:59-85 ; scripts/backup_db.* |
| T3 | Haute | Dérive planner → agent : compactStep perd `path`/`fps` des `*_recording_bg`, ainsi que `timeout`, `button/clicks` et `method`. `cwd` n'est pas exigé. Confirmé aussi dans la worktree restructure a24b7bd. | agentGoal.ts:27-120 ; record_bg.py:114-115 |
| T4 | Haute | Un stop devient `failed`, part à l'évaluation et peut déclencher un correctif non demandé. | executor.py:148-151,239-241 ; agentGoal.ts:268-333 |
| T5 | Haute | Démos sans `steps` : faux succès, évaluation payante, mémoire polluée, retry impossible (L). | demoTasks.ts:42-55 ; formationVideo.ts:59-86 ; executor.py:120-121 |
| T6 | Haute | Un PDF de 2 pages ou plus plante hors Windows ; le test CI échouera. | pdf.py:18-33,53-55 |
| T7 | Haute | resolve_montage annonce un faux succès et n'est pas idempotent. | resolve_montage.py:120-197 |
| T8 | Haute | Le chat colle 50 entrées KB (≤ 100 000 car. chacune) dans le prompt, sans budget de tokens. | chat.ts:152-174 |
| T9 | Moyenne | Double exécution : un final resté > 180 s en outbox donne 2 exécutions ; un final REJECTED en donne 4 (R). | soulbah_agent.py:97-101 ; pending.py:123-139 ; agentTasks.ts:34-47 |
| T10 | Moyenne | Le dry-run réclame des tâches réelles, les marque `completed` et produit une mémoire validée (R). | executor.py:184-185 ; reasoning.py:123 ; agentGoal.ts:303-310 |
| T11 | Moyenne | Mémoire : les entrées '(général)' ne sont jamais récupérées, les rejets sont réinjectés, ILIKE sans index, tri par date seul. | agentMemory.ts:13-47,119,192-197 |
| T12 | Moyenne | KB : 2 écrivains sur 3 contournent le service. Le hash reste périmé après un PATCH. Une confidence hors bornes donne une 500. | KnowledgeBase.tsx:49-103 ; chatActions.ts:99-112 ; supabaseStore.ts:72 |
| T13 | Moyenne | Sans clé web, chaque recherche est une synthèse LLM à confiance auto-déclarée, mise en cache puis resservie comme connaissance (`source:'kb'`). Cela blanchit les hallucinations. Les URL citées ne sont pas vérifiées. | research/index.ts:45,59-96 ; research.py:70-74,88-91 |
| T14 | Moyenne | Récupération sémantique OU FTS, jamais hybride, avec un seuil cosinus fixe. Le filtre user_id s'applique après le scan HNSW (perte de rappel multi-locataire). Seuls 8000 car. sont embarqués par entrée. | supabaseStore.ts:259-281 ; embeddings.ts:16 |
| T15 | Moyenne | cancel_event est global : un thread zombie reste actif pendant la tâche suivante, ce qui interdit le parallélisme. | skills/base.py:16 ; executor.py:83-87,125 |
| T16 | Moyenne | Une file par utilisateur sans agent assigné ; le planner voit l'union des whitelists, donc un mauvais PC peut prendre la tâche. | agentKeys.ts:72-85 ; agentTasks.ts:114-128 |
| T17 | Moyenne | Évaluation non attendue (perdue sur crash) et hors transaction. L'UI affiche « Correction lancée » même sans tâche créée. | agentGoal.ts:287-333 ; AgentTasksPanel.tsx:279-281 |
| T18 | Moyenne | Les correctifs n'ont aucun lien vers leur parent (ni parent_task_id ni mission). Un objectif ne peut être ni regroupé ni annulé d'un bloc. | agentGoal.ts:150-161,324 |
| T19 | Moyenne | La reprise recommence à l'étape 0. Sans reaper global, une tâche orpheline reste `in_progress` indéfiniment. | agentTasks.ts:34-71,119 ; maintenance.ts |
| T20 | Moyenne | Captures base64 stockées en base et diffusées en Realtime ; `/events` renvoie 500 lignes avec leurs images. | executor.py:196,203-209 ; agentTasks.ts:267-277 |
| T21 | Moyenne | agent_events.task_id est polymorphe (tâche ou formation), sans FK, et purgé à 3 jours : inutilisable comme historique. | 20260706130000_agent_events.sql:7 ; generate.ts:36-43 ; maintenance.ts:37-46 |
| T22 | Moyenne | hotkey : « Ctrl+S » envoie Ctrl+Shift+S, une touche inconnue renvoie ok. Aucune skill ne vérifie son effet. | hotkey.py:17-44 ; mouse.py:28-50 ; type_text.py:98-106 |
| T23 | Moyenne | Le timeout de run_command ne tue pas l'arbre (npm.cmd → cmd → node survivent). | run_command.py:316-331 |
| T24 | Moyenne | Enregistrement : écran principal seul, mp4v, vidéo accélérée, clé `_ACTIVE` non normalisée. | record_bg.py:42-156 ; record_screen.py:56-78 |
| T25 | Moyenne | edit_video supprime tout l'audio. La narration Resolve est ajoutée après la vidéo, sans synchronisation, et ses erreurs sont avalées. | edit_video.py:81 ; resolve_montage.py:145-169 |
| T26 | Moyenne | Routeur : le fallback ne se déclenche jamais, vision=True par défaut, usage et troncature ignorés. Timeouts désalignés : SDK 600 s × 3 contre 120 s côté node. | router.py:84-105 ; openai_compat.py:26 ; anthropic_provider.py:25,71-74 |
| T27 | Moyenne | La vidéo est une requête synchrone (TTS séquentiel par slide), sans file de jobs ni annulation. python-ia continue et paie après l'abandon de node à 900 s. | python-ia main.py:258-270 ; video.py:252-261 ; iaClient.ts:16-17 |
| T28 | Moyenne | Formations : garde 409 en TOCTOU et en mémoire, deux pipelines qui divergent, aucun checkpoint. | generate.ts:49-108 ; chatActions.ts:39 |
| T29 | Moyenne | Les événements de formation détournent le cockpit (pause/stop renvoient 404). | AgentCockpit.tsx:90-116 ; generate.ts:37-60 |
| T30 | Moyenne | Types Supabase périmés (6 tables manquantes, casts `as unknown as`). | src/integrations/supabase/types.ts |
| T31 | Moyenne | Sidebar factice : « opérationnel », 75 %, CPU 34 %, RAM 62 %. | Sidebar.tsx:80-90 |
| T32 | Moyenne | Console `frontend/` en 401 permanent et hors CI (régression du tour précédent). | frontend/src/api/client.ts:26-31 ; analyze.ts:11 |
| T33 | Moyenne | La CommandBar perd la demande pour chat, generate, database et video. | CommandBar.tsx:20-32 |
| T34 | Moyenne | Un Python global partagé par l'agent et python-ia ; épingles en conflit ; versions installées différentes des épingles. | agent/requirements.txt ; python-ia/requirements.txt |
| T35 | Moyenne | Trous de CI : ni `tsc` racine, ni cargo, ni build Docker, ni test de migrations, ni runner Windows, ni audits (npm/pip, gitleaks, CodeQL). | .github/workflows/ci.yml |
| T36 | Moyenne | Tests purement unitaires : ni Fastify inject, ni DB, ni E2E, ni tests de pages. 6 skills et rust-compute n'ont aucun test. | node-api/test/* ; src/lib/*.test.ts ; agent/tests |
| T37 | Moyenne | Aucune gouvernance des ressources : conteneurs sans limites, médias sans rétention (22 Mo déjà), rate limit en mémoire, clé IP sans `trustProxy`. | docker-compose.yml ; server.ts:56-78 ; maintenance.ts:37-46 |
| T38 | Moyenne | `vector(1536)` est figé alors que le modèle d'embedding est configurable ; aucun `embedding_model` par ligne. | 20260706150000_knowledge_embeddings.sql:7 ; embeddings.ts:5-6 |

**Sévérité basse** (une ligne et un emplacement chacune)
- T39 Pause : 1 événement et 1 GET par seconde ; une erreur pendant la pause (get_control renvoie 'none') relance l'exécution (executor.py:139-144 ; client.py:132-143).
- T40 Ctrl+C ne fait que lever un drapeau ; la tâche courante continue jusqu'à environ 32 min (soulbah_agent.py:73-76,270-273).
- T41 401/403 classés comme transitoires : une clé révoquée apparaît comme « backend injoignable » (client.py:35-42).
- T42 `python3` résout vers le stub WindowsApps (run_command.py:257-272).
- T43 `bool("false")` vaut True pour `feasible` (reasoning.py:148).
- T44 L'orchestrateur répond 200 `success:true` quand la planification échoue (orchestrator.ts:49-53).
- T45 Renvoyer la même valeur de `control` prolonge le bail (hardening.sql:218-225 ; agentTasks.ts:258-261).
- T46 Pas d'index pour la requête de poll (20260218152103:44 ; agentTasks.ts:120-124).
- T47 Migrations de juillet non rejouables (20260703000000_agent_keys.sql:20 ; 20260706130000_agent_events.sql:17).
- T48 `modules_status` est un schéma mort (20260218031213:107-120).
- T49 `tsx` en production, sans build compilé (node-api/Dockerfile:7,15 ; package.json:8,18).
- T50 rust-compute : pas de Cargo.lock, image root, `/infer` renvoie 500 sans Rust (rust-compute/Dockerfile:14-18 ; rust_client.py:6-14).
- T51 Thread heartbeat jamais joint : 409 parasite après le final (soulbah_agent.py:170-191).
- T52 Le lanceur n'active pas `.venv`, contrairement au README (Lancer_Agent.bat:13,20).
- T53 Tests non hermétiques : ils chargent le vrai agent/.env (config.py:7-12).
- T54 Documentation périmée (backend/README.md ; MIGRATION.md:87-90 ; docs/SOULBAH_AI_ARCHITECTURE.md:110,113).

## 7. Problèmes de sécurité

Tous sont **ouverts** dans `d542f65`.

| # | Sév. | Problème | Emplacement |
|---|---|---|---|
| S1 | Haute | La whitelist est la racine du dépôt. `read_file` sur les .env renvoie leur contenu dans agent_tasks.result, puis au LLM évaluateur. `write_file` peut réécrire permissions.py ou agent/.env. Une sonde sans effet le confirme en mode auto ; le mode confirm actuel atténue le risque. | agent/.env ; permissions.py:151-167 ; filesystem.py:39-68 ; agentGoal.ts:284-289 |
| S2 | Haute | Garde `.git` contourné (PoC vérifié) : `git init --separate-git-dir`, puis écriture d'un hook, exécuté au `git commit`. | run_command.py:33-39,121-134 ; filesystem.py:19-27 |
| S3 | Haute | Le contrôle des entrées équivaut à une exécution de code (win+r, terminal VS Code). Rien n'est confirmé avec ALLOW_INPUT_CONTROL. | hotkey.py ; type_text.py ; permissions.py:202-205 |
| S4 | Haute | node-api se connecte en `postgres` : toute la RLS est contournée. La page Sécurité affirme le contraire. | db.ts:29-37 ; backend/.env ; Security.tsx:221-231 |
| S5 | Haute | Commandes sans sandbox : `npm install/run`, `pytest` (conftest) et `python x.py` exécutent du code écrit par l'agent, sous une confirmation qui n'en montre pas le contenu. | run_command.py:31-41,317 ; filesystem.py:56-61 |
| S6 | Moyenne | Téléphone hors du verrou input, non confirmé en mode auto. | permissions.py:17,207-210 ; phone.py:96-101 |
| S7 | Moyenne | Confirmations sans contenu : type_text en montre 40 car., write_file le chemin seul. | type_text.py:82-85 ; filesystem.py:36-37 |
| S8 | Moyenne | Les textes tapés partent dans les logs, agent_events, le payload, le prompt LLM et le presse-papiers. | executor.py:161,187 ; type_text.py:59-104 ; reasoning.py:191 |
| S9 | Moyenne | Supprimer une tâche en cours ne l'arrête pas : control répond 'none' et l'agent ignore les 404. | AgentTasksPanel.tsx:182-190 ; agentTasks.ts:233-246 ; client.py:35-41 |
| S10 | Moyenne | Les correctifs générés par le LLM partent en file sans approbation (injection indirecte). | agentGoal.ts:315-324 |
| S11 | Moyenne | Empoisonnement de la mémoire : verdicts LLM et dry-runs stockés `validated`, insertions client directes acceptées. | agentMemory.ts:28-46 ; 20260704000000_agent_memory.sql:18-20 |
| S12 | Moyenne | Les tool calls du chat sont auto-exécutés, alors que la KB est injectée avec une autorité système. | AiChat.tsx:271-282 ; chat.ts:152-171 |
| S13 | Moyenne | TLS vers la base sans vérification du certificat. | db.ts:16-26 |
| S14 | Moyenne | python-ia est ouvert (token absent) : routes LLM payantes, /docs, /providers. | python-ia main.py:28-35,61-68 |
| S15 | Moyenne | system_logs, le seul « audit », accepte les INSERT du client. | 20260218031213:104 |
| S16 | Moyenne | npm audit : 1 alerte haute (dev) et 2 modérées (prod). Le serveur de dev écoute sur `::`. | package.json ; vite.config.ts:9 |

**Sévérité basse**
- S17 Captures jamais confirmées ; l'écran complet part au backend et au LLM (screenshot.py ; permissions.py:196-197).
- S18 HOST=0.0.0.0, ports compose publics, /media et /health/deep sans authentification (docker-compose.yml:131-153 ; server.ts:89).
- S19 has_role répond pour autrui, y compris en anon ; un REVOKE naïf casse la policy user_roles et isAdmin (20260218031213:33-46).
- S20 INSERT inter-locataires, agent_keys en FOR ALL, clés sans expiration et en clair (20260218041438:33 ; knowledge_base_pro.sql:58 ; 20260703000000_agent_keys.sql:20).
- S21 Tout JWT authentifié peut mettre en file des `run_command`/`write_file` arbitraires ; le serveur ne vérifie que la forme (agentTasks.ts:281-293).
- S22 Confirmation à la console seulement. `step_started` est émis avant l'autorisation, donc l'UI ne voit pas qu'une approbation est en attente (permissions.py:133-146 ; executor.py:161-179).
- S23 Texte d'exception interne et corps d'erreur amont renvoyés aux clients (python-ia main.py:269,334 ; anthropic_provider.py:63-68).
- S24 close_window agit sur la première correspondance de sous-chaîne (window.py:52-53).
- S25 Un x/y en chaîne fait ouvrir par pyautogui une image hors whitelist (mouse.py:46-47).
- S26 Un JWT Supabase reste accepté jusqu'à 60 s après la déconnexion (auth.ts:54-104).
- S27 requests 2.32.3, vulnérable à CVE-2024-47081 (agent/requirements.txt:1).
- S28 TOCTOU : un lien symbolique peut être remplacé entre l'autorisation et l'exécution (permissions.py:45 ; executor.py:188).
- S29 Garde de taille de corps contournable en chunked (python-ia main.py:68-76).
- S30 Mot de passe DB passé en argument de pg_dump ; dumps non chiffrés (backup_db.sh:70-75 ; backup_db.ps1:51-55).
- S31 Self-XSS dans AppPreview ; postMessage sans contrôle d'origine (AppPreview.tsx:48-69,194-207).
- S32 Tout utilisateur peut forcer un fournisseur LLM (python-ia main.py:117,125,147 ; orchestrator.ts:24).
- S33 Clé anon dans l'historique public, publique par conception (origin/main:.env).

## 8. Dépendances importantes

| Couche | Dépendance (version) | Point d'attention |
|---|---|---|
| Agent | Python 3.11.9 global ; requests 2.32.3 | pas de venv ; CVE, passer à ≥ 2.32.4 |
| Agent | pyautogui 0.9.54, pygetwindow 0.0.9, pyperclip, mss 9.0.1, Pillow 10.4.0, opencv 4.10, moviepy 1.0.3 + imageio-ffmpeg | pygetwindow n'est plus maintenu ; numpy non épinglé ; pas de CLI ffmpeg |
| Agent (externes) | DaVinci Resolve, adb | non installés, jamais testés |
| node-api | Node ≥ 22.19, fastify 5.12.5, pg 8.23.1, undici 8.11.2, tsx 4.23.15 | npm audit prod : 0 alerte |
| python-ia | fastapi 0.142.2 (0.115.5 installé), pydantic, httpx, anthropic <1.0 (1.11 disponible), claude-opus-4-8, fpdf2, moviepy | versions installées ≠ épingles ; Opus 5.5 : thinking face à de petits max_tokens |
| Front | react 18.3.1, react-router-dom 6.30.6, supabase-js 2.96.0, vite 5.4.21 | 2 alertes modérées en prod |
| Données | Supabase (en pause) ; PostgreSQL 18 local | **pgvector absent en local** (0 fichier dans `share/extension`), pas de binaire Windows, pas de Visual Studio/MSVC ; version majeure de Supabase inconnue |
| Externes | OpenAI, Anthropic ; Tavily/Serper/Brave non configurés | une seule clé utilisée par python-ia |
| À ajouter | uiautomation, playwright, psutil, keyring, jsonschema, pypdf ; ajv | aucune n'est installée |

## 9. Proposition d'architecture V2 adaptée au code réellement existant

### 9.1 Choix : Split-Plane (trois plans)

**Les trois plans**
- **P1 contrôle** = `backend/node-api`, seul écrivain de `soulbah.*`.
- **P2 modèles** = `backend/python-ia`, seul routeur de modèles.
- **P3 exécution** = `agent/`, transformé en runtime à N sous-processus.

**Alternatives écartées**
1. *Tout dans node-api, avec l'exécution PC dans un seul processus à deux couloirs.* Meilleure réutilisation du code, mais ni isolation par tâche, ni vrai parallélisme, et des boucles de vision éloignées de l'écran.
2. *Cerveau local dans `agent/`.* Deux sources de vérité, un audit dans un SQLite que l'agent peut modifier, et le plan et l'état au même endroit que le contrôle des entrées.

**Limite assumée.** Split-Plane garde lui aussi des boucles LLM de rôle dans les workers, près de l'écran (§9.2), parce que la latence de la vision l'exige. Le risque « LLM à côté d'un contrôle d'entrées » n'est donc pas supprimé par l'emplacement : il est **borné** par trois mécanismes.
1. Le worker n'émet que des appels d'outils, tous filtrés par le Tool Gateway (L0–L3, deny-list, verrou `desktop.input`).
2. Toute action L2/L3 exige une approbation émise par P1, liée au `payload_sha256` et vérifiée par jeton HMAC.
3. Le plan, l'état, l'audit, les budgets et la rédaction restent dans P1. Le worker ne détient ni l'audit, ni les clés fournisseur, ni le pouvoir de s'auto-approuver.

**Éléments repris des alternatives**
- `AUTH_MODE=dev-local`, refusé hors dev et hors 127.0.0.1.
- Long-poll servi avec un seul client LISTEN.
- `embedding` sans dimension fixe et `embedding_model` par ligne.
- Extension de `agent_memory` et `knowledge_base` plutôt que tables parallèles.
- `target_agent_key_id`/`claimed_by_key_id` dès la V1 (corrige T16).
- Pont `/api/agent/goal` derrière un drapeau.
- Tolérance hors ligne du runtime.
- Chaque défaut de l'audit devient un test permanent.

### 9.2 Vue d'ensemble

```
┌──────── Navigateur React (src/ → frontend/src après restructure) ────────┐
│ Missions · DAG · Agents x/6 · Approbations · Messages · Preuves · Coûts  │
└──────┬────────────── /api/v2/* (JWT) ─────────────▲── SSE /api/v2/stream ┘
       ▼                                             │
╔═ P1 CONTRÔLE — backend/node-api (seul écrivain de soulbah.*) ═══════════════╗
║ Orchestrateur → Planner (gabarits + proposition LLM → validateDag → OK)     ║
║ Scheduler (READY, baux SKIP LOCKED, max_parallel, ressources, reaper)       ║
║ File 10 états · Bus 9 types · Mémoire · RAG hybride · Évaluation · L0–L3   ║
║ Audit chaîné · Relais modèles (budget, rédaction) · Artefacts · V1 /api/*  ║
╚══╤════════════════╤════════════════════════════════════▲════════════════════╝
   │ pg :5432       │ HTTP 127.0.0.1 + x-ia-token          │ HTTP 127.0.0.1 aujourd'hui (même PC) ;
   │ LISTEN/NOTIFY  ▼ (obligatoire hors dev)               │ HTTPS si P1 est hébergé ailleurs :
┌──▼────────────┐ ┌─ P2 MODÈLES — backend/python-ia ─┐     │ register · lease · keepalive · actions ·
│ public.* (V1) │ │ invoke/stream · embed · tts ·    │     │ checkpoints · result · artefacts ·
│ soulbah.* (V2,│ │ vision/locate · rerank · propose │     │ approbations (écritures clôturées par
│  API seule)   │ │ profils, disjoncteur, usage/coût │     │ task_id + attempt + lease_owner)
└───────────────┘ └──────────────────────────────────┘     │
╔═ P3 EXÉCUTION — agent/ → soulbah-runtime (session Windows interactive) ═╧═════╗
║ Superviseur : bail · journal SQLite WAL + outbox · Tool Gateway (L0–L3,       ║
║   deny-list, approbations, verrous, preuves, artefacts sha256)               ║
║ ├─ slots 1..N : sous-processus, 1 Job Object par tâche, rôle lié au bail     ║
║ ├─ outils : 17 skills corrigées + browser · vscode · git_workspace · verify  ║
║ └─ legacy_adapter : protocole V1 sur public.agent_tasks                      ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

**Répartition.** Les boucles LLM des rôles tournent dans les workers. Tous leurs appels modèle passent par le relais de P1, qui applique budget, rédaction, audit et coût.

**Topologie réelle**
- Aujourd'hui, P1, P2 et P3 tournent tous sur **ce même PC**, hors Docker ; P1 et P2 lisent `backend/.env`.
- La garantie est donc une séparation de **processus et de répertoires**, pas de machines. Aucune clé fournisseur n'est présente dans le processus runtime, son environnement ou son workspace. Le runtime refuse de démarrer si son workspace contient un `.env`.
- Héberger P1/P2 ailleurs reste possible sans changer le protocole, mais aucun lot ne le planifie : la décision sera documentée au LOT 15.
- Le packaging du runtime (lancement à l'ouverture de session, poignée de main de version, mise à jour) est livré au LOT 8.

**rust-compute**
- La V2 n'en dépend pas ; Rust n'est d'ailleurs pas installé sur cette machine.
- Décision : gelé comme démo optionnelle (profil compose `demo`, hors CI bloquante). `/infer` renverra 503 au lieu de 500 quand Rust manque.
- Aucun rôle V2 ne lui est attribué : hachage, BM25 et probe vidéo restent en Postgres et en Python. Sa suppression est proposée au LOT 15 si aucun besoin mesuré n'apparaît.

### 9.3 Modules : emplacement et réutilisation

| Module | Où | Réutilise | Apporte |
|---|---|---|---|
| Soulbah Core | P1 server.ts, config.ts, src/v2/ | bootstrap Fastify, erreurs, rate limit, CORS | SOULBAH_ENV, drapeau V2, client LISTEN, `requireRuntime`, dev-local |
| Orchestrator | P1 v2/sessions | orchestrator.ts (`execute` crée une session), agents.py (choix du gabarit) | cycle DRAFT → PLANNING → AWAITING_APPROVAL → RUNNING/PAUSED → terminal ; `plan_version` |
| Planner | P1 v2/planner ; P2 /v2/planner/propose | plan_goal, FormationEngine, demoTasks | `validateDag` (acyclique, rôles, niveaux, chemins, critères, budget) ; nœud *observe* avant toute tâche écran |
| Scheduler | P1 v2/scheduler | clôture CAS, remise en file plafonnée | READY, SKIP LOCKED, plafonds, classes de ressources, backoff, reaper global |
| Agent Runtime | P3 agent/runtime | `_run_step`, outbox, heartbeat, 156 tests | superviseur, N sous-processus, CancelToken par tâche, rôles versionnés, legacy_adapter |
| Tool Gateway | P3 runtime/gateway.py | PermissionGate, allowlist run_command, résolveur open_app | niveaux du catalogue, deny-list, approbations distantes, verrous, idempotence, preuves |
| Computer Control | P3 roles/desktop_operator, runtime/vision | skills d'entrée corrigées | observer (mss, UIA, DPI) → décider (/v2/vision/locate) → agir sous `desktop.input` → vérifier |
| Browser Engine | P3 skills/browser.py | rien | Playwright headless, un contexte par tâche ; preuves URL, statut, hash DOM |
| Code Execution Env | P3 git_workspace.py, sandbox.py, vscode.py | parseurs run_command, CLI `code` | worktrees, Job Object (kill d'arbre, limites), env nettoyé, `--ignore-scripts` sauf L3, rapports de tests |
| Knowledge Engine | P1 services/knowledge ; P3 kb_ingest | KnowledgeStore, index HNSW/FTS | chunks, RRF + filtres + rerank, écrivain unique, *findings* séparés du validé |
| Memory Engine | P1 v2/memory | workflow proposed/validated/rejected | portée session et TTL, admission sur preuve, récupération par portée/tags/vecteur |
| Evaluation Engine | P1 v2/evaluation ; P3 verify.* | evaluate_execution (rubrique à faible confiance) | DSL de critères, niveaux de confiance, VALIDATING durable, qa_reviewer, `action_taken` |
| Video Engine | packages/soulbah_media | video.py, montage.py, record_bg | enregistreur H.264 horodaté, probe, jobs annulables, TTS via le routeur |
| Security & Permission | P1 v2/security ; P3 gateway | gate, clés hachées, JWT | L0–L3, approbations HMAC, rédaction, budgets, keyring/DPAPI, token IA obligatoire hors dev |
| Audit Engine | P1 v2/audit | logEvent (reste le fil d'activité) | `audit_logs` en ajout seul, chaîné, écrit dans la transaction du changement d'état |
| Model Router | P2 providers/*, app/v2 ; P1 v2/models | LLMProvider, registry, upstream_error, fake_llm | usage, coût, latence ; capacités explicites ; profils par rôle ; fallback multi-sauts + disjoncteur ; FakeProvider |

### 9.4 Machine à états des tâches (10 états, `soulbah.tasks`)

Chemin nominal : `PENDING → READY → RUNNING → VALIDATING → COMPLETED`. Transitions complètes :

| De | Vers | Déclencheur |
|---|---|---|
| PENDING | READY / BLOCKED | toutes les dépendances dures COMPLETED / une dépendance dure FAILED ou CANCELLED |
| READY | RUNNING | bail accordé (capacité, verrous, budget) ; `attempt+1` |
| RUNNING | WAITING | QUESTION, approbation L2/L3, verrou ou budget indisponible |
| WAITING | RUNNING / BLOCKED | condition satisfaite (même bail) / délai dépassé ou approbation refusée |
| RUNNING | BLOCKED | BLOCKER émis |
| BLOCKED | READY | blocage levé (réponse, verrou libéré, dépendance remplacée) |
| BLOCKED | PENDING | replanification (`plan_version+1`, nouvelles dépendances) |
| BLOCKED | FAILED | délai d'escalade dépassé (24 h par défaut) |
| RUNNING | VALIDATING | TASK_RESULT reçu |
| VALIDATING | COMPLETED | tous les critères requis passent au niveau de confiance demandé |
| RUNNING, WAITING, VALIDATING | RETRYING | crash, timeout, **bail expiré (le reaper passe directement en RETRYING)** ou critère échoué, avec `retry_count < max_retries` |
| RUNNING, WAITING, VALIDATING | FAILED | même cause avec les retries épuisés, ou erreur non rejouable (refus de politique, run `simulated`) |
| RETRYING | READY | backoff écoulé (30 s, 2 min, 8 min) ; `retry_count+1` |
| tout état non terminal | CANCELLED | stop ou annulation utilisateur, session annulée ; jamais d'auto-correction |
| FAILED | READY | relance manuelle par l'utilisateur, auditée ; sinon FAILED est terminal |

**Règles complémentaires**
- Un bail expiré ne passe jamais par FAILED pour revenir en RETRYING.
- Un final tardif pour l'attempt *a* est accepté tant qu'aucun bail plus récent n'existe.
- **Compatibilité V1** : `public.agent_tasks` garde ses 5 statuts. L'adaptateur fait la correspondance pending ↔ PENDING/READY, in_progress ↔ RUNNING, et les statuts terminaux à l'identique.
- **États d'une action** : planned → attempted → executed → verified. Autres issues : failed, skipped, ou `simulated` (dry-run), qui ne peut jamais devenir `verified`.

### 9.5 Messages structurés (`soulbah.messages`)

Champs : `session_id`, `task_id`, `from_agent_id`, `to_agent_id`/`to_role`, `type`, `correlation_id`, `reply_to`, `payload` (schéma JSON, ≤ 64 Ko), `requires_ack`, `acked_at`. Les messages sont livrés aux workers par le keepalive et au dashboard par SSE.

| Type | Effet géré par P1 |
|---|---|
| TASK_REQUEST | patch de plan proposé (`plan_version+1`) |
| TASK_RESULT | résultat attaché, tâche → VALIDATING |
| QUESTION | tâche → WAITING jusqu'à la réponse |
| BLOCKER | tâche → BLOCKED, puis replanification ou escalade |
| EVIDENCE | preuve rattachée aux critères |
| REVIEW_REQUEST | création d'une tâche qa_reviewer |
| REVIEW_RESULT | débloque ou refuse le merge |
| ERROR | journal, puis politique de retry |
| KNOWLEDGE_FOUND | proposition mise en file, jamais validée automatiquement |

### 9.6 `max_parallel_agents = 6`, configurable

Le parallélisme effectif est le minimum de quatre valeurs :

| Source | Défaut | Rôle |
|---|---|---|
| `SOULBAH_MAX_PARALLEL_AGENTS` (config.ts) | 6 | plafond global |
| `soulbah.user_settings.max_parallel_agents` (page Paramètres, CHECK 1–32) | 6 | réglage par utilisateur |
| `sessions.max_parallel_agents` (`PATCH /api/v2/sessions/:id`) | aucun | surcharge par mission |
| `runtimes.max_slots` (annoncé par le runtime, `SOULBAH_MAX_SLOTS`) | 6 | capacité du PC |

- La valeur est relue à chaque tick du scheduler.
- La baisser bloque seulement les nouveaux baux, sans interrompre les tâches en cours.
- Le compteur « x/6 » = agents BUSY rapportés à cette valeur effective.
- Sur ce PC : 1 agent bureau (`desktop.input` exclusif) et jusqu'à 5 agents sans écran (codeur en worktree, navigateur headless, recherche, rendu vidéo, QA).

### 9.7 Verrous de fichiers et worktrees git

**La table `soulbah.resource_leases`**
- Colonnes : `resource_key`, `holder_task_id`, `mode`, `expires_at`.
- Un index unique partiel sur les verrous exclusifs garantit l'exclusivité.
- Clés normalisées des deux côtés : `desktop.input:<runtime>`, `phone:<serial>`, `file:<chemin>`, `repo:<id>:worktree:<task>`, `repo:<id>:ref:<branche>`, `cpu.heavy` (≤ 2).
- Les ressources sont déclarées dans le nœud du DAG et acquises au moment du bail (le calcul de READY en tient compte). Elles sont libérées en fin de tâche ou par le reaper.
- Le gateway exige `desktop.input` pour toute action souris, clavier ou téléphone.

**Le workspace et les worktrees**
- Workspace : `SOULBAH_WORKSPACE_ROOT` (défaut `%USERPROFILE%\SoulbahWorkspace`), jamais le dépôt Soulbah.
- Chaque tâche de code a sa worktree, sur la branche `soulbah/<session>/<task>`.
- Merger vers `soulbah/<session>/integration` relève du niveau L2. Il exige le verrou de ref, un REVIEW_RESULT positif et des tests verts.
- Merger vers la branche de l'utilisateur, faire un push ou un `branch -D` relève du niveau L3.
- Un conflit émet un BLOCKER.

### 9.8 Capture des preuves

**Identification.** Clé d'idempotence `task_id:attempt:step_index`. Une action passe par planned, attempted (journal local + `POST actions`), executed (preuve brute) puis verified (post-condition contrôlée).

**Niveaux de confiance**

| Confiance | Types de preuves |
|---|---|
| Élevée | code de sortie, rapport de tests, sha256 avant/après, statut HTTP, probe vidéo |
| Moyenne | état UIA, titre de fenêtre |
| Faible | jugement visuel d'un modèle |
| Nulle | auto-déclaration de l'agent |

**DSL de critères** : `file_exists`, `file_contains`, `command_succeeds`, `tests_pass`, `http_status`, `git_branch_contains`, `video_valid`, `ui_element_state`, `artifact_hash`, `llm_rubric`.

**Règles de complétion**
- COMPLETED exige que tous les critères requis passent.
- Une tâche L2 ou plus exige au moins une preuve de confiance moyenne.
- Un dry-run ou un plan vide ne passent jamais.

**Artefacts** : adressés par sha256, téléversés par `PUT` idempotent, lus par `GET` authentifié. Plus aucun base64 en base.

### 9.9 Reprise après crash

| Panne | Comportement |
|---|---|
| Worker | Kill du Job Object ; RETRYING depuis le dernier checkpoint. |
| Superviseur ou PC | `journal.db` est réconcilié avec P1, qui répond *resume*, *abandon* (attempt plus récent) ou *cancel*. Le traitement dépend de l'état de chaque étape (voir ci-dessous). |
| P1 | L'état est dans Postgres. Les tâches VALIDATING orphelines sont réévaluées une fois par attempt ; scheduler et reaper reprennent sous advisory lock. |
| Base injoignable | Le runtime termine l'étape en cours, met ses écritures en tampon et ne prend plus de bail. |
| Final en outbox | Le bail reste maintenu en « finalizing » et aucun nouveau travail n'est pris. Un final rejeté est remplacé par un FAILED minimal qui référence les artefacts (ferme T9). |

Après un crash du superviseur ou du PC, chaque étape est traitée selon son état :
- `verified` : sautée ;
- `executed` : seule la vérification est rejouée ;
- `attempted` : rejouée seulement si l'outil est idempotent ;
- sinon : contrôle de la post-condition, ou WAITING pour qu'un humain tranche. move_file, type_text et git commit ne sont jamais rejoués à l'aveugle.

### 9.10 Niveaux de sécurité

| Niveau | Périmètre | Approbation |
|---|---|---|
| L0 | lecture sans effet dans le workspace, KB, mémoire, `git status/diff/log`, web headless | automatique |
| L1 | réversible et confiné : écriture dans le workspace, tests en sandbox | automatique après approbation de la session |
| L2 | effets réels : souris, clavier, téléphone, apps, scripts npm, merge d'intégration | grant de session ou approbation par action avec le contenu complet |
| L3 | irréversible : suppression, push, `branch -D`, secrets, installation, promotion | par action, payload complet, jamais en lot |
| DENY | code et config de l'agent, `*.env`, `.ssh`, clés, hooks, `git init --separate-git-dir/--template` | toujours refusé |

## 10. Fichiers qu'il faudra modifier

| Fichier(s) | Changement |
|---|---|
| agent/config.py, permissions.py | Workspace hors du dépôt (refus au démarrage sinon), deny-list, téléphone sous verrou, niveaux, approbation distante, décisions positives journalisées, realpath revérifié avant exécution, `SOULBAH_NO_DOTENV`. |
| agent/executor.py, soulbah_agent.py, client.py, pending.py | Plan vide = échec ; dry-run = `simulated` ; CancelToken ; checkpoints. Stop → `cancelled` ; 404/410 → abandon ; 401/403 diagnostiqués ; final minimal ; Ctrl+C interrompt. |
| agent/skills/*.py, requirements.txt, Lancer_Agent.bat | Manifestes ; options git refusées ; Job Object ; écriture atomique + sha256 ; validation des entrées ; presse-papiers restauré ; H.264 + probe ; rendu Resolve vérifié ; requests ≥ 2.32.4 ; `.venv`. |
| node-api server.ts, config.ts, db.ts, auth.ts | Routes v2 sous drapeau, scheduler et reaper, LISTEN, `requireRuntime`, dev-local, token IA et CA obligatoires hors dev. |
| routes/agentTasks.ts | `POST /:id/cancel`, 410 + « stop » pour une tâche absente, reaper global, long-poll, filtre `target_agent_key_id`, `/events` sans base64. |
| lib/agentTaskSql.ts | **Modifié** : la requête de claim (kind `claim`, l.53-66) écrit aussi `claimed_by_key_id`. La garde CAS (`status='pending' AND requeue_count=attempt`) reste inchangée. Tests ajoutés aux 7 existants. |
| lib/agentSteps.ts, agentGoal.ts, agentMemory.ts, orchestrator.ts | Validation générée depuis le catalogue. Pas d'évaluation des runs stoppés, simulés ou vides. 3 dernières captures. `action_taken`. Mémoires `proposed`, rejets exclus, récupération par portée. 502 en cas d'échec. Provider sous allowlist. |
| formationVideo.ts, knowledge/*, research/*, chat.ts, chatActions.ts | `/demos` via gabarit ; hash recalculé au PATCH ; chunks et RRF ; findings datés ; top-k sous budget ; tool calls approuvés côté serveur. |
| python-ia main.py, providers/*, reasoning.py, pdf.py, video.py, rust_client.py | Router v2 ; token obligatoire hors dev ; CompletionResult ; capacités ; disjoncteur ; catalogue généré ; fin de la règle « dry-run = succès » ; police TTF ; `/infer` → 503. |
| src/ : AgentTasksPanel, AgentCockpit, Sidebar, CommandBar, KnowledgeBase, AiChat, Security, lib/api.ts, types.ts | Annulation via l'API, statut `cancelled`, raison du refus 422 affichée ; événements filtrés par source ; métriques réelles ; prefill lu partout ; KB via l'API ; approbation des tool calls ; affirmation sur la RLS corrigée ; types régénérés. |
| frontend/src/api/client.ts, docker-compose.yml, ci.yml, docs | JWT de dev ou retrait de l'appel. Ports liés à 127.0.0.1, profil `demo` pour rust-compute. Jobs CI db, catalogue, `tsc` racine, windows-latest, audits. Documentation V2. |

## 11. Nouveaux composants nécessaires

| Chemin | Rôle |
|---|---|
| shared/{tools,schemas,roles,models}/ + scripts/gen_catalog.py | Catalogue d'outils unique et généré ; schémas DAG, critères, preuves et messages ; rôles versionnés ; profils et tarifs. `--check` bloque toute dérive. |
| scripts/dev_db/ | PG18 local (`initdb`/`pg_ctl`), stub auth, **réécriture du DDL pgvector en stub**, application ×2, jeton de dev. |
| backend/node-api/src/v2/* | Sessions, tâches, scheduler, planner, messages, routes runtime, évaluation, sécurité, audit, mémoire, RAG, artefacts, SSE, métriques. |
| agent/runtime/*, agent/skills/{git_workspace,browser,vscode,verify,kb_ingest}.py | Superviseur, pool, Job Objects, journal SQLite, gateway, approbations HMAC, rédaction, DPAPI, rôles, vision, sandbox, legacy_adapter ; nouveaux outils. |
| agent/Lancer_Runtime.bat + packaging | Instance unique, démarrage à l'ouverture de session, poignée de main de version, mise à jour. |
| packages/soulbah_media/ ; backend/python-ia/app/v2/, providers/{capabilities,usage,circuit,fake}.py | Médias partagés (slides, montage, enregistreur, probe, polices) ; API du routeur, coûts, disjoncteur, FakeProvider. |
| benchmarks/missions/, fixtures RAG | Missions de référence (LOT 15) ; corpus étiqueté avec embeddings précalculés versionnés. |
| src/pages/{Missions,MissionDetail}.tsx, src/components/v2/ | Pool x/N, DAG, approbations, messages, preuves, live, coûts. |

## 12. Migrations nécessaires

**Toutes les migrations sont additives.** Aucune ne supprime de données, ne renomme une table ni ne touche au CHECK de statut d'`agent_tasks`.

**Règles communes**
- Style de `hardening.sql` : `IF NOT EXISTS`, `DROP POLICY IF EXISTS` puis `CREATE`, contraintes `NOT VALID` puis `VALIDATE` dans un bloc d'exception, Realtime dans un bloc `DO`.
- `RESTAURATION_BASE.sql` et `types.ts` sont régénérés à chaque lot.

**pgvector : chemin retenu.** PG18 local n'a pas pgvector, il n'existe pas de binaire Windows et MSVC n'est pas installé.
1. **Local (PG18)** : `scripts/dev_db` réécrit à la volée le DDL vectoriel (CREATE EXTENSION vector → type stub, index HNSW sautés), comme lors de l'audit LOT 0. Cela valide tout le schéma **sauf** la sémantique vectorielle.
2. **Répétition sur dump** : le dump de production ne quitte jamais le PC. Il est restauré en local avec `pg_restore -l/-L`, en excluant l'extension et les colonnes et index vectoriels.
3. **Vérifications vectorielles** (DDL `vector`, HNSW, Recall@5 du LOT 13) : uniquement dans le job CI `db`. L'image `pgvector/pgvector` y est **épinglée sur la version majeure de Supabase**, relevée par `SHOW server_version` dès la restauration (inconnue aujourd'hui ; pas de pg16 par défaut). Ces vérifications portent sur le schéma et des fixtures, jamais sur des données réelles.
4. **Option** : compiler pgvector pour PG18 avec les Build Tools MSVC (`Makefile.win`) supprimerait l'écart local. Ce n'est pas requis par le plan.

**Ordre d'application sur Supabase restauré**
1. Vérifier que la migration hardening est appliquée.
2. `backup_db.ps1`.
3. Répétition locale (point 2 ci-dessus).
4. CI vectorielle (point 3) au vert.
5. Application.

**Correspondance avec les 18 tables V2**

| Table V2 | Décision | Objet réel |
|---|---|---|
| users | réutilisée | auth.users, profiles, user_roles ; nouvelle `soulbah.user_settings` (max_parallel_agents, plafond, budget) |
| sessions | nouvelle | objectif, statut, environnement, plafond L0–3, max_parallel_agents, budget, plan, `plan_version` |
| agents | nouvelle + réutilisée | `soulbah.agents`, `soulbah.runtimes` (FK agent_keys) ; agent_keys + kind, scopes, expires_at, capabilities, last_seen_at |
| tasks | nouvelle | `soulbah.tasks` (10 états, attempt, lease_owner, lease_expires_at, idempotency_key, acceptance_criteria, simulated). Sur agent_tasks : colonnes nullables `v2_task_id`, `target_agent_key_id`, `claimed_by_key_id`, et index de poll |
| task_dependencies | nouvelle | (task_id, depends_on_task_id, kind) + trigger anti-cycle |
| messages | nouvelle | 9 types ; chat_messages intacte |
| actions | nouvelle | états planned…verified/simulated, clé d'idempotence unique ; agent_events reste la télémétrie V1 |
| tool_calls | nouvelle | appels d'outils et de modèles : exit_code, http_status, tokens, coût, fournisseur |
| knowledge_documents | réutilisée | Voir le détail ci-dessous. |
| knowledge_chunks | nouvelle | FK knowledge_base, tsvector généré, `embedding vector` sans dimension, embedding_model, HNSW partiel par modèle, GIN |
| memories | réutilisée | agent_memory + session_id, scope, source_task_id, evidence_ids, confidence, validated_by/at, expires_at, is_simulation. CHECK `NOT VALID` : validated exige une preuve ou un validateur. Les anciennes lignes 'validated' écrites par l'évaluateur sont lues comme 'proposed', sans modification de données. |
| skills | nouvelle | name, version, schéma, procédure, permissions, exemples, erreurs connues, tests ; UNIQUE(name, version) ; alimentée par le catalogue |
| evaluations | nouvelle | critères, résultats, verdict, preuves, `action_taken` |
| checkpoints | nouvelle | task, attempt, seq, step_cursor, variables |
| recordings | nouvelle | durée, fps effectif, probe |
| artifacts | nouvelle | sha256 unique par utilisateur, mime, taille, URI, classe de rétention |
| permissions | nouvelle | grants, demandes, niveau, payload présenté, décideur, expiration |
| audit_logs | nouvelle | ajout seul et chaîné (prev_hash/row_hash) ; UPDATE et DELETE refusés par trigger ; aucune purge |

**Détail de `knowledge_documents`.** On réutilise `knowledge_base` en ajoutant source_uri, mime, ingest_status, embedding_model, last_written_at et **`doc_status` nullable, sans valeur par défaut** (CHECK `NOT VALID` : finding, user, validated, rejected, deprecated).
- La vue `soulbah.knowledge_documents` dérive le statut des lignes héritées sans les modifier : `category='recherche'` donne **finding** (non validé), le reste donne **user**.
- Les nouvelles écritures fixent le statut explicitement : une recherche produit un finding, et une entrée ne devient `validated` qu'après une revue avec preuves.
- Le RAG « connaissance validée » exclut les findings.

**Tables supplémentaires** : `soulbah.resource_leases`, `soulbah.audit_chain_head`.

**Fichiers de migration**
- Premier fichier : `20261015000000_v2_schema.sql`. Il crée le schéma `soulbah`, révoqué pour anon et authenticated et non exposé à PostgREST.
- Suivent 11 fichiers par groupe de tables.
- Le dernier fichier :
  - recrée `agent_tasks_set_updated_at`, pour qu'un `control` identique ne rafraîchisse plus le bail (changement de comportement, aucune donnée touchée) ;
  - ajoute `is_admin()` sans argument, puis `REVOKE has_role FROM anon` uniquement.

**Changements de policy du LOT 4.** agent_keys et agent_memory passent en SELECT (+ DELETE) pour le client, après un grep confirmant qu'aucun code `src/` n'écrit dans ces tables.

**Seconde vague, conditionnée au front déployé**
- G1 : retrait de l'INSERT client sur system_logs.
- G2 : retrait du DELETE client sur agent_tasks (l'UI passe par `/cancel`).
- G3 : knowledge_base en lecture seule pour le client.
- G4 : `REVOKE has_role FROM authenticated`.
- G5 : policies d'INSERT qui vérifient la propriété (chat_messages, knowledge_versions).
- G6 : `VALIDATE` des CHECK.

**Jamais**
- Modifier le CHECK de statut d'`agent_tasks`.
- Renommer `agent_tasks` ou `agent_events`.
- Changer la dimension de l'embedding en place.
- Ajouter une FK sur `agent_events.task_id`.
- Exécuter `RESTAURATION_BASE.sql` sur le projet existant.
- Supprimer `modules_status` (seulement marqué déprécié).

## 13. Ordre d'implémentation recommandé

**Préalables, avant tout code**
1. Pousser `main` vers `origin`.
2. Restaurer Supabase, puis lancer `backup_db.ps1` immédiatement.
3. Fusionner `restructure` (a24b7bd), en coordination avec les équipes node-api et `src/`.
4. Garder l'agent en mode `confirm` jusqu'à la fin du LOT 1.

**Socle de non-régression à chaque lot** : les 297 tests existants.

| LOT | Livrables | Critères de sortie vérifiables |
|---|---|---|
| 1. Sécurité et défauts confirmés | **Agent** : workspace hors dépôt, deny-list, téléphone sous verrou, options git refusées, validation hotkey/mouse, plans vides refusés, stop → `cancelled`, dry-run sans vraies tâches ni mémoire, 404/410 → abandon, outbox corrigée. **Serveur** : compactStep corrigé, 3 dernières captures, `action_taken`, mémoires `proposed`, `/cancel`, `/demos` → 501. **Configuration** : IA_SERVICE_TOKEN, HOST=127.0.0.1, requests ≥ 2.32.4. | sim.py → 1 exécution dans les scénarios (a) et (b). sim2.py → plus de `completed`. En mode auto, la sonde refuse `read_file backend/.env`, `write_file agent/permissions.py` et `phone_tap`. PoC du hook refusé. pytest agent ≥ 171. vitest au vert, `tsc` propre. |
| 2. Contrat d'outils unique | Manifestes ; catalogue consommé par agentSteps, compactStep et reasoning. | `--check` renvoie 0 ; une dérive injectée renvoie 1. Un `start_recording_bg` planifié est accepté par le serveur **et** par l'agent. |
| 3. Base locale, auth de dev, CI | `scripts/dev_db` (stub vectoriel), dev-local, FakeProvider, Fastify inject sur pg. CI poussée : `tsc` racine, job `db` épinglé sur la version Supabase, windows-latest, police PDF. | Un run CI vert, avec son URL. Migrations ×2 sans erreur, en local et en CI. Test HTTP poll/claim/409 réussi. |
| 4. Schéma V2 additif | Les 12 migrations ; restauration et types régénérés. | Application idempotente. `soulbah.*` refusé à authenticated. Le trigger refuse le cycle A → B → A. UPDATE/DELETE d'audit refusés. Suites V1 vertes. |
| 5. Model Router v2 | CompletionResult, profils, capacités, disjoncteur, allowlist des overrides, deadline, métrage dans `tool_calls`, budgets. | ≥ 25 nouveaux tests, sans appel payant. La vision n'est jamais routée vers un modèle non-vision. Un override inconnu renvoie 400. |
| 6. Sécurité et audit | L0–L3, approbations HMAC liées au payload, rédaction, audit chaîné, DPAPI, ApprovalsInbox. | Politique testée pour chaque outil du catalogue. `verifyChain` détecte une altération. Le secret canari est absent des lignes, des logs et des prompts. |
| 7. Sessions, file, scheduler, bus | Machine à états, SQL clôturé, SKIP LOCKED, classes de ressources, reaper, 9 messages, routes runtime, SSE. | 6 workers factices, 1 000 entrelacements : 0 double bail. RUNNING ≤ max pour 1, 3 et 6. Toutes les transitions du §9.4 testées, aucune autre acceptée. |
| 8. Runtime + packaging | Superviseur, sous-processus, Job Objects (breakaway pour open_app), journal, legacy_adapter, lancement à l'ouverture de session, poignée de main de version. | Kill d'un worker → reprise sans rejouer d'étape non idempotente. Kill du superviseur → 0 doublon. Un arbre bloqué est tué en < 10 s. Un runtime de version incompatible est refusé. |
| 9. Tool Gateway et preuves | Toutes les skills enveloppées, preuves typées, artefacts, `sandbox_exec`. | Preuve conforme au schéma pour chaque outil. 0 base64 en base. Un appel L2 sans grant passe en WAITING, puis reprend une seule fois. |
| 10. Évaluation, QA, chaos | DSL de critères, VALIDATING durable, qa_reviewer. | Un run simulé ou vide n'est jamais COMPLETED. node tué en VALIDATING → une seule évaluation. PG coupé 2 min → 0 doublon. |
| 11. Planner et orchestrateur | Gabarits, `validateDag`, approbation du plan, pont `/api/agent/goal`, `/demos` via gabarit. | Tests golden : cycles, rôles inconnus, niveaux trop élevés, chemins hors workspace et critères manquants refusés. Modules de formation exécutés en parallèle (horodatages qui se chevauchent). |
| 12. Ordinateur, navigateur, VS Code, worktrees | desktop_operator (UIA, DPI), Playwright, CLI `code`, git_workspace, rôle codeur. | Scénario Notepad vérifié par sha256 et UIA, < 2 s par itération. 3 codeurs en worktrees, merge avec tests verts. `branch -D` refusé sans L3. |
| 13. Mémoire et RAG | Chunks, ingestion, RRF, rerank, écrivain unique, mémoire de session. | **Dans le job CI `db`** (pgvector, version Supabase), sur un corpus étiqueté à embeddings précalculés : Recall@5 hybride supérieur au vecteur seul et au FTS seul. Mémoire rejetée jamais renvoyée. Une entrée créée dans l'UI est retrouvable. Findings exclus du RAG validé. |
| 14. Vidéo, enregistrement, recherche | soulbah_media, video_editor, `recordings`, TTS via le routeur, sources datées. | Durée enregistrée à ±5 % du temps réel. Chaque export passe la probe h264/aac. URL citées ⊂ URL récupérées. |
| 15. Dashboard, auto-amélioration, benchmarks | Pages Missions (x/6), Sidebar réelle, propositions → benchmark isolé → promotion L3, adaptateurs, vague G1–G6. Décisions documentées : hébergement de P1/P2 et sort de rust-compute. | E2E Playwright avec 6 agents. Rapport de benchmark stocké. Promotion impossible sans approbation. Plus aucune valeur factice (grep). |

## 14. Risques de régression

| Risque | Mitigation |
|---|---|
| Le statut `cancelled` est inconnu de l'UI et de l'évaluateur | Livrer AgentTasksPanel et agentGoal.ts dans la même version. |
| La whitelist resserrée casse des flux existants | Workspace créé automatiquement ; note de migration. |
| Le catalogue devient requis à l'exécution | Échec explicite au démarrage ; test de dérive bloquant. |
| Chat et embeddings passent par python-ia | Drapeau gardant l'ancien chemin jusqu'à la parité. |
| Le SSE dépend de LISTEN (pooler :5432 obligatoire) | Avertissement au démarrage ; repli en polling testé. |
| Le Job Object tue des applications de l'utilisateur | Breakaway pour open_app ; test dédié. |
| L'agent V1 et le runtime tournent en même temps | Garde d'instance unique dans les deux lanceurs. |
| Deux sémantiques de clôture (V1 et V2) | Helpers séparés. Dans agentTaskSql.ts, la garde CAS V1 reste inchangée ; le seul ajout, `claimed_by_key_id`, est couvert par de nouveaux tests. |
| Écart entre PG18 local, Supabase et l'image CI | Vectoriel validé seulement dans la CI épinglée ; stub explicite en local. |
| RLS resserrée avant que le front ne migre | Vague G1–G6 conditionnée aux E2E. |
| Supabase restauré dans un état inconnu | Sauvegarde, répétition locale, contrôle de `convalidated`. |
| Le token python-ia obligatoire casse le lancement local | `SOULBAH_ENV=dev` dès le LOT 1. |
| Conflits avec restructure | Fusionner restructure d'abord ; code neuf dans `src/v2/`. |
| Passage à Opus 5.5 | max_tokens adaptés au thinking ; détection de troncature avant la migration. |

## 15. Stratégie de tests

**Principe** : chaque lot se termine sur des preuves, sans appel LLM payant automatique. Les 297 tests existants sont un plancher.

1. **Unitaires**
   - Node (vitest) : machine à états (exhaustive selon le tableau du §9.4), `validateDag`, politique, rédaction, chaîne d'audit.
   - Agent (pytest, avec `SOULBAH_NO_DOTENV`) : CancelToken, verrous, journal, jetons d'approbation, deny-list.
   - python-ia : routeur testé avec FakeProvider.
2. **Contrats** : mêmes fixtures golden validées par ajv et jsonschema ; `gen_catalog.py --check` bloquant.
3. **Intégration DB**
   - PG18 local avec stub vectoriel pour tout ce qui n'est pas vectoriel.
   - Job CI `db` avec pgvector épinglé sur la version Supabase pour le vectoriel.
   - Migrations ×2, RLS testée par `SET ROLE`, SKIP LOCKED multi-clients, immutabilité de l'audit.
4. **Routes** : Fastify inject avec un JWT de dev.
5. **Runtime** : faux plan de contrôle, 6 workers, kills, réconciliation. sim.py, sim2.py, la sonde du gate et le PoC du hook deviennent des tests permanents.
6. **Contrôle de l'ordinateur en sandbox sûre**
   - Uniquement dans le workspace dédié, sur des applications témoins.
   - Session `simulated`, qui n'écrit jamais de mémoire.
   - Secret canari placé hors workspace ; kill switch par Job Object.
   - `pytest -m desktop` lancé à la main avant chaque version, à partir du LOT 12 ; job windows-latest en CI.
7. **Chaos** (LOT 10) : attendu 0 doublon et 0 rejeu d'étape non idempotente.
8. **Front et sécurité** : `tsc` et E2E Playwright sur la pile locale ; fixtures d'injection qui doivent aboutir à une approbation ou à un refus, jamais à une action L2/L3 exécutée.
9. **Benchmarks (LOT 15)**
   - `benchmarks/missions`, rejoués avec FakeProvider en CI et sur matériel réel pour un sous-ensemble.
   - Indicateurs : réussite **vérifiée**, coût, durée, retries.
   - Le même banc sert à juger les propositions d'auto-amélioration.

## Annexe : ce qui n'a pas pu être vérifié

**Base et environnement**
- **Supabase en pause.** Inconnus : l'application réelle de la migration hardening, les contraintes `NOT VALID` restantes, la version majeure de Postgres et les limites du pooler. Le schéma n'a été vérifié que sur un PG18 jetable avec stubs. pgvector y est absent (ni extension, ni binaire Windows, ni MSVC), donc aucune requête vectorielle n'a été exécutée.
- **Aucun parcours de bout en bout.** La qualité du planner et de l'évaluateur n'est pas mesurée, faute d'appel LLM payant.
- **Docker et Rust absents.** Les images, compose et rust-compute n'ont jamais été construits.
- **CI jamais exécutée.** Les comportements sous Ubuntu et sous un runner Windows, ainsi que la branche Python 3.12, ne sont pas reproduits. Le crash PDF sous Linux est démontré par simulation.

**Matériel et outillage**
- **Matériel.** Resolve, le téléphone, le multi-écran, le DPI élevé et les effets réels de la souris et du clavier n'ont pas été exercés.
- **Pile V2 non installée** (uiautomation, Playwright, keyring, psutil). La disponibilité de Windows Sandbox n'est pas vérifiée.
- **Front.** L'audit npm de la console n'a pas été relancé. `vite build` n'a pas été exécuté, car il écrirait dans `dist/`.

**Travaux en cours**
- Les travaux annoncés comme en cours sont absents du disque ; leurs effets sont déjà dans `d542f65`.
- Le travail non commité ailleurs est invisible. La worktree `restructure` (a24b7bd) n'a été lue qu'en lecture seule.
- Les références `fichier:ligne` sont celles de `d542f65`. Elles pourront se décaler après la fusion de restructure (`src/` → `frontend/src`).
