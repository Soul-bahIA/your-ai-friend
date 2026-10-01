# V3 LOT 1 — Configuration centrale, modes, profil matériel, capacités

Source : mission V3 (§3 Hardware Profiler, §8 trois modes, §79 configuration centralisée, §84-86 registre des
capacités et absence d'hallucination de capacité), rapport `docs/SOULBAH_V3_LOT0_LOCAL_READINESS.md` §K.
Aucun modèle téléchargé, aucun fournisseur supprimé : le mode par défaut (HYBRID) garde le comportement V2.

## 1. Configuration centrale

Un seul contrat pour les trois services :

| Élément | Fichier |
|---|---|
| Implémentation de référence (Python, bibliothèque standard) | `shared/config/soulbah_settings.py` |
| Copies à l'identique (non-dérive vérifiée par les tests et la CI) | `agent/soulbah_settings.py`, `backend/python-ia/app/soulbah_settings.py` ; `python scripts/sync_shared.py` |
| Équivalent TypeScript | `backend/node-api/src/lib/soulbahSettings.ts` |
| Cas de résolution communs (exécutés par les trois) | `shared/config/resolution_cases.json` |
| Schéma et exemple | `shared/config/soulbah.config.schema.json`, `shared/config/soulbah.config.example.json` |

Résolution : valeurs par défaut < fichier `soulbah.config.json` (racine du dépôt, jamais versionné, ou chemin
`SOULBAH_CONFIG`) < variables d'environnement.

| Clé | Variable | Défaut | Effet aujourd'hui |
|---|---|---|---|
| `mode` | `SOULBAH_MODE` | `HYBRID` | Voir §2 |
| `max_agents` | `SOULBAH_MAX_PARALLEL_AGENTS` | 6 | Plafond global du scheduler |
| `resource_profile` | `SOULBAH_RESOURCE_PROFILE` | `BALANCED` | `ECO` limite à 2 agents ; le Resource Manager (LOT 6 V3) affinera |
| `model_policy` | `SOULBAH_MODEL_POLICY` | `auto` | Lu et validé ; appliqué par le routeur local (LOT 3 V3) |
| `network.allow_hosts` | `SOULBAH_NETWORK_ALLOW_HOSTS` | aucun | Machines de l'utilisateur joignables même en OFFLINE |
| `computer_control` | `SOULBAH_COMPUTER_CONTROL` | `true` | `false` : souris, clavier, fenêtres, applications, téléphone refusés par l'agent |
| `recording` | `SOULBAH_RECORDING` | `true` | `false` : enregistrement d'écran refusé |
| `self_improvement` | `SOULBAH_SELF_IMPROVEMENT` | `false` | Lu et validé ; utilisé au LOT 14 V3 |

Une valeur invalide (par exemple `SOULBAH_MODE=OFLINE`) **bloque le démarrage** de l'agent, de python-ia et de
node-api. Une faute de frappe n'ouvre jamais le cloud ni le réseau en silence.

## 2. Les trois modes

| | OFFLINE | LOCAL_INTERNET | HYBRID |
|---|---|---|---|
| Fournisseurs de modèles cloud (python-ia, chat, embeddings, TTS) | refusés | refusés | autorisés |
| `LOCAL_LLM_URL` | machine de l'utilisateur seulement | machine de l'utilisateur seulement | libre |
| Recherche web, lecture web (`browser_get`), `git_push` | refusés (hôtes déclarés seulement) | autorisés | autorisés |
| `npm ci` / `npm install` | refusés (réseau requis) | autorisés | autorisés |
| Base, python-ia, Supabase Auth au démarrage de node-api | doivent être locaux, sinon démarrage refusé | libres | libres |

« Machine de l'utilisateur » : bouclage (`127.0.0.1`, `localhost`, `::1`), nom sans point (service Docker
`python-ia`, `postgres`, machine du réseau local) ou hôte déclaré dans `network.allow_hosts`.

Où c'est appliqué :

- **python-ia** (`app/providers/registry.py`) : hors HYBRID, aucun fournisseur cloud n'est **construit**, même avec
  une clé. Sans modèle local, `503 « Aucun modèle local disponible en mode OFFLINE… »`. `GET /v2/models` expose le
  mode et les fournisseurs écartés (`blocked_by_mode`). La narration des vidéos (OpenAI TTS) répond 503 hors HYBRID.
- **node-api** : chat (`services/chatProvider.ts`), embeddings (`services/knowledge/embeddings.ts`, repli plein
  texte, aucun appel réseau), recherche web (`services/research/webSearch.ts`), contrôles de démarrage
  (`lib/envChecks.ts`), plafond d'agents (`config.maxParallelAgents`).
- **agent** (`permissions.py`, `settings_refusal`) : refus avant toute confirmation, y compris en simulation ; ni
  le mode auto, ni `allow_input_control`, ni une approbation ne le lèvent.

Ce LOT applique le mode au niveau des **décisions** du code. Le blocage réseau au niveau du système (une connexion
ouverte par un sous-processus) est l'objet de NetworkGuard (lot suivant).

## 3. Profil matériel (`agent/hardware.py`)

Lecture sans droits administrateur et sans lancer de processus (registre Windows, API Win32 via ctypes,
bibliothèque standard) : OS, CPU (cœurs physiques, threads, fréquence, AVX/AVX2/FMA/AVX-512), RAM totale et
disponible, GPU (VRAM dédiée, pilote, adaptateurs virtuels repérés), CUDA / Vulkan / DirectML, disques, moteurs
locaux (Ollama, llama.cpp, Whisper, Piper, Tesseract), outils, paquets Python, voix de synthèse installées.
Option `--bench` : GFLOPS fp32 et bande passante mémoire en environ 2 secondes.

Recommandations **estimées** (à confirmer par les benchmarks de modèles du LOT 2) : budget RAM d'un modèle,
taille maximale de fichier, inférences simultanées, profil conseillé, budget disque, jetons/s estimés par taille de
modèle (bande passante × 0,7 ÷ taille).

Mesuré sur le PC de développement le 2026-10-01 : i5-6300U 2 cœurs / 4 threads AVX2, 7,9 Go de RAM, Intel HD 520
(VRAM 1 Go partagée) + adaptateur virtuel Hyper-V, Vulkan et DirectML présents, pas de CUDA ; 115 GFLOPS et
19 Go/s mesurés ; recommandation : CPU, fichier de modèle ≤ 2,7 Go, 1 inférence à la fois, profil ECO.

## 4. Registre des capacités

- **Agent** (`agent/capabilities.py`) : `computer.input`, `screen.capture`, `screen.inspect`, `screen.ocr`,
  `vision.local`, `files`, `terminal.execute`, `git.local`, `git.remote`, `editor.vscode`, `web.read`,
  `video.record`, `video.edit`, `voice.tts`, `voice.stt`, `phone.android`, `llm.engine`. Statut `available`,
  `unavailable` (composant manquant nommé) ou `disabled` (mode ou interrupteur).
- Le superviseur envoie `{mode, hardware (résumé sans chemins), local}` dans `capabilities` à l'enregistrement du
  runtime (`POST /api/v2/runtime/register`, colonne existante `soulbah.runtimes.capabilities`, aucune migration).
- **Plan de contrôle** : `GET /api/v2/capabilities` (JWT) agrège la configuration, l'état du routeur de modèles
  (python-ia joignable ou non, fournisseurs écartés), les services (`reasoning.plan`, `vision.judge`, `chat`,
  `web.search`, `knowledge.vector`, `knowledge.fulltext`, `voice.*`, `orchestration.dag`, `evaluation.rules`) et les
  PC enregistrés avec leur profil.
- **Interface** : badge permanent du mode (barre latérale et en-tête mobile) : 🟢 OFFLINE — 100% LOCAL,
  🔵 LOCAL + INTERNET, 🟣 HYBRID, avec le nombre de capacités indisponibles et leurs raisons en infobulle
  (`frontend/src/components/ModeBadge.tsx`).

## 5. Diagnostic : `python doctor.py`

```text
cd agent
.venv\Scripts\python.exe doctor.py            rapport lisible
.venv\Scripts\python.exe doctor.py --bench    + mesures courtes
.venv\Scripts\python.exe doctor.py --json     profil complet
.venv\Scripts\python.exe doctor.py --save     enregistre %LOCALAPPDATA%\Soulbah\hardware.json
```

Code de sortie 2 si la configuration est invalide. Rien n'est envoyé sur le réseau.

## 6. Preuves

| Exigence | Test |
|---|---|
| Même résolution dans les trois services | 10 cas de `shared/config/resolution_cases.json` : `agent/tests/test_v3_lot1.py`, `backend/python-ia/tests/test_v3_lot1_modes.py`, `backend/node-api/test/v3Lot1Modes.test.ts` |
| Copies identiques à la source | tests de non-dérive + CI `sync_shared.py --check` |
| Démarrage refusé sur configuration invalide | agent (`build_executor`), python-ia (`check_startup_config`), node-api (`checkStartupEnv`) |
| Aucun fournisseur cloud hors HYBRID, même avec une clé | python-ia : registre vide, 503 explicite ; node : chat nul, embeddings sans appel `fetch` (espion) |
| OFFLINE : base / python-ia / Supabase externes refusés au démarrage | `v3Lot1Modes.test.ts` (mot de passe jamais affiché) |
| Gate : réseau, contrôle de l'ordinateur, enregistrement | `test_v3_lot1.py` (y compris simulation, `allow_input_control`, aucune confirmation demandée) |
| Profil rapide et sans chemins d'outils envoyés | `test_profile_shape_and_speed`, `test_summary_has_no_tool_paths` |
| Mode visible dans l'interface, rien d'inventé si la route manque | `frontend/src/components/ModeBadge.test.tsx` |
| HYBRID (défaut) inchangé | suites complètes vertes |

## 7. Limites

- Le mode est appliqué dans le code de Soulbah, pas encore au niveau du système : NetworkGuard (lot suivant)
  ajoutera un refus des connexions sortantes dans chaque processus et une règle de pare-feu Windows facultative.
- `model_policy` et `self_improvement` sont validés mais pas encore utilisés (LOT 3 et LOT 14 V3).
- L'interface web exige toujours Supabase Auth (cloud) pour se connecter : en OFFLINE, node-api refuse de démarrer
  avec `AUTH_MODE=supabase` vers un Supabase distant, mais le frontend n'a pas encore de connexion locale.
- Les recommandations matérielles sont des estimations : les benchmarks de modèles (LOT 2) les remplaceront.
