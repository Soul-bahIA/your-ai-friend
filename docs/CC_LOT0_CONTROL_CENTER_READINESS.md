# SOULBAH CONTROL CENTER — READINESS REPORT

LOT 0 de la mission « Soulbah Control Center ». Audit seul, réalisé le 2026-10-02 sur le dépôt au commit
`f98bcd3` (fin du V3 LOT 4 + 6) et sur le PC de développement. Aucune protection n'a été désactivée, aucun
droit de production n'a été donné, aucun système parallèle n'a été créé.

Ce rapport est le premier de trois. Les deux autres missions reçues le même jour le complètent :

- `docs/AUTONOMY_LOT0_PROJECT_INTELLIGENCE_READINESS.md` : Soulbah face à 224Solutions et 224Connect,
  dépendances aux IA externes, fonctionnement hors ligne, Project Brain, **plan de migration unifié** des trois
  missions ;
- `docs/INTELLIGENCE_BASELINE_REPORT.md` : mesures actuelles, domaine par domaine.

## Légende

| Statut | Sens |
|---|---|
| `EXISTS + WORKS` | Présent et vérifié |
| `EXISTS INCOMPLETE` | Présent, mais une partie de ce que demande la mission manque |
| `EXISTS DEFECTIVE` | Présent, mais ne fait pas ce qu'il annonce |
| `ABSENT` | Rien d'utilisable |

Nature des preuves : **[T]** test automatisé vert aujourd'hui ; **[R]** essai réel aujourd'hui sur cette
machine ; **[C]** lecture du code seulement, non exécuté.

Suites de tests vertes aujourd'hui : agent 792, python-ia 473, node-api 387 tests unitaires et 57 tests
d'intégration sur PostgreSQL réel, frontend 194.

## Synthèse

- **Le noyau d'exécution est solide.** Orchestration V2 (sessions, DAG, scheduler, baux, reprise), niveaux de
  sécurité L0 à L3, approbations liées à l'empreinte de l'action, journal d'audit chaîné, preuves typées,
  worktrees git, mode hors ligne réel, file d'inférence et limitation par la RAM : tout cela fonctionne et
  servira de base au Control Center.
- **La gouvernance est presque absente.** Pas de rôle PDG ni Super Admin, un seul contrôle « admin » dans toute
  l'API, pas de double authentification, pas d'arrêt d'urgence global, pas de SAFE MODE, pas de moteur de
  politiques par permission et par environnement. Les garde-fous existent mais se règlent par fichier ou
  variable d'environnement, sans écran, sans historique et sans audit de leurs changements.
- **Des réglages annoncés n'ont aucun effet** (défauts à corriger en premier) : plafond de sécurité par
  utilisateur ignoré, interrupteur d'auto-amélioration jamais vérifié, budgets par session jamais comptés,
  version des rôles non enregistrée.
- **Aucun agent de sécurité et aucune intégration 224.** Le code principal de 224Solutions n'est pas sur cette
  machine. 224Connect est présent localement, mais sans dépôt git.
- **Risque immédiat découvert pendant l'inventaire** : des clés semblent stockées en clair dans deux fichiers du
  Bureau (section 21). Aucune valeur n'a été lue ni recopiée.

---

## 1. Architecture actuelle

```text
frontend (React + Vite, connexion locale ou Supabase Auth)
   │  REST + SSE
P1 node-api (Fastify) ── plan de contrôle, seul écrivain des schémas public et soulbah
   │   sessions, DAG, scheduler, baux, approbations, audit chaîné, preuves, artefacts,
   │   ressources (V3 LOT 6), capacités et modes (V3 LOT 1), chat, base de connaissances
   │
P2 python-ia (FastAPI) ── routeur de modèles : local d'abord, cloud seulement en HYBRID ;
   │   file d'inférence par serveur local ; planification, évaluation, rédaction
   │
serveur de modèle local llama.cpp (qwen2.5-1.5b) ── partagé par tous les agents
   │
P3 agent (Python, Windows) ── boucle V1 ou runtime V2 (superviseur + workers en Job Object,
       journal SQLite), 39 outils (fichiers, terminal, git, bureau, navigateur, vidéo, voix, téléphone),
       approbations, coffre DPAPI, NetworkGuard
PostgreSQL 18 local (développement) ; Supabase cloud en pause
```

| Composant | Statut | Preuve |
|---|---|---|
| Plan de contrôle node-api | `EXISTS + WORKS` | [T] 387 + 57 tests ; [R] ordres traités aujourd'hui |
| Routeur de modèles python-ia | `EXISTS + WORKS` | [T] 473 tests ; [R] plans produits par le modèle local |
| Runtime agent V1 et V2 | `EXISTS + WORKS` | [T] 792 tests ; [R] fichier écrit sur ordre, mission de 6 agents |
| Modes OFFLINE / LOCAL_INTERNET / HYBRID et NetworkGuard | `EXISTS + WORKS` | [T] ; [R] toute la session d'aujourd'hui en OFFLINE |
| Interface web | `EXISTS INCOMPLETE` | [C] aucune page pour les missions V2, les ressources, les rôles ou les garde-fous |

## 2. Agents existants

Il existe **7 rôles V2 versionnés**, codés en dur dans `backend/node-api/src/v2/planner/roles.ts:27-84`
(copie publiée : `shared/roles/roles.json`). Chaque tâche lancée crée un agent logique dans la table
`soulbah.agents`. La V1 a en plus 15 « étiquettes d'agents » de routage (`backend/python-ia/app/agents.py:14-30`),
dont seules la recherche, la connaissance et les ordres au PC déclenchent réellement quelque chose.

| Agent demandé par la mission | Équivalent actuel | Statut |
|---|---|---|
| Developer, Backend, Frontend | `coder` 1.1.0 (worktree, fichiers, terminal, git) | `EXISTS INCOMPLETE` : un seul rôle généraliste |
| QA, Reviewer | `qa_reviewer` 1.0.0, exécuté par node-api | `EXISTS + WORKS` [T] |
| Research | `researcher` 1.1.0 (lecture seule) | `EXISTS + WORKS` [T] |
| Computer | `desktop_operator` 1.2.0 | `EXISTS + WORKS` [T] |
| Video | `video_editor` 1.1.0 | `EXISTS + WORKS` [T] |
| Knowledge | `content_writer` 1.0.0 (rédaction par le modèle) | `EXISTS INCOMPLETE` |
| Architect, Database, Security, Evaluator, Watchdog, Supervisor | aucun | `ABSENT` |
| Création d'agents par le PDG | aucune table ni route de rôles | `ABSENT` |
| Fiche agent (modèle, réussites, échecs, ressources, version) | données dispersées (tâches, évaluations, `tool_calls`) | `ABSENT` comme vue |

Défaut constaté : la version du rôle n'est jamais enregistrée sur l'agent créé au moment du bail
(`scheduler.ts:258-262` n'écrit pas `role_version`, qui reste à 1.0.0). **`EXISTS DEFECTIVE`** [C].

## 3. Orchestrateur

| Élément | Statut | Preuve |
|---|---|---|
| Sessions, DAG validé (`validateDag`), approbation du plan, scheduler, baux, reaper, reprise après crash | `EXISTS + WORKS` | [T] intégration PostgreSQL ; [R] mission de 6 agents : 6/6 fichiers vérifiés en 32 s |
| Parallélisme borné (`max_parallel_agents`, slots du PC, RAM libre) | `EXISTS + WORKS` | [R] 1 worker à la fois sous 530 Mo libres |
| File d'inférence partagée par les agents | `EXISTS + WORKS` | [R] 6 inférences simultanées : 6/6, une seule à la fois |
| Boucle V1 « ordre → plan → action → évaluation » | `EXISTS + WORKS` | [R] ordre planifié hors ligne en 50 s, fichier réel écrit |
| Plan multi-agents proposé par le modèle local | `EXISTS DEFECTIVE` | [R] 0 plan accepté sur 4 essais ; la validation a tout refusé, rien d'invalide n'a été exécuté |
| Bus de messages typés entre agents (`soulbah.messages`) | `EXISTS + WORKS` | [T] |
| Messages structurés de type « finding » | `ABSENT` | — |

## 4. Permissions

| Élément | Statut | Preuve |
|---|---|---|
| Niveau de sécurité par outil (L0 lecture → L3 irréversible), dérivé du catalogue | `EXISTS + WORKS` | [T] `shared/tools/catalog.json` |
| Approbation L2 et L3 liée à l'empreinte du payload, jeton HMAC | `EXISTS + WORKS` | [R] approbation refusée sans empreinte, acceptée avec |
| Dossiers autorisés par PC, liste noire (`.env`, `.git`, `.ssh`, clés) | `EXISTS + WORKS` | [T] `v2/security/policy.ts:60-83` |
| Plafond de sécurité de la mission | `EXISTS + WORKS` | [T] `validateDag` |
| Plafond de sécurité de l'utilisateur (`user_settings.max_security_level`) | `EXISTS DEFECTIVE` | [C] jamais lu : la demande d'approbation code `userMaxLevel: "L3"` en dur (`v2/routes/approvals.ts:144`) |
| Rôles applicatifs (`app_role` : admin, moderator, user) | `EXISTS INCOMPLETE` | [C] un seul contrôle admin dans l'API (`routes/knowledge.ts:11-18`) |
| Rôles PDG, Super Admin | `ABSENT` | — |
| Permissions nommées (`filesystem.write`, `terminal.execute`…) | `ABSENT` | les outils portent un niveau, pas une permission |
| Permissions par environnement (DEV ≠ PRODUCTION) | `ABSENT` | — |
| Permissions par agent | `EXISTS INCOMPLETE` | liste d'outils et plafond par rôle, codés en dur |

## 5. Garde-fous

| Catégorie | Ce qui existe | Statut |
|---|---|---|
| Filesystem | Dossiers autorisés, liste noire, niveaux, approbations | `EXISTS + WORKS` [T] |
| Terminal | `run_command` : liste fermée de programmes (git, npm, python, node, pytest) et de sous-commandes, dossier et chemins confinés à la liste blanche, confirmation humaine à chaque commande (`agent/skills/run_command.py`) | `EXISTS + WORKS` [T] ; un script lancé par l'agent n'est pas en bac à sable : la confirmation est la seule barrière |
| Database | Rôle `soulbah_api` à moindre privilège pour la base de Soulbah ; aucun outil d'agent vers une base tierce | `EXISTS + WORKS` pour Soulbah, sans objet ailleurs |
| Git | Worktree par tâche, fusion seulement après relecture QA et tests verts, push L3 toujours confirmé | `EXISTS + WORKS` [T] |
| Network | Modes et NetworkGuard (blocage réel en OFFLINE) | `EXISTS + WORKS` [T] ; pas de permission réseau par agent |
| Computer Control | Interrupteur `SOULBAH_COMPUTER_CONTROL`, saisies sur confirmation | `EXISTS + WORKS`, mais statique (redémarrage requis) |
| Production | Aucun outil de déploiement, aucun modèle d'environnement | `ABSENT` |
| Secrets | Coffre DPAPI de l'agent, masquage dans les journaux et l'audit | `EXISTS INCOMPLETE` : pas de secret par action, pas de rotation |
| Payments | Aucun outil de paiement | `ABSENT` (rien à protéger aujourd'hui) |
| Security | Approbations et audit ; aucune politique de scan | `ABSENT` |
| Self Improvement | Interrupteur `SOULBAH_SELF_IMPROVEMENT` | `EXISTS DEFECTIVE` : lu et validé au démarrage, jamais vérifié par les routes d'auto-amélioration |
| Agent Communication | Bus de messages typés, accusés de réception | `EXISTS + WORKS` [T] |
| Niveaux SAFE / STANDARD / ADVANCED / CUSTOM | — | `ABSENT` |
| Écran des garde-fous, historique, double validation | — | `ABSENT` : réglage par fichier ou variable, changements non audités |

## 6. Mémoire

`public.agent_memory` range des leçons (erreur, solution, pratique, optimisation) avec un statut proposé,
validé ou rejeté, et une revue dans l'interface (`AgentMemoryReview.tsx`). Le planificateur V1 y puise au plus
6 entrées marquées « données non fiables ».

| Élément | Statut | Preuve |
|---|---|---|
| Mémoire de leçons avec validation humaine | `EXISTS + WORKS` | [T] |
| Portée par projet, session ou utilisateur | `EXISTS DEFECTIVE` | [C] colonnes `project_id`, `scope`, `session_id` présentes mais jamais filtrées |
| Utilisation par le planificateur V2 | `ABSENT` | [C] |
| Research Memory, Project Memory, Security Memory | `ABSENT` (voir section 8 pour la recherche) | — |

## 7. Knowledge Base

| Élément | Statut | Preuve |
|---|---|---|
| Entrées, domaines, versions, restauration | `EXISTS + WORKS` | [T] |
| Recherche sémantique | `EXISTS INCOMPLETE` | [C] embeddings OpenAI seulement (refusés hors HYBRID) ; hors ligne, recherche plein texte |
| Embeddings locaux | `EXISTS INCOMPLETE` | modèle nomic-embed installé le 2026-10-01, pas encore branché |
| Index vectoriel local | `ABSENT` | pgvector absent du PostgreSQL local ; `soulbah.knowledge_chunks` jamais écrite |
| Fusion plein texte + vecteurs, reranking | `ABSENT` | — |
| Statuts ACTIVE / STALE / SUPERSEDED / INVALID | `ABSENT` | — |

## 8. Research system

`POST /api/research` consulte d'abord la base de connaissances (90 jours, confiance ≥ 0,6), sinon fait une
recherche web (Tavily, Serper ou Brave), une synthèse par le modèle, puis range le résultat avec ses sources.
Une source n'est marquée vérifiée que si la page a été réellement récupérée.

| Élément | Statut | Preuve |
|---|---|---|
| Cache « base de connaissances d'abord », provenance, `last_verified_at` | `EXISTS + WORKS` | [T] `services/research/index.ts:97-171` |
| Fonctionnement hors ligne | `ABSENT` par nature (Internet et clé de recherche requis) | — |
| Date par source, politique de fraîcheur, déduplication, historique consultable | `ABSENT` | — |

## 9. Self-improvement existant

`POST /api/agent/self-improve` analyse les 20 dernières tâches V1 et range des suggestions en mémoire
« proposée ». Rien n'est appliqué automatiquement.

| Élément | Statut |
|---|---|
| Suggestions à partir des échecs | `EXISTS + WORKS` [T] |
| Respect de l'interrupteur `SOULBAH_SELF_IMPROVEMENT` | `EXISTS DEFECTIVE` [C] |
| Version candidate, benchmark, comparaison, activation, rollback | `ABSENT` |
| Registre des skills (`soulbah.skills`) | `ABSENT` dans les faits : table créée, jamais écrite |

## 10. Security Agent existant

`ABSENT`. L'« agent sécurité » V1 n'est qu'une étiquette de routage vers la génération générique. Aucun
scanner ne tourne dans Soulbah. La CI du dépôt contient déjà npm audit, pip-audit, gitleaks et CodeQL
(`.github/workflows/ci.yml:312-352`, `codeql.yml`), mais **elle n'a jamais tourné sur le code actuel** : 31
commits locaux ne sont pas poussés sur GitHub.

## 11. Intégration 224Solutions

`ABSENT`. Aucune mention dans le dépôt Soulbah. **Le code principal de 224Solutions n'est pas sur cette
machine** : on y trouve seulement une fonction AWS Lambda d'authentification (`Desktop\224solutions-lambda\authGateway.mjs`,
sans dépôt git ni tests), un document de paiement vide et un document d'API au format RTF. Détail dans le
rapport Autonomie.

## 12. Intégration 224Connect

`ABSENT` dans Soulbah. Le projet est présent localement dans `Desktop\224` : PWA React, console d'administration,
API Fastify (TypeScript), service FastAPI (Python), deux projets Supabase (46 migrations, RLS sur toutes les
tables, 42 tests SQL), Redis. **Il n'a pas de dépôt git** : pas d'historique, pas de sauvegarde, et sa CI ne
peut pas tourner. Détail dans le rapport Autonomie.

## 13. Git

| Élément | Statut | Preuve |
|---|---|---|
| Worktree et branche `soulbah/<session>/…` par tâche, commit, fusion testée après relecture QA | `EXISTS + WORKS` | [T] `agent/skills/git_workspace.py` |
| Push et suppression de branche (L3, toujours confirmés, jamais forcés) | `EXISTS + WORKS` | [T] |
| Dépôt Soulbah publié | `EXISTS INCOMPLETE` | 31 commits en avance sur `origin/main` ; le push reste une action de l'utilisateur |

## 14. CI/CD

| Élément | Statut |
|---|---|
| CI : frontend, console, catalogue, node-api, python-ia, agent (Windows), base (migrations, politiques, droits, intégration), sécurité, CodeQL | `EXISTS INCOMPLETE` : jamais exécutée sur le code actuel |
| CD (déploiement) | `ABSENT` |

## 15. Environnements

| Élément | Statut |
|---|---|
| `SOULBAH_ENV` (dev, test, staging, production) appliqué à Soulbah lui-même : jetons inter-services, secret d'approbation, TLS, connexion locale interdite hors dev | `EXISTS + WORKS` [T] |
| Environnements cibles LOCAL / DEV / TEST / STAGING / PRODUCTION pour les actions des agents | `ABSENT` (`sessions.environment` est stocké mais jamais lu) |

## 16. Logs

| Élément | Statut |
|---|---|
| Journaux node-api (pino, en-têtes masqués), python-ia, agent (rotatifs, masqués), journal SQLite du runtime | `EXISTS + WORKS` |
| Audit V2 en ajout seul, chaîné par SHA-256, UPDATE et DELETE refusés, vérification par `/api/v2/audit/verify` | `EXISTS + WORKS` [T] |
| Audit des actions V1, des changements de configuration et de garde-fous | `ABSENT` |

## 17. Monitoring

| Élément | Statut |
|---|---|
| `/health`, `/health/deep`, `/api/v2/capabilities`, `/api/v2/resources`, flux SSE | `EXISTS + WORKS` [T] [R] |
| Historique de métriques, alertes, notifications au PDG | `ABSENT` |
| Surveillance de Soulbah par lui-même (superviseur, node-api, python-ia) | `ABSENT` |

## 18. Base de données

31 migrations. Schéma `public` (19 tables V1, RLS active) et schéma `soulbah` (19 tables et 2 vues V2,
accessibles seulement par node-api via le rôle `soulbah_api`). PostgreSQL 18 local en développement ; Supabase
cloud en pause.

| Élément | Statut |
|---|---|
| Migrations idempotentes, vérifications de schéma et de droits en CI | `EXISTS + WORKS` [T] |
| Tables créées mais jamais écrites : `soulbah.skills`, `soulbah.knowledge_chunks`, `soulbah.recordings` ; `user_settings` jamais écrite | `EXISTS INCOMPLETE` |
| Budgets `sessions.budget_usd`, `spent_usd`, `user_settings.daily_budget_usd` | `EXISTS DEFECTIVE` : jamais lus ni comptés |

## 19. Composants réutilisables

| Besoin du Control Center | Composant existant à réutiliser |
|---|---|
| Journal des changements de garde-fous | `soulbah.audit_logs` (chaîné, ajout seul) |
| Double validation des actions critiques | Approbations HMAC liées à l'empreinte (`v2/security/approvals.ts`), boîte d'approbations de l'interface |
| Policy Engine | Niveaux L0–L3, liste noire, plafonds de mission (`v2/security/policy.ts`, `validateDag`) |
| Arrêt d'urgence | Ordres `stop` du keepalive, annulation de session, Job Objects, révocation de clé |
| Watchdog | Détection de blocage, reaper, escalade, idempotence des actions |
| Peer review | `qa_reviewer`, critères sur preuves, relecture obligatoire avant fusion |
| Sandbox de correction | Worktrees git et fusion testée |
| Santé et ressources | `/health/deep`, capacités, `/api/v2/resources` |
| Preuves | Preuves typées, artefacts sha256 |
| Mode sûr de base | Mode OFFLINE, interrupteurs de l'agent |

## 20. Composants manquants

Interface Control Center ; rôles PDG et Super Admin avec double authentification et délai de session ; arrêt
d'urgence global ; SAFE MODE ; moteur de politiques (permissions nommées × agent × projet × environnement,
préréglages, historique, double validation) ; registre d'agents modifiable et versionné ; watchdog
(boucles, actions répétées, plafond d'appels d'outils, quarantaine) ; agent de sécurité, scanners et pipeline
de findings ; mémoires de recherche, de projet et de sécurité ; registre de skills ; pipeline
d'auto-amélioration avec rollback ; registre des projets et de leurs environnements ; moteur de régression ;
garde de production ; notifications.

## 21. Risques

1. **Secrets en clair sur le Bureau (critique).** L'inventaire a détecté, sans les ouvrir, des motifs de clés
   dans `Desktop\224connect` (fichier texte : jetons JWT, probablement la clé `service_role` de Supabase) et dans
   `Desktop\API 224solutions.rtf` (`client_secret`). Le dossier `Desktop\224\.claude\` contient aussi un
   `.credentials.json`. Il faut faire tourner ces clés et les ranger dans un coffre. Soulbah ne doit jamais
   indexer ces fichiers.
2. **224Connect sans contrôle de version.** Aucune correction en worktree, aucun historique, aucune
   sauvegarde. À mettre sous git avant toute autre étape.
3. **Code de 224Solutions absent.** Sans le dépôt, aucune analyse ni surveillance n'est possible.
4. **Identité.** La connexion locale repose sur un seul jeton lié à un seul utilisateur, sans double
   authentification. C'est acceptable en développement, pas pour un Control Center (« pas de compte admin
   partagé »).
5. **Usage offensif.** Un agent de sécurité qui scanne et « vérifie » peut dériver vers l'attaque. Il faut une
   liste fermée de projets et d'hôtes autorisés, aucune génération d'exploit, une vérification seulement sur
   copie ou environnement de test.
6. **Injection par le code analysé.** Les commentaires, documents et pages lus par les agents doivent rester
   des données, jamais des instructions (déjà appliqué au chat et à la mémoire, à généraliser).
7. **Qualité du modèle local.** Le modèle de 1,5 milliard de paramètres échoue à planifier des missions
   multi-agents (0 sur 4) et à un calcul simple du banc d'essai. Le tri de sécurité doit reposer sur des règles
   et des tests, le modèle seulement sur le résumé.
8. **Matériel.** 8 Go de RAM, environ 0,5 Go libre avec les applications ouvertes, pas de GPU. La vitesse
   tombe de 11,5 à 2 à 5 jetons par seconde quand toute la pile tourne.
9. **Faux positifs** des scanners : déduplication et validation humaine nécessaires.
10. **CI jamais exécutée** : les contrôles de sécurité existants n'ont jamais tourné sur le code actuel.

## 22. Migrations nécessaires

Toutes additives et idempotentes, comme celles de la V2 :

- rôles `pdg` et `super_admin` (ou table `soulbah.admin_roles`), sessions d'administration avec expiration ;
- `soulbah.system_state` : arrêt d'urgence, SAFE MODE, interrupteurs maîtres (Internet, IA externes,
  production, auto-amélioration, Security Autopilot), avec version ;
- `soulbah.policies`, `soulbah.policy_versions`, `soulbah.policy_changes` (ancien, nouveau, auteur,
  justification, date) ;
- `soulbah.agent_definitions` et `soulbah.agent_versions` (alimentées au départ par les 7 rôles actuels) ;
- `soulbah.projects`, `soulbah.project_environments`, `soulbah.project_baselines` ;
- `soulbah.findings`, `soulbah.finding_events` (chronologie), `soulbah.security_patterns` ;
- `soulbah.research_records` et colonnes de provenance, de fraîcheur et de statut sur la connaissance ;
- `soulbah.skills` (déjà créée) complétée par versions et preuves ;
- `soulbah.improvement_candidates`, `soulbah.benchmark_runs`, `soulbah.activations` (rollback) ;
- `soulbah.notifications`.

## 23. Fichiers à modifier

| Fichier | Modification |
|---|---|
| `backend/node-api/src/auth.ts` | Rôles d'administration, garde des routes du Control Center, expiration des sessions |
| `backend/node-api/src/v2/security/policy.ts` | Devient le cœur du moteur de politiques (permissions, environnements, préréglages) |
| `backend/node-api/src/v2/routes/approvals.ts` | Appliquer le plafond de l'utilisateur au lieu de L3 en dur |
| `backend/node-api/src/v2/planner/roles.ts`, `validateDag.ts` | Lire le registre d'agents au lieu de la liste codée en dur |
| `backend/node-api/src/v2/scheduler/scheduler.ts` | Arrêt d'urgence et SAFE MODE ; enregistrer `role_version` |
| `backend/node-api/src/routes/agentMemory.ts` | Respecter l'interrupteur d'auto-amélioration |
| `agent/permissions.py`, `agent/executor.py`, `agent/runtime/supervisor.py` | Politique compilée reçue du serveur, arrêt d'urgence, environnement de la tâche |
| `shared/tools/catalog.json` (via `scripts/gen_catalog.py`) | Nom de permission par outil |
| `frontend/src/App.tsx`, `Sidebar.tsx` | Section Control Center réservée aux rôles d'administration |

## 24. Nouveaux composants proposés

Control Center (interface) ; Trusted Core (identité, moteur de politiques, arrêt d'urgence, audit) ; registre
d'agents ; watchdog et superviseur ; agent de sécurité défensif avec adaptateurs de scanners ; pipeline de
findings ; registre des projets 224 ; mémoires (recherche, projet, bugs, solutions, sécurité, décisions) ;
registre de skills ; laboratoire d'amélioration avec rollback ; garde de production ; service de
notifications. La conception détaillée est dans le plan unifié du rapport Autonomie.

## 25. Architecture finale recommandée

Garder le Split-Plane et ajouter un **Trusted Core** dans node-api, que les modèles ne pilotent jamais :

```text
PDG / Super Admin (identité propre, double authentification)
        │
CONTROL CENTER (frontend, section réservée)
        │
TRUSTED CORE (node-api) : identité · moteur de politiques · interrupteurs maîtres · STOP SOULBAH ·
        │                 SAFE MODE · audit chaîné · approbations · registre d'agents et de modèles
        │
ORCHESTRATEUR V2 + superviseur + watchdog ── évaluateur et relecture croisée
        │
AGENTS (registre) ── chaque action passe par la passerelle d'outils : politique → permission → exécution
        │
python-ia (routeur local, file d'inférence) · runtime agent (worktrees, sandbox)
        │
PROJETS ENREGISTRÉS (224Solutions, 224Connect) par environnement : LOCAL → DEV → TEST → STAGING → PRODUCTION
```

Règle de construction : un agent ne peut jamais modifier le Trusted Core, ses propres permissions ou
l'arrêt d'urgence ; seule une identité humaine habilitée le peut, avec double validation pour les
politiques critiques.

## 26. Ordre exact des prochains lots

Les trois missions reçues le 2026-10-02 se recouvrent largement, et leurs ordres de lots diffèrent. Le
**plan unifié** est dans `docs/AUTONOMY_LOT0_PROJECT_INTELLIGENCE_READINESS.md`, section « Migration Plan ».
Il commence par le Trusted Core minimal (identité PDG, arrêt d'urgence, interrupteurs maîtres, correction des
défauts ci-dessus), parce que tout ce qui suit donne à Soulbah plus de connaissance et plus d'autonomie : les
freins doivent exister avant.

**En attente de validation avant le LOT 1.**
