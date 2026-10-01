# SOULBAH IA V3 — LOCAL READINESS REPORT

LOT 0 de la mission « Soulbah IA V3 local-first / offline / open source ». Audit seul, le 2026-10-01, sur le
dépôt au commit `2c2b77a` (fin du LOT 12 de la V2) et sur le PC de développement. Aucun modèle téléchargé, aucun
fournisseur remplacé, aucune API supprimée.

Statuts utilisés : **FONCTIONNE** (existe et fonctionne, testé), **INCOMPLET** (existe mais incomplet),
**DÉFECTUEUX** (existe mais défectueux), **ABSENT**.

Index des 25 questions de la mission : architecture (1) §A ; dépendances IA (2), appels cloud (3) §B ; ce qui casse
sans Internet (4) §D ; capacités locales (5) §C ; contrôle ordinateur (6), multi-agent (7), mémoire (8), base de
connaissances (9), vidéo (10), voix (11), base de données (12) §C ; matériel, GPU, VRAM, RAM, CPU, stockage, OS
(13 à 19) §E ; moteurs locaux (20) §F ; à conserver, refactoriser, créer (21 à 23) §G ; risques (24) §I ; plan (25) §H.

---

## A. Architecture actuelle

Architecture V2 « Split-Plane » (docs/SOULBAH_V2_LOT0_AUDIT.md, lots 1 à 12 livrés) :

```text
frontend (React/Vite) ──HTTP──► P1 node-api (Fastify) ──SQL──► PostgreSQL (schéma soulbah.* + tables V1)
        │ Supabase Auth (cloud)        │  sessions, tâches, DAG, scheduler, validateDag, évaluation,
        │                              │  approbations HMAC, audit chaîné, artefacts sha256
        │                              ├──HTTP──► P2 python-ia (FastAPI) : routeur de modèles ──► API cloud LLM
        │                              │                                  (ou LOCAL_LLM_URL, jamais configuré)
        │                              └──HTTP──► recherche web (Tavily / Serper / Brave), embeddings OpenAI
        ▼
P3 agent Windows (agent/) : superviseur V2 + 1 worker par tâche (Job Object), journal SQLite,
   skills locales : bureau, fichiers, commandes, git/worktrees, capture, enregistrement, montage, téléphone
```

| Composant | Rôle | Dépend du cloud ? |
|---|---|---|
| `agent/` (Python 3.11) | Exécute les actions sur le PC ; 56 types d'étapes ; gate L0–L3 ; runtime V2 | Non pour l'exécution. Oui pour **décider** quoi faire (le plan vient de P1/P2). |
| `backend/node-api` (Node 25, TS) | Plan de contrôle : seul écrivain de `soulbah.*` | Non pour l'orchestration V2. Oui pour l'authentification hors `AUTH_MODE=dev-local`, le chat, les embeddings, la recherche web. |
| `backend/python-ia` (FastAPI) | Routeur de modèles (planification, évaluation, vision, rédaction, recherche) | **Oui** : tous les appels de raisonnement passent par une API cloud, sauf si `LOCAL_LLM_URL` pointe vers un serveur local. |
| `frontend/` (React) | Interface | **Oui** : connexion uniquement par Supabase Auth cloud ; police Google Fonts. |
| PostgreSQL | Données V1 + V2 | Supabase cloud (en pause) en production ; PostgreSQL 18 local (`scripts/dev_db`) en développement. |

## B. Dépendances cloud

| Usage | Service | Fichier | Configuration | Repli local aujourd'hui |
|---|---|---|---|---|
| Raisonnement : planification V1 et V2, évaluation, grilles `llm_rubric`, vision des captures, rédaction, formations | Anthropic, OpenAI, Gemini, Mistral, DeepSeek, xAI, Qwen | `backend/python-ia/app/providers/registry.py` (SPECS), `router.py` | `*_API_KEY`, `LLM_ROUTING`, `LLM_MODEL_<RÔLE>` | **Partiel** : `LOCAL_LLM_URL` (Ollama, LM Studio, llama.cpp, vLLM : toute API compatible OpenAI) est déjà géré, en dernier dans l'ordre par défaut. Aucun serveur local installé. `FakeProvider` réservé au dev/test (aucune intelligence). |
| Chat de l'application | Mêmes fournisseurs, appel direct depuis node | `backend/node-api/src/services/chatProvider.ts` | `OPENAI_URL`, clés, `LOCAL_LLM_URL` | **Partiel** : `LOCAL_LLM_URL` géré ; sans fournisseur, le chat répond 503. |
| Embeddings de la base de connaissances | OpenAI `text-embedding-3-small` (1536 dimensions) | `backend/node-api/src/services/knowledge/embeddings.ts` | `EMBEDDING_URL`, `EMBEDDING_MODEL`, `OPENAI_API_KEY` | **Oui** : recherche plein texte si les embeddings manquent (`supabaseStore.ts`). |
| Recherche web | Tavily, Serper, Brave | `backend/node-api/src/services/research/webSearch.ts` | `TAVILY_API_KEY`, `SERPER_API_KEY`, `BRAVE_API_KEY` | Non (Internet par nature). |
| Narration des vidéos de formation | OpenAI TTS | `backend/python-ia/app/video.py` (`_synthesize`) | `OPENAI_API_KEY`, `OPENAI_TTS_URL` | **Non** : sans clé, erreur « OPENAI_API_KEY non configurée ». |
| Connexion des utilisateurs | Supabase Auth | `frontend/src/integrations/supabase/client.ts`, `frontend/src/pages/Auth.tsx`, `backend/node-api/src/auth.ts` (`/auth/v1/user`) | `VITE_SUPABASE_*`, `SUPABASE_URL` | **Partiel** : node-api accepte `AUTH_MODE=dev-local` (LOT 3) ; le frontend ne l'a **pas** : l'interface est inutilisable sans Supabase cloud. |
| Base de données de production | Supabase PostgreSQL (pooler) | `backend/.env` | `DATABASE_URL` | **Oui** : PostgreSQL 18 local, toutes les migrations passent (sans pgvector : DDL vectoriel remplacé par un stub). |
| Police de l'interface | Google Fonts | `frontend/src/index.css:1` | — | Repli sur les polices système (rendu différent). |
| Télémétrie | Aucune trouvée (ni Sentry, ni PostHog, ni analytics) | — | — | Sans objet. |

Le service `rust-compute` (`backend/python-ia/app/rust_client.py`) est un service local, pas un cloud.

## C. Capacités offline actuelles

### Contrôle de l'ordinateur (agent)

| Capacité | Statut | Preuve |
|---|---|---|
| Souris, clavier, fenêtres, lancement d'applications | FONCTIONNE | `agent/skills/mouse.py`, `type_text.py`, `hotkey.py`, `window.py`, `open_app.py` ; tests agent |
| Capture d'écran | FONCTIONNE | `agent/skills/screenshot.py` (mss) |
| Inspection d'interface Win32 (titre, contrôles, DPI, empreinte du texte) | FONCTIONNE | `agent/skills/ui_snapshot.py` ; scénario Bloc-notes réel réussi le 2026-10-01 |
| Localiser « le bouton Exporter » par son nom | ABSENT | Aucun arbre UI Automation, aucun OCR, aucune vision locale |
| Vérifier une action par nouvelle observation | INCOMPLET | Critères `ui_element_state`, `artifact_hash`, `file_exists` (LOT 10) ; pas de boucle observer → décider → agir |
| Sensibilité DPI | FONCTIONNE | `skills/desktop.py:ensure_dpi_awareness` |
| Arrêt d'urgence | INCOMPLET | Arrêt depuis l'app, fichiers d'arrêt du superviseur (`runtime/supervisor.py`), coin d'écran de pyautogui ; **pas de raccourci clavier global**, pas d'arrêt unique de tous les agents |
| Watchdog | INCOMPLET | Le superviseur relance les workers (2 fois au plus) ; rien ne surveille le superviseur, node-api ni un serveur de modèle |

### Code, terminal, fichiers

| Capacité | Statut | Preuve |
|---|---|---|
| Commandes sans shell (git, npm, python, node, pytest), sortie, code de retour, arbre tué au délai | FONCTIONNE | `agent/skills/run_command.py`, `proctree.py` |
| Git : worktree par tâche, commit, fusion testée, suppression et push L3 | FONCTIONNE | `agent/skills/git_workspace.py` (LOT 12) |
| VS Code | INCOMPLET | `vscode_open` ouvre un dossier ; aucun pilotage de l'éditeur |
| Fichiers : lire, écrire, déplacer, lister, créer un dossier | FONCTIONNE | `agent/skills/filesystem.py`, `move_file.py` |
| `patch_file`, `search_files`, `compare_files`, `hash_file`, `copy` | ABSENT | — |
| Lancer un serveur et surveiller ses journaux | ABSENT | `run_command` attend la fin du processus |

### Multi-agents et orchestration

| Capacité | Statut | Preuve |
|---|---|---|
| Sessions, tâches à 10 états, DAG anti-cycle, scheduler à baux, parallélisme configurable (`SOULBAH_MAX_PARALLEL_AGENTS`, 6 par défaut) | FONCTIONNE | `backend/node-api/src/v2/*`, migrations `soulbah.*`, tests d'intégration Postgres |
| Rôles versionnés, validateDag, gabarits (`desktop_goal`, `formation`, `demo_video`, `code_parallel`) | FONCTIONNE | `src/v2/planner/*`, `shared/roles/roles.json` |
| Workers isolés, journal SQLite, reprise après crash, idempotence | FONCTIONNE | `agent/runtime/*` (LOT 8), tests de chaos (LOT 10) |
| Anti-boucle (tentatives bornées, backoff 30 s / 2 min / 8 min, escalade) | FONCTIONNE | `stateMachine.ts`, `scheduler.ts` |
| Planificateur | INCOMPLET hors ligne | Gabarits = local ; proposition libre = LLM via python-ia (cloud) |
| Évaluation par preuves | FONCTIONNE hors ligne pour les critères à règles ; `llm_rubric` exige un modèle |
| Ressources machine (RAM, VRAM, CPU) dans l'ordonnancement | ABSENT | Le scheduler ne connaît que des slots et des ressources logiques (`desktop.input`, `git.merge`) |
| Agent ≠ instance de modèle | ABSENT | Aucun serveur de modèle partagé |

### Mémoire, connaissances, RAG

| Capacité | Statut | Preuve |
|---|---|---|
| Mémoire de l'agent : leçons proposées puis validées, rejets exclus, contexte borné et marqué non fiable | FONCTIONNE | `backend/node-api/src/routes/agentMemory.ts`, `test/memory.test.ts`, migrations `20260704000000_agent_memory.sql` et `20260706120000_agent_memory_levels.sql` |
| Base de connaissances (écrivain unique, hash, versions, dédoublonnage) | FONCTIONNE | `backend/node-api/src/services/knowledge/*` |
| Recherche plein texte / trigrammes | FONCTIONNE hors ligne | `pg_trgm` 1.6 installé localement |
| Recherche vectorielle | INCOMPLET | pgvector **absent** du PostgreSQL local ; embeddings OpenAI seulement |
| Recherche hybride avec fusion RRF et reranking | ABSENT | Prévu au LOT 13 V2, non commencé |
| Mémoires épisodique, sémantique, procédurale, de projet distinctes | ABSENT | — |

### Vidéo, voix, vision

| Capacité | Statut | Preuve |
|---|---|---|
| Enregistrement d'écran (premier plan et arrière-plan) | FONCTIONNE | `agent/skills/record_screen.py`, `record_bg.py` (mss + OpenCV) |
| Montage simple, export MP4 vérifié par sonde | FONCTIONNE | `agent/skills/edit_video.py` (moviepy 1.0.3 + FFmpeg 7.1 fourni par imageio-ffmpeg) |
| Montage DaVinci Resolve | INCOMPLET | `resolve_montage.py` ; Resolve non installé sur ce PC |
| Montage automatique (temps morts, versions démo/tutoriel) | ABSENT | — |
| Sous-titres | ABSENT | Pas de STT |
| Synthèse vocale | INCOMPLET | Formation vidéo : OpenAI TTS (cloud). Lecteur web : `speechSynthesis` du navigateur. **Voix françaises Windows installées : Hortense, Julie, Paul** (utilisables hors ligne, non branchées côté serveur) |
| Reconnaissance vocale (STT) | ABSENT | Aucun microphone, VAD ni moteur STT dans le dépôt |
| Vision (comprendre l'écran) | INCOMPLET | Jugement des captures par un modèle cloud à vision ; rien de local |

### Données, sécurité, configuration

| Capacité | Statut | Preuve |
|---|---|---|
| PostgreSQL local avec tout le schéma V2 | FONCTIONNE | `scripts/dev_db/dev_db.sh` (PG 18, 127.0.0.1:54329) |
| Journal SQLite du runtime, artefacts sha256 sur disque (0 base64 en base), audit chaîné | FONCTIONNE | LOT 4, 8, 9 |
| Niveaux L0–L3, approbations HMAC liées au payload, rédaction des secrets, deny-list, coffre DPAPI | FONCTIONNE | LOT 6, LOT 12 |
| Permissions fines (`filesystem.write`, `network.access`…) | INCOMPLET | Catégories + niveaux, pas encore ce vocabulaire |
| NetworkGuard (blocage réseau réel en mode OFFLINE) | ABSENT | Seul `browser_get` refuse les adresses privées |
| Mode OFFLINE / LOCAL_INTERNET / HYBRID | ABSENT | — |
| Configuration centralisée | ABSENT | Trois sources : `agent/config.py`, `backend/node-api/src/config.ts`, `backend/python-ia/app/config.py` + `.env` |
| Auto-amélioration, benchmarks, bibliothèque de skills procédurales | ABSENT | Prévus au LOT 15 V2 |

## D. Capacités impossibles offline actuellement

1. **Toute décision d'un modèle** : planification d'un objectif libre, chat, évaluation `llm_rubric`, jugement visuel
   d'une capture, rédaction de formations, synthèse de recherche. Aucun serveur local n'est installé, même si le
   code sait déjà en appeler un (`LOCAL_LLM_URL`).
2. **L'interface web** : la connexion passe obligatoirement par Supabase Auth cloud (le frontend n'a pas de mode
   `dev-local`). Hors ligne, personne ne peut se connecter.
3. **La recherche vectorielle** : embeddings OpenAI, et pgvector absent du PostgreSQL local.
4. **La narration audio des vidéos de formation** : OpenAI TTS uniquement côté serveur.
5. **La voix** (STT) et la **vision locale** : absentes.
6. **La recherche web** : impossible par nature hors ligne ; aujourd'hui rien n'empêche techniquement un appel réseau
   quand on voudrait l'interdire.

Ce qui fonctionne déjà hors ligne : l'exécution de toutes les étapes de l'agent, l'orchestration V2 (sessions, DAG,
scheduler, baux, reprise), l'évaluation à règles, les gabarits de plans, les preuves et artefacts, la base locale,
la recherche plein texte, l'enregistrement et le montage vidéo simples, les worktrees git.

## E. Hardware détecté (mesuré le 2026-10-01)

| Élément | Valeur | Commentaire |
|---|---|---|
| OS | Windows 10 Professionnel 22H2 (10.0.19045), 64 bits | WSL présent et actif (processus `vmmem` ≈ 300 Mo) |
| Machine | HP EliteBook 850 G3 (portable) | Risque de bridage thermique en charge longue (température non lisible sans droits administrateur) |
| CPU | Intel Core i5-6300U, **2 cœurs / 4 threads**, 2,4 GHz (Skylake) | AVX2 et FMA3 présents, pas d'AVX-512 (mesuré via numpy) |
| Calcul mesuré | **56 GFLOPS** fp32 (produit matriciel 1536², médiane de 5) | Ordre de grandeur pour le traitement du prompt |
| RAM | **7,9 Go** (2 × 4 Go DDR4-2133) ; **0,8 Go libres** pendant l'audit | VS Code, Claude et WSL occupent l'essentiel ; fichier d'échange 13,6 Go dont 3,9 Go utilisés |
| Bande passante mémoire mesurée | **13 Go/s** médiane, 20 Go/s maximum (copie de 64 Mo) | Détermine la vitesse de génération d'un modèle sur CPU |
| GPU | **Intel HD Graphics 520** intégré, pilote 31.0.101.2111 (2022) | Pas de NVIDIA, pas de CUDA ; mémoire partagée avec la RAM (pas de VRAM dédiée) ; Vulkan 1.3 et DirectML présents |
| Disque | SSD SATA Samsung 128 Go : **13,4 Go libres** sur C: | + clé USB 59 Go (lente, déconseillée pour charger des modèles) |
| Outils | Python 3.11.9, Node 25.6.1, Git 2.53, PostgreSQL 18, VS Code installé, FFmpeg 7.1 (via imageio-ffmpeg) | Absents : Ollama, llama.cpp, Docker, Tesseract, Whisper, Piper, PyTorch, ONNX Runtime |

**Conséquence directe.** Cette machine fait tourner **un seul petit modèle quantifié à la fois, sur CPU**. Ordres de
grandeur à confirmer au LOT 2 (la génération est limitée par la bande passante : environ 13 Go/s ÷ taille du
modèle) :

| Taille du modèle (quantifié 4 bits) | Fichier | Génération estimée | Tient en RAM ? |
|---|---|---|---|
| 0,5 à 1,5 milliard de paramètres | 0,4 à 1,1 Go | 10 à 25 jetons/s | Oui |
| 3 à 4 milliards | 2 à 2,5 Go | 4 à 7 jetons/s | Oui si VS Code et WSL sont fermés |
| 7 à 8 milliards | 4,5 à 5 Go | 2 à 3 jetons/s | Non en usage normal (pagination sur disque) |
| 14 milliards et plus | 8 Go et plus | — | Non |

Le traitement d'un long prompt est lent : à quelques dizaines de jetons par seconde, un prompt de planification de
3 000 jetons coûterait environ une minute. « Six agents en parallèle » signifie ici six contextes logiques sur **une**
instance de modèle, avec une ou deux inférences simultanées au plus.

## F. Modèles et moteurs locaux techniquement envisageables

Candidats à **benchmarker au LOT 2**, pas des choix arrêtés. Les licences sont à revérifier sur la fiche officielle
au moment de l'installation (elles changent d'une version à l'autre). Format privilégié : GGUF ou ONNX (pas de
fichiers pickle exécutables).

### Moteurs d'exécution

| Moteur | Adapté à ce PC ? | Raison |
|---|---|---|
| **llama.cpp** (`llama-server`, licence MIT) | **Oui, premier candidat** | Binaire natif Windows, CPU AVX2, serveur compatible OpenAI (branchable tel quel sur `LOCAL_LLM_URL`), plusieurs contextes sur une seule copie des poids, sortie contrainte par schéma JSON. Backend Vulkan possible sur le HD 520, gain à mesurer (probablement faible). |
| Ollama (MIT) | Oui, second candidat | Repose sur llama.cpp, installation simple, API compatible OpenAI ; moins de contrôle fin, service en arrière-plan supplémentaire. |
| ONNX Runtime (MIT) | Oui pour les petits modèles spécialisés | Embeddings, reranker, OCR, STT via DirectML ou CPU. |
| Transformers + PyTorch | Non | Plusieurs Go d'installation pour 13 Go libres, lent sur CPU. |
| vLLM | Non | Exige Linux et un GPU NVIDIA. |

### Modèles par rôle (petites tailles uniquement)

| Rôle | Candidats à évaluer | Remarque |
|---|---|---|
| Raisonnement et planification | Familles Qwen (Qwen2.5 / Qwen3, 1,5 à 4 milliards), Phi (Phi-3.5-mini / Phi-4-mini), Llama 3.2 (1 et 3 milliards), Gemma (2 et 3), SmolLM2 | La qualité de planification d'un modèle de 3 milliards est très inférieure à celle des modèles cloud actuels : les gabarits et validateDag deviennent essentiels. |
| Code | Qwen2.5-Coder (1,5 à 3 milliards), DeepSeek-Coder (1,3 milliard) | Licence du Qwen2.5-Coder 3B à vérifier (différente des autres tailles d'après mes informations). |
| Vision et lecture d'écran | Moondream2, SmolVLM, Qwen2-VL-2B, Florence-2 (OCR et repérage) | Une inférence vision sur ce CPU prendra plusieurs secondes : réserver la vision aux cas où `ui_snapshot` et l'OCR ne suffisent pas. |
| OCR | Tesseract, PaddleOCR (via ONNX) | Utile pour trouver « Exporter » dans les applications non Win32. |
| Embeddings | multilingual-e5-small, bge-m3, nomic-embed-text | e5-small (≈ 120 Mo) est réaliste ici ; bge-m3 (≈ 570 millions de paramètres) l'est moins. |
| Reranking | bge-reranker-v2-m3, cross-encoders MiniLM | Petit cross-encoder conseillé. |
| Reconnaissance vocale | whisper.cpp ou faster-whisper (Whisper tiny, base, small), Vosk | Whisper base ou small en français sur CPU : à mesurer (temps réel probable seulement pour tiny et base). |
| Synthèse vocale | **Voix Windows SAPI (Hortense, Julie, Paul : déjà installées)**, Piper | SAPI = zéro téléchargement, immédiatement hors ligne. Piper : meilleure qualité, licence à vérifier voix par voix. |
| Vecteurs | pgvector (à installer dans PG 18 Windows) ou index embarqué (sqlite-vec, LanceDB) | Derrière une interface `VectorStoreProvider`. |

Budget disque recommandé pour un premier « Offline Pack » : **5 à 6 Go au total** (un modèle généraliste de 3 à
4 milliards, un petit modèle de code, embeddings, reranker, Whisper base), pour garder de la marge sur les 13,4 Go
libres.

## G. Architecture V3 recommandée

Principe : **garder le Split-Plane V2** et ajouter une couche locale, au lieu de reconstruire. Le noyau existant
(orchestration, preuves, sécurité) est déjà local ; ce qui manque, ce sont les « cerveaux » locaux et les garde-fous
réseau.

```text
frontend (mode local : connexion locale, pas de police distante)
   │
P1 node-api ── orchestration V2 inchangée (sessions, DAG, scheduler, preuves, approbations, audit)
   │   + Resource Manager (RAM libre, modèle chargé, slots d'inférence) dans le scheduler
   │   + CapabilityRegistry (ce qui est disponible : modèles, STT, TTS, OCR, internet)
   │   + SOULBAH_MODE (OFFLINE | LOCAL_INTERNET | HYBRID) + NetworkGuard
   │
P2 python-ia ── Model Router V2 conservé, enrichi d'un LocalModelProvider par rôle
   │              (raisonnement, code, vision, embeddings, rerank, STT, TTS) ; cloud = option HYBRID
   │
Serveur de modèle local partagé (llama-server) : 1 copie des poids, N contextes
   │
P3 agent ── skills existantes + OCR / UI Automation / boucle observer-agir + voix (SAPI d'abord)
```

| À conserver | À refactoriser | À créer |
|---|---|---|
| Orchestration V2 (sessions, DAG, scheduler, baux, reprise) | Ordre de routage : `local` en premier selon le mode ; les rôles du routeur deviennent des rôles de modèle locaux | Hardware Profiler, CapabilityRegistry, Resource Manager |
| Gate L0–L3, approbations, audit chaîné, rédaction | Embeddings : interface `EmbeddingProvider` (local par défaut), dimension libre (aujourd'hui figée à 1536) | NetworkGuard réel (voir §I) et modes |
| Catalogue d'outils unique, preuves typées, artefacts | Narration vidéo : `TTSProvider` (SAPI ou Piper, OpenAI en option) | Registre `local_models` + Model Installer avec consentement et vérification d'empreinte |
| Runtime agent, journal SQLite, worktrees git | Frontend : mode de connexion local, polices embarquées | STT local, OCR, UI Automation, boucle observer → décider → agir |
| PostgreSQL local, recherche plein texte | Configuration : un fichier central lu par les trois services | Arrêt d'urgence global (raccourci), watchdog, benchmarks, Offline Pack |
| `LOCAL_LLM_URL` déjà géré par python-ia et le chat | Prompts : plus courts et contraints par schéma pour les petits modèles | Mémoires épisodique, sémantique, procédurale et de projet ; auto-amélioration contrôlée |

Base de données : **garder PostgreSQL**. Il fonctionne déjà en local et porte tout le schéma V2. Ajouter pgvector
au PostgreSQL 18 Windows, ou un index vectoriel embarqué si son installation échoue. Pas de migration vers une autre
base.

## H. Plan de migration

Les lots V3 de la mission sont repris dans un ordre adapté au matériel mesuré. Les LOT 13 à 15 de la V2 (RAG,
vidéo et recherche, tableau de bord et auto-amélioration) sont en pause : ils sont absorbés par les lots V3
correspondants, avec des moteurs locaux par défaut.

| Lot V3 | Contenu | Dépend de | Critère de sortie |
|---|---|---|---|
| 1 | Hardware Profiler (`soulbah doctor`), CapabilityRegistry, `SOULBAH_MODE`, configuration centrale | — | Profil stocké et affiché ; capacités exactes par mode |
| 15 (avancé) | NetworkGuard : refus des connexions sortantes en OFFLINE dans chaque service, puis règle de pare-feu Windows facultative | 1 | Test : en OFFLINE, toute tentative de connexion externe est refusée **et journalisée** |
| 2 | Model Installer (avec ton accord explicite), llama-server, `LocalModelProvider`, benchmark de 2 ou 3 modèles candidats | 1 | Modèle choisi sur mesures (qualité JSON, vitesse, RAM), branché sur `LOCAL_LLM_URL` |
| 3 | Routeur local par rôle, repli Grand → Moyen → Petit, jamais vers le cloud en OFFLINE | 2 | Plans V2 proposés par le modèle local et validés par validateDag |
| 4 + 6 | Orchestrateur hors ligne + Resource Manager (slots d'inférence selon la RAM libre) | 3 | 6 agents logiques, 1 ou 2 inférences simultanées, aucune saturation mémoire |
| 7 + 8 | Embeddings et reranker locaux, recherche hybride (plein texte + vecteurs + RRF), mémoires distinctes | 2 | Recall@5 hybride > vecteur seul et > plein texte seul, hors ligne |
| 11 (avancé) | Voix : SAPI puis Piper ; Whisper local ; VAD | 1 | Commande vocale comprise et exécutée hors ligne |
| 9 | OCR, UI Automation, boucle observer → agir avec vérification | 2 | « Ouvre VS Code, lance les tests » réussi hors ligne |
| 10, 12, 13 | Environnement de code, vidéo locale (montage automatique, sous-titres), skills procédurales | 9, 11 | Démonstration enregistrée et montée hors ligne |
| 14, 16, 17 | Auto-amélioration contrôlée, tableau de bord, benchmarks hors ligne | tous | Test maître hors ligne exécuté et rapporté sans arrangement des échecs |

## I. Risques

1. **Matériel insuffisant pour l'ambition complète.** 8 Go de RAM et 2 cœurs ne permettent pas de faire tourner en
   même temps un modèle de raisonnement, un modèle de code, un modèle de vision, Whisper et un TTS neuronal. Il faudra
   charger et décharger les modèles à la demande (attentes de plusieurs secondes) ou utiliser une machine plus
   puissante sur le réseau local. Le « test maître » (application complète + vidéo, hors ligne) sera lent et sa
   réussite n'est pas garantie avec des modèles de 3 milliards de paramètres.
2. **Qualité des petits modèles.** Planification et code nettement moins fiables qu'avec les modèles cloud. Parades
   : gabarits, sortie contrainte par schéma JSON, validateDag, critères à règles, prompts courts.
3. **NetworkGuard sous Windows.** Une garde dans le code (hook réseau de Python, intercepteur des requêtes Node) se
   contourne par un sous-processus. Le vrai blocage passe par une règle de pare-feu sortante par programme, qui
   exige les droits administrateur. À traiter en deux couches, avec un test qui prouve le blocage.
4. **Interface dépendante du cloud.** Tant que le frontend exige Supabase Auth, le mode OFFLINE ne concerne que
   l'agent et les API.
5. **Espace disque.** 13,4 Go libres : chaque modèle compte. Pas de PyTorch.
6. **Licences et sécurité des modèles.** Licences variables (certaines restreignent l'usage commercial) ; préférer
   GGUF et ONNX, vérifier les empreintes, ne jamais exécuter de code distant fourni avec un modèle.
7. **Thermique et autonomie** d'un portable en charge CPU continue : baisse de fréquence probable.
8. **Double maintenance cloud / local** pendant la transition : le mode HYBRID doit rester testé.

## J. Tests nécessaires

| Test | Méthode | Preuve attendue |
|---|---|---|
| Hors ligne réel | NetworkGuard actif et, sur une machine de test, adaptateur réseau désactivé | Zéro connexion sortante dans le journal de NetworkGuard ; tâches réussies |
| Absence d'appel cloud en OFFLINE | Clés cloud présentes mais mode OFFLINE | Aucun fournisseur cloud sollicité (compteurs `tool_calls` à zéro) |
| Benchmarks de modèles | Même jeu de tâches (JSON de plan, correction de bug, question sur la documentation) | Taux de réussite, jetons/s, RAM, durée |
| Resource Manager | 6 agents logiques avec RAM libre réduite | Pas de pagination excessive, files d'attente visibles |
| RAG local | Corpus de test, questions à réponse connue | Recall@5 par méthode, citations exactes |
| Voix | Phrases enregistrées en français | Taux d'erreur de mots, latence |
| Computer use hors ligne | VS Code + projet de test | Fichier modifié (empreinte), tests verts, captures |
| Vidéo hors ligne | Enregistrement + montage | Sonde MP4 (durée, pistes) |
| Non-régression | Suites actuelles : agent 703, node 350 + 54, python-ia 415, frontend 187 | Toutes vertes à chaque lot |

## K. Première modification recommandée

**LOT 1 : Hardware Profiler, CapabilityRegistry et `SOULBAH_MODE`, sans aucun téléchargement.**

- Un module de profil matériel (CPU, SIMD, RAM totale et libre, GPU, disque, outils présents) exposé par
  `soulbah doctor` et envoyé au plan de contrôle à l'enregistrement du runtime.
- Un registre des capacités qui répond honnêtement à « que puis-je faire maintenant ? » selon le mode, les moteurs
  installés et le réseau : aujourd'hui, en OFFLINE, il répondrait « raisonnement : indisponible » au lieu de laisser
  échouer un appel cloud.
- La variable `SOULBAH_MODE` lue par les trois services, et le refus explicite d'un appel cloud en OFFLINE.

Ce lot ne change aucun comportement existant en mode HYBRID (mode par défaut). Il prépare le choix des modèles sur
mesures réelles, au LOT 2. Le LOT 2 demandera ton accord avant tout téléchargement (taille, licence, empreinte).

En attente de ta validation avant toute transformation importante.
