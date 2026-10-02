# SOULBAH AUTONOMY & PROJECT INTELLIGENCE READINESS REPORT

LOT 0 de la mission « Extension maître : Soulbah devient l'IA technique autonome de 224Solutions et
224Connect ». Audit seul, le 2026-10-02, sur le dépôt Soulbah au commit `f98bcd3` et sur les dossiers 224
présents sur ce PC, en lecture seule. Aucun fichier de configuration (`.env`), de clés ou de paiement n'a été
ouvert ; aucune valeur secrète n'a été lue ni recopiée.

Rapports liés, produits le même jour : `docs/CC_LOT0_CONTROL_CENTER_READINESS.md` (gouvernance, détail des
26 points) et `docs/INTELLIGENCE_BASELINE_REPORT.md` (mesures). Ce rapport contient le **plan de migration
unifié** des trois missions.

Légende : `EXISTS + WORKS`, `EXISTS INCOMPLETE`, `EXISTS DEFECTIVE`, `ABSENT`. Preuves : **[T]** test
automatisé vert aujourd'hui, **[R]** essai réel aujourd'hui, **[C]** lecture seule.

## Niveau d'autonomie actuel

Sur l'échelle de la mission, Soulbah est au **niveau B** : il fonctionne localement (session entière
d'aujourd'hui en mode OFFLINE, sans aucune IA externe) mais il **ne connaît pas du tout** 224Solutions ni
224Connect. Il peut atteindre le niveau C dès que le Project Brain existe. Le niveau D (correction autonome en
sandbox) demande un modèle de code plus fort que celui installé.

---

## Soulbah

| Domaine | Statut | Constat |
|---|---|---|
| Architecture | `EXISTS + WORKS` | Split-Plane : node-api (contrôle), python-ia (modèles), agent (exécution), PostgreSQL local. [T] [R] |
| Agents | `EXISTS INCOMPLETE` | 7 rôles V2 codés en dur (coder, desktop_operator, researcher, video_editor, phone_operator, qa_reviewer, content_writer) ; ni Architect, ni Database, ni Security, ni Supervisor ; pas de registre modifiable. Agents ≠ modèles : déjà vrai, tous partagent un serveur. |
| Modèles locaux | `EXISTS INCOMPLETE` | Installés et vérifiés par empreinte : qwen2.5-1.5b-instruct Q4_K_M (1,04 Go, Apache-2.0) et nomic-embed-text v1.5 (0,14 Go, Apache-2.0, pas encore branché) ; moteur llama.cpp b11325 CPU. Ni modèle de code, ni vision, ni reranker, ni voix neuronale. |
| Routeur de modèles local | `EXISTS + WORKS` | Chaîne par rôle (spécialisé → général → petit), local d'abord, cloud jamais hors HYBRID, file d'inférence. [T] [R] |
| APIs externes | `EXISTS + WORKS` comme option | 7 fournisseurs cloud gérés, tous bloqués hors HYBRID (détail plus bas). |
| Mémoire | `EXISTS INCOMPLETE` | Leçons validées par l'humain (V1) ; portée par projet déclarée mais jamais appliquée ; ni mémoire de bugs, de solutions, de sécurité, ni de décisions. |
| Knowledge | `EXISTS INCOMPLETE` | Base versionnée ; recherche sémantique par embeddings OpenAI seulement, hors ligne plein texte ; aucun index vectoriel local. |
| Sécurité | `EXISTS + WORKS` pour l'exécution | Niveaux L0–L3, approbations liées à l'empreinte, audit chaîné, liste noire, coffre DPAPI, NetworkGuard. [T] [R] Pas de gouvernance (voir rapport Control Center). |
| Outils | `EXISTS + WORKS` | 39 outils au catalogue : fichiers (5), terminal (1), git (5), souris (6), clavier (2), fenêtres et applications (3), écran (2), vidéo (5), voix (1), web (1), téléphone (7), attente (1). Aucun outil d'analyse de code, de base de données ou de scan. |

## 224Solutions

**Le code de l'application 224Solutions n'est pas sur cette machine.** Recherche de dossiers « 224 » sur le
Bureau et dans Documents (profondeur 3) : seuls les éléments ci-dessous existent.

| Élément | Statut | Constat |
|---|---|---|
| Architecture, repository, modules, DB, APIs, UI, tests, CI/CD | `ABSENT` sur ce PC | Impossible à auditer sans le code. Les deux raccourcis du Bureau « 224Solutions - Taxi-Moto, Livraison & E-Commerce » pointent vers l'application, pas vers les sources. |
| `Desktop\224solutions-lambda\authGateway.mjs` | `EXISTS INCOMPLETE` | Fonction AWS Lambda de 173 lignes derrière API Gateway : valide des jetons Cognito, routes `/auth/validate-token`, `/auth/sync-profile`, `/auth/me` avec 2 TODO « Cloud SQL ». Pas de `package.json`, pas de dépôt git, pas de tests, pas d'infrastructure décrite. [C] |
| Sécurité visible de cette Lambda | `EXISTS DEFECTIVE` | D'après la lecture : CORS `*` ; la vérification JWT contrôle l'émetteur et RS256 mais pas l'audience, le client ni `token_use` ; le rôle vient de `custom:role` (à vérifier non modifiable par l'utilisateur) ; message d'erreur interne renvoyé au client ; runtime Node 20 annoncé, en fin de vie. À confirmer sur la version réellement déployée. [C] |
| `Desktop\224Solutions paiement\224Solutions.doc` | non ouvert | Document de paiement (règle : jamais de fichier financier). |
| `Desktop\API 224solutions.rtf` | non ouvert | Contient des motifs de secrets (`client_secret`), voir la section Risques. |

**Prérequis pour toute intelligence sur 224Solutions** : disposer du code (dépôts clonés sur ce PC ou sur une
machine du réseau local), avec un accès en lecture seule pour commencer.

## 224Connect

Le dossier `Desktop\224` est **224Connect** (son `README.md` le nomme ainsi : réseau social relié à
224Solutions par son API partenaire). Vérifié par lecture de la structure, sans ouvrir de configuration.

| Élément | Statut | Constat |
|---|---|---|
| Architecture | `EXISTS + WORKS` (code présent) | PWA React 18 + Vite 6 (`frontend/web`), console d'administration du PDG (`frontend/admin`), design system ; API Fastify 5 en TypeScript (`backend1`, paquet `@224connect/api-node`) ; service Python 3.12 FastAPI avec worker et scheduler (`backend2`, « intelligence ») ; Redis ; temps réel Ably, appels Agora, vidéo HLS. |
| Repository | `ABSENT` | **Aucun dépôt git** (ni à la racine, ni dans les sous-dossiers) : pas d'historique, pas de sauvegarde versionnée, CI impossible, corrections en worktree impossibles. |
| Modules backend1 | `EXISTS` | admin, calls, channels, comments, community, content, distribution, events, health, interactions, link224, lives, media, messaging, offers, payments, platform, posts, profiles, realtime, relations, stories, studio, training, videos, wallet. |
| Modules backend2 | `EXISTS` | accounts, feed, media, moderation, push, queue, storage, studio, tasks, security, worker. |
| UI web | `EXISTS` | Pages : accueil, profils, amis, stories, vidéos, recherche, notifications, appels, création, réglages ; domaines channels, community, creation, distribution, lives, messages, offers, payments, security, studio, training, wallet. |
| UI admin | `EXISTS` | Dashboard, Users, Moderation, Finance, Gifts, Channels, Lives, Community, Content, Reports, Audit, Team, Assistant, Announcements, PlatformSettings. |
| Domaines demandés absents du code | — | Musique, Artists, Boost/Ads, Copyright, Rights Manager, Recommandations (au sens d'un module dédié) : non trouvés. Wallet et paiements passent par 224Solutions (`link224` : webhooks HMAC-SHA256, idempotence). |
| Base de données | `EXISTS + WORKS` (à vérifier en exécution) | 2 projets Supabase (`base1-coeur`, `base2-activite`) : 47 fichiers de migration, 43 tests SQL ; RLS activée sur toutes les tables (relevé de l'inventaire) ; 785 définitions de fonctions SQL (redéfinitions comprises), dont 757 en SECURITY DEFINER, avec `search_path` fixé ; 71 policies, toutes dans base1 : base2 n'en a aucune (tout passe par la clé service et les fonctions). |
| APIs | `EXISTS` | Routes Fastify par module ; webhooks partenaires ; à cartographier (LOT 4). |
| Tests | `EXISTS` | backend1 ≈ 42 fichiers (Vitest et node:test), backend2 ≈ 26 (pytest), frontend ≈ 44 (Vitest), plus 43 tests SQL. Non exécutés dans cet audit. |
| CI/CD | `EXISTS INCOMPLETE` | Workflow `ci.yml` (lint, typage, tests, build) inactif faute de dépôt ; Dockerfiles non-root ; en-têtes HSTS, CSP et X-Frame-Options sur Vercel. |
| Sécurité visible | `EXISTS INCOMPLETE` | Points positifs : helmet, liste d'origines CORS, limitation de débit, masquage des journaux, MFA aal2 côté serveur pour l'admin. Manques : aucun scan de dépendances ni de secrets ; grande surface de fonctions SECURITY DEFINER à relire ; vrais fichiers `.env` dans le dossier (ignorés par git et Docker, mais exposés si le dossier est copié ou zippé) ; dossier `.claude` avec `.credentials.json` et historique de fichiers. |
| Taille | — | ≈ 650 fichiers source (TypeScript ≈ 430, Python ≈ 100, SQL ≈ 90). Réaliste à indexer sur ce PC. |

## Dépendances externes

Chaque endroit où Soulbah peut appeler une IA ou un service externe, et son comportement aujourd'hui.

| Usage | Service | Fichier | Hors HYBRID (OFFLINE, LOCAL_INTERNET) |
|---|---|---|---|
| Planification, évaluation, rédaction, grilles `llm_rubric`, synthèse de recherche | Anthropic, OpenAI, Google Gemini, Mistral, DeepSeek, xAI, Qwen | `backend/python-ia/app/providers/registry.py:33-68`, `anthropic_provider.py`, `router.py` | Fournisseurs cloud non construits, modèle local utilisé. [T] [R] |
| Chat de l'application | Mêmes fournisseurs | `backend/node-api/src/services/chatProvider.ts:19-49` | Modèle local seulement. [R] chat utilisé aujourd'hui |
| Embeddings de la base de connaissances | OpenAI `text-embedding-3-small` | `backend/node-api/src/services/knowledge/embeddings.ts:7-13` | Refusés ; repli plein texte (recherche dégradée). |
| Vision (captures d'écran) | Modèles cloud déclarés « vision » | `backend/python-ia/app/providers/capabilities.py` | Aucune vision ; l'évaluation juge sur le rapport seul (depuis le 2026-10-02). |
| Narration des vidéos de formation | OpenAI TTS | `backend/python-ia/app/video.py:45` | Refusée ; la voix locale SAPI existe dans l'agent mais n'est pas branchée sur ces vidéos. |
| Recherche web | Tavily, Serper, Brave (pas des IA) | `backend/node-api/src/services/research/webSearch.ts` | Indisponible en OFFLINE ; autorisée en LOCAL_INTERNET. |
| Connexion des utilisateurs | Supabase Auth (cloud) | `frontend/src/integrations/supabase/client.ts`, `backend/node-api/src/auth.ts` | Connexion locale `dev-local` (développement seulement). |
| Base de production | Supabase PostgreSQL (en pause) | `backend/.env` | PostgreSQL 18 local. |
| Police de l'interface | Google Fonts | `frontend/src/index.css:1` | Polices système. |

Aucune fonction ne dépend **obligatoirement** d'une IA externe en mode OFFLINE. La distinction demandée entre
« Internet » et « IA externes » existe déjà sous forme de mode (LOCAL_INTERNET = Internet sans IA cloud), mais
pas encore comme deux interrupteurs indépendants pilotés depuis le Control Center.

## Offline readiness

| Fonction | Sans Internet | Preuve |
|---|---|---|
| Chat avec le modèle local | Fonctionne | [R] conversation de l'utilisateur aujourd'hui |
| Ordre → plan → action → évaluation (un agent) | Fonctionne, 50 à 94 s de planification | [R] |
| Mission multi-agents avec plan fourni ou gabarit | Fonctionne | [R] 6/6 |
| Mission multi-agents planifiée par le modèle local | Ne fonctionne pas (0/4) | [R] |
| Approbations, audit, preuves, worktrees, ressources | Fonctionne | [T] [R] |
| Recherche dans la base de connaissances | Dégradée (plein texte seulement) | [C] |
| Vision, narration vidéo, recherche web | Cassées | [C] |
| Pages de l'interface qui lisent Supabase directement | Vides | [R] constat du 2026-10-01 |
| Génération de formations et d'applications par le modèle local | Non vérifiée | — |

## Project Brain readiness

| Brique | Statut | Existant réutilisable |
|---|---|---|
| Project Registry (projets, chemins, environnements) | `ABSENT` | Dossiers autorisés par PC, `sessions.environment` (inutilisé) |
| Indexeur de code (fichiers, symboles, AST) | `ABSENT` | `typescript` dans les dépendances de node-api, module `ast` de Python |
| Index lexical | `EXISTS INCOMPLETE` | Recherche plein texte PostgreSQL de la base de connaissances |
| Index vectoriel local | `ABSENT` | Modèle nomic-embed installé ; pas de pgvector local |
| Code Knowledge Graph, impact analysis | `ABSENT` | — |
| Database Intelligence | `ABSENT` | Les contrôles de schéma de la CI de Soulbah (`scripts/ci/schema_checks.sql`, `check_api_grants.py`) donnent des modèles de requêtes |
| API Intelligence | `ABSENT` | — |
| UI / User Flow Intelligence | `ABSENT` | — |
| ProjectWatcher incrémental, Git Memory | `ABSENT` | Outils git de l'agent ; **224Connect n'a pas de git** |
| Bug, Solution, Security, Architecture Decision Memory | `ABSENT` | Mémoire de leçons V1 avec validation humaine |
| Research Memory | `EXISTS INCOMPLETE` | Recherche avec provenance et `last_verified_at` |
| KnowledgeGapDetector, couverture réelle (%) | `ABSENT` | — |
| Documentation hors ligne des technologies | `ABSENT` | — |

## Control Center

Ce qui existe : boîte d'approbations, lecture et vérification de l'audit, badge de mode, état des services,
cockpit d'une tâche V1 (pause, reprise, arrêt). Ce qu'il faut ajouter : tout le reste (rôles PDG, STOP
SOULBAH, SAFE MODE, interrupteurs maîtres séparés Internet / IA externes / production / auto-amélioration /
Security Autopilot, politiques immuables, garde-fous versionnés, pages 224Solutions et 224Connect, agents,
modèles, mémoire, recherches). Détail point par point dans `docs/CC_LOT0_CONTROL_CENTER_READINESS.md`.

## Self Improvement

| Élément | Statut | À sécuriser |
|---|---|---|
| Suggestions d'amélioration à partir des échecs, rangées « proposées » | `EXISTS + WORKS` [T] | Seules les leçons validées doivent entrer dans la mémoire fiable (déjà vrai pour l'injection dans les plans). |
| Interrupteur `SOULBAH_SELF_IMPROVEMENT` | `EXISTS DEFECTIVE` [C] | Jamais vérifié par les routes : à faire respecter, puis à piloter depuis le Control Center (OFF, PROPOSE ONLY, LAB AUTO, SAFE AUTO). |
| Soulbah Lab (clone, candidat, benchmark, comparaison, activation, rollback) | `ABSENT` | Construire avant toute activation automatique. |
| Benchmarks réutilisables | `EXISTS INCOMPLETE` | Banc de 5 tâches du modèle local, tests de chaos, essais réels de ce jour. |
| Trusted Core protégé des modifications par les agents | `ABSENT` | Les politiques sont dans des fichiers que l'agent peut atteindre s'ils sont dans un dossier autorisé : à isoler. |

## Risques à traiter avant tout

1. **Secrets en clair** : `Desktop\224connect` (fichier texte, jetons de type JWT et probablement la clé
   `service_role` Supabase de 224Connect) et `Desktop\API 224solutions.rtf` (`client_secret`). Recommandation :
   faire tourner ces clés, les ranger dans un gestionnaire de secrets, supprimer les fichiers.
2. **224Connect sans git** : à mettre sous contrôle de version (dépôt local au minimum, dépôt privé ensuite).
3. **Code 224Solutions absent** : à fournir pour tout travail sur cette application.
4. **Modèle local trop faible pour coder et planifier seul** : mesures dans le rapport Intelligence.
5. **Mémoire vive** : environ 0,5 Go libre avec les applications ouvertes ; indexer, faire tourner un modèle
   et des agents en même temps imposera des files d'attente (déjà gérées) et de la patience.

---

## Migration Plan

Trois missions reçues le même jour proposent trois ordres différents (Control Center : 17 lots ; Extension :
20 lots ; Intelligence Lab : rapport de base puis chantier). Le plan ci-dessous les fusionne, ainsi que les lots
V3 restants (mémoire et RAG local, skills, auto-amélioration, tableau de bord, benchmarks), qui sont en pause.

**Différence assumée avec l'ordre de l'Extension** : je place un **Trusted Core minimal** en premier, avant le
Project Registry. Raison : tout ce qui suit donne à Soulbah plus de connaissance de vos applications et plus
d'autonomie. L'arrêt d'urgence, l'interrupteur « IA externes » et la correction des réglages sans effet doivent
exister avant. Ce lot est court et ne touche pas aux projets 224.

### Prérequis de votre côté (aucun code)

| N° | Action | Bloque |
|---|---|---|
| P1 | Faire tourner les clés exposées et supprimer les fichiers en clair | Rien techniquement, mais urgent |
| P2 | Mettre 224Connect sous git | Lots 7 et 12 et suivants |
| P3 | Fournir le code de 224Solutions | Tout le travail sur 224Solutions |
| P4 | Choisir l'identité du Control Center : comptes locaux avec double authentification (recommandé, fonctionne hors ligne) ou Supabase Auth réactivé | Lot 1 |
| P5 | Pousser les 31 commits de Soulbah pour que la CI et ses contrôles de sécurité tournent | Rien, mais aucune CI n'a encore validé ce code |
| P6 | Accords de téléchargement modèle par modèle (code, reranker, plus grand modèle de raisonnement) | Lots 6 et 9 |

### Ordre des lots

| Lot | Contenu | Reprend | Preuve de sortie |
|---|---|---|---|
| 1 | **Trusted Core minimal + Control Center (socle)** : rôles PDG et Super Admin, sessions d'administration qui expirent, confirmation renforcée ; STOP SOULBAH et SAFE MODE ; interrupteurs maîtres persistés, versionnés et audités (Internet, IA externes, Computer Control, auto-amélioration, Security Autopilot, production : valeurs prudentes seulement) ; politiques immuables pour les agents ; correction des 4 défauts relevés ; tableau de bord de santé et page Garde-fous | CC 1-2 (socle), Ext 16-17 (socle) | STOP pendant une mission : workers arrêtés en moins de 10 s, aucun nouveau bail ; SAFE MODE : écriture refusée ; changement d'interrupteur audité (ancien, nouveau, auteur, raison) |
| 2 | **Project Registry** : 224Connect (lecture seule) et 224Solutions dès que fourni ; environnements LOCAL à PRODUCTION ; liste d'exclusion des secrets (`.env`, `.claude`, clés, credentials) ; baseline (version, dépendances, migrations, routes) | Ext 1, CC 10-11 (socle) | Fiche projet dans le Control Center ; aucun fichier exclu jamais lu |
| 3 | **Code Indexer** : fichiers, empreintes, symboles par AST (TypeScript, Python), SQL des migrations, index lexical | Ext 2, Ext 12 | « Où est défini X, qui l'appelle » hors ligne sur 224Connect |
| 4 | **Code Knowledge Graph + Database Intelligence + API Intelligence** : graphe fichiers, fonctions, routes, tables, policies, fonctions SQL ; analyse d'impact | Ext 3-5 | Impact d'une fonction ou d'une table vérifié sur 10 cas étiquetés |
| 5 | **UI / User Flow Intelligence** : routes, écrans, appels d'API, permissions, parcours | Ext 6 | Parcours « live » ou « canal » de 224Connect reconstitué avec ses fichiers |
| 6 | **Project Brain + RAG local hybride** : lexical, vecteurs locaux, graphe, historique ; reranker (accord) ; couverture réelle et KnowledgeGapDetector | Ext 7, V3 7+8, CC 6 | Test hors ligne n° 69 (module Canaux) ; rappel mesuré sur un jeu de questions |
| 7 | **ProjectWatcher + Git Memory** : réindexation incrémentale, commits, migrations | Ext 8 | 4 fichiers modifiés → seuls eux et leurs dépendants réindexés |
| 8 | **Mémoires** : bugs, solutions, sécurité, décisions d'architecture, recherche (provenance, fraîcheur, statuts, versions, déduplication), portée par projet, défense contre l'empoisonnement | Ext 9, CC 6-7 | Connaissance remplacée marquée SUPERSEDED ; candidat externe jamais validé seul |
| 9 | **Local Model Stack + Model Registry + champion / challenger** : modèle de code, plus grand modèle de raisonnement si la RAM le permet, mesures par capacité | Ext 10, Lab 4-6 et 71-73 | Le challenger doit battre le champion sur les mêmes tests (dont la planification multi-agents, 0/4 aujourd'hui) |
| 10 | **Registre d'agents + moteur de politiques complet + passerelle d'outils** : permissions nommées × agent × projet × environnement, préréglages SAFE à CUSTOM, double validation, historique, aucune auto-élévation | CC 2-3, Ext 17, Lab 39 | Matrice agent / permission / environnement affichée et appliquée ; tentative d'élévation bloquée et auditée |
| 11 | **Superviseur, watchdog, évaluateur, relecture croisée** : boucles, actions répétées, plafonds, quarantaine, relecteur sécurité, jamais d'auto-validation critique | CC 4-5, Ext 12 | Boucle provoquée détectée et arrêtée ; correction critique refusée sans relecteur indépendant |
| 12 | **Codage autonome hors ligne en sandbox** sur 224Connect (copie DEV) : reproduire, cause racine, worktree, correctif, tests, relecture | Ext 11, CC 12 | Tests hors ligne n° 68 et 70 |
| 13 | **Security Command Center + Security Autopilot** (OFF, MONITOR, FIX IN LAB, FIX + TEST) : adaptateurs de scanners, findings et chronologie, bibliothèque de patterns, recherche du même pattern dans l'autre projet | CC 9-11, Ext 18, Lab 35-62 | Test n° 71 : vulnérabilité contrôlée détectée, classée, corrigée en sandbox, test de non-régression créé |
| 14 | **Maintenance autonome + moteur de régression + cause racine** (sources de journaux et métriques des projets requises) | Ext 13, CC 13 | Anomalie injectée en DEV reliée au changement responsable |
| 15 | **Soulbah Lab + auto-amélioration + registre de skills** : candidat, benchmark, comparaison, activation, rollback | Ext 14-15, CC 8 et 14, V3 13-14 | Test n° 72 ; rollback vérifié |
| 16 | **Intelligence Lab** : matrice de capacités, golden tasks, suite de benchmarks (dont privés 224), Dataset Factory filtrée, Technology Radar ; pas d'entraînement sur ce PC | Lab 1-23 | Scores issus uniquement de tests reproductibles |
| 17 | **Production Guard + sauvegardes testées** : barrière avant déploiement, surveillance après, rollback préparé, restauration testée | CC 15, Lab 66-67 | Déploiement simulé bloqué par une barrière rouge ; restauration réussie en environnement isolé |
| 18 | **Observabilité et Control Center complet** : notifications au PDG, historique de santé, tableau Intelligence | CC 16, Ext 16 | Alerte reçue pour un événement critique simulé, aucune pour un avertissement mineur |
| 19 | **Tests maîtres hors ligne et benchmarks** (tests 68 à 72 rejoués ensemble) | Ext 19, CC 17, V3 17 | Rapport sans arrangement des échecs |
| 20 | **Durcissement et défense** : empreintes des composants critiques, détection de compromission, laboratoire red team sur copies, tests adversariaux (injection, mémoire empoisonnée, dépendance malveillante, élévation) | Ext 20, Lab 45-65 | Chaque attaque contrôlée détectée et bloquée |

Chaque lot ajoute sa propre page au Control Center, se termine par des tests et une preuve réelle, puis un
commit. Tout téléchargement de modèle ou d'outil reste soumis à votre accord, modèle par modèle.

**Reportés faute de matériel** : moteur de génération d'images et laboratoire d'entraînement (un GPU est
nécessaire ; ce PC n'en a pas). Reportés en attente d'accord : reconnaissance vocale locale, OCR et boucle
« observer, agir, vérifier » (V3 LOT 9 et 11).

**En attente de validation avant le LOT 1.**
