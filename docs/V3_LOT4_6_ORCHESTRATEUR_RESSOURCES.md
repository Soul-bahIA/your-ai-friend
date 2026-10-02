# V3 LOT 4 + 6 — Orchestrateur hors ligne et Resource Manager

Source : mission V3 (agents ≠ instances de modèle ; 6 agents logiques sur une machine de 8 Go), plan du
rapport V3 LOT 0 §H : « 6 agents logiques, 1 ou 2 inférences simultanées, aucune saturation mémoire ».
S'appuie sur l'orchestration V2 (sessions, DAG, scheduler, baux) sans la remplacer.

## 1. Politique mémoire commune

`shared/config/soulbah_resources.py`, copiée à l'identique dans l'agent et python-ia
(`scripts/sync_shared.py`, test de non-dérive dans les deux services).

| Variable | Défaut | Rôle |
|---|---|---|
| `SOULBAH_RAM_RESERVE_MB` | 400 | Mémoire toujours laissée libre au système |
| `SOULBAH_RAM_CRITICAL_MB` | 200 | En dessous : aucun nouveau worker, une seule inférence |
| `SOULBAH_WORKER_RAM_MB` | 150 | Coût estimé d'un worker du runtime |

Nouveaux workers permis = (mémoire libre − réserve) ÷ coût d'un worker, bornés par les slots libres.
Si rien ne tourne et que la mémoire n'est pas critique, un worker reste permis (garantie de progression).
Mémoire illisible : seuls les slots comptent (comportement V2). Lecture par `GlobalMemoryStatusEx`
(Windows) ou `/proc/meminfo`, sans dépendance.

## 2. File d'inférence des modèles locaux (python-ia)

`backend/python-ia/app/inference_gate.py`, appelée par le routeur de modèles avant chaque appel à un
serveur local. Une file par serveur (clé = URL).

- **Capacité** : slots du serveur (`GET /props` → `total_slots` de llama.cpp), ou `SOULBAH_INFERENCE_SLOTS` ;
  réduite à 1 sous pression mémoire critique.
- **Occupation réelle** : avant de libérer une requête, la file lit `GET /slots`. Le chat de node-api appelle
  llama-server directement, sans passer par python-ia : ses inférences comptent quand même.
- **Priorité** : conversation (`chat`, `routing`) > agents (`automation`, `evaluation`, `vision`…) > fond
  (`code`, rédaction, formation) ; ordre d'arrivée à priorité égale.
- **Délais** : le temps passé en file n'est pas imputé au délai de l'appel au modèle, seulement à
  l'échéance globale de la requête. Au-delà de `SOULBAH_INFERENCE_QUEUE_MAX_S` (600 s) ou du temps restant :
  503 `local_busy` avec l'état de la file, et repli vers le saut suivant s'il existe (petit modèle local,
  ou cloud en HYBRID). Un serveur occupé n'ouvre pas son disjoncteur.
- **Visible** : `GET /v2/resources` (python-ia) → mémoire, capacité, en cours, en attente (avec tâche,
  priorité et ancienneté), servies, refus, attentes dernière / max / moyenne.
- `SOULBAH_INFERENCE_PROBE=0` : pas de lecture de `/props` ni `/slots` (serveur autre que llama.cpp).

## 3. Runtime (PC) et plan de contrôle

- **Superviseur** (`agent/runtime/supervisor.py`) : avant chaque demande de bail, `slots` est réduit au
  nombre de workers permis par la mémoire ; mémoire critique → aucune demande. L'état mémoire
  (`free_mb`, `pressure`, `held`, `allowed_new`, `throttled`) part avec `lease` et `keepalive`. Le lanceur
  local démarre le runtime V2 avec 6 slots (`-AgentV2`) : la RAM décide combien tournent vraiment.
- **node-api** : l'état reçu est nettoyé (nombres bornés, niveau connu) et rangé dans
  `soulbah.runtimes.capabilities.live`. Garde-fou du scheduler : aucun nouveau bail pour un runtime dont
  l'état critique date de moins de 90 s (`memory_limited: true` dans la réponse du bail).
- **Vue d'ensemble** : `GET /api/v2/resources` → plafond effectif, agents logiques (en cours, en attente
  d'approbation, en validation, file READY, par rôle), PC (mémoire, workers permis), files d'inférence du
  modèle (relais de python-ia, `null` s'il est injoignable). L'écran viendra avec le tableau de bord.

## 4. Orchestrateur hors ligne

- **Planificateur multi-agents compact** (`compact_planner.dag_system`) : quand le premier modèle de la
  chaîne est local, `POST /v2/planner/propose` n'envoie que les rôles exécutés sur le PC et, pour chacun, ses
  outils pertinents pour l'objectif (≈ 2 600 caractères au lieu du catalogue complet). La sortie est contrainte
  par schéma : une variante de nœud PAR RÔLE (étapes limitées aux outils de ce rôle), niveaux ≤ plafond du rôle
  et de la mission, critères à la forme attendue par node-api, 6 nœuds, 4 étapes et 2 critères au plus, pas de
  champ « note » ni « feasible » (plan vide = irréalisable). Délai long imposé (600 s, `LLM_LONG_TIMEOUT_S`) et
  appel node → python-ia en délai long. Clés de nœuds en double renommées si aucune arête ne les cite.
- **Réparation** : un plan proposé par le modèle et refusé par `validateDag` est redemandé une fois avec la
  liste des erreurs et le plan refusé (`MAX_LLM_PLAN_ATTEMPTS = 2`). Jamais pour un gabarit. La réponse
  indique `attempts`. La validation elle-même est inchangée.
- Le pont V1 → V2 et le chemin V1 utilisaient déjà le planificateur compact (commit 5c4f7b4).

## 5. Preuves automatisées

python-ia `tests/test_v3_lot6_resources.py` (18 : politique mémoire, priorités, file pleine, occupation externe du
serveur, 6 requêtes sérialisées, temps de file non imputé, repli `local_busy`, délai long, DAG compact par rôle,
clés en double) ; agent `tests/test_v3_lot6_resources.py` (5 : workers limités par la RAM, état envoyé avec lease
et keepalive, mémoire critique) ; node-api `test/v3Lot6Resources.test.ts` (3) et
`test/integration/v3Resources.pg.test.ts` (2, PostgreSQL réel : garde-fou « mémoire critique », vue
d'ensemble) ; `test/integration/v2Planner.pg.test.ts` (réparation : plan refusé puis corrigé et posé).

## 6. Essais réels (2026-10-02, PC de référence : 2 cœurs, 8 Go, qwen2.5-1.5b, 1 slot llama-server)

| Essai | Résultat |
|---|---|
| 6 agents demandent une inférence au même instant (python-ia `/v2/models/complete`) | 6/6 réussies en 63 s ; jamais plus d'1 inférence à la fois ; file visible jusqu'à 6 en attente ; RAM libre 301 à 1 172 Mo ; llama-server 1 285 Mo au plus |
| Même essai, pendant une conversation de l'utilisateur dans le chat | La file a attendu que le chat (appel direct de node-api au serveur, 38 s) libère le slot : l'occupation externe est bien respectée |
| Mission V2 de 6 agents logiques (plan fourni, validé par validateDag), runtime réel avec 6 slots | 6/6 tâches COMPLETED en 32 s, 6/6 fichiers vérifiés ; RAM libre 530 Mo au plus bas → 1 worker permis à la fois (limitation vue), aucune saturation |
| DAG multi-agents proposé par le modèle LOCAL (« crée a.txt, b.txt, c.txt ») | **0/4 accepté** : (1) délai de 280 s dépassé à 3,4 jetons/s sous grammaire → délai long de 600 s ; (2) « irréalisable » déclaré avant d'écrire les nœuds → champ retiré ; (3) clés en double et `write_file` dans un rôle qui ne l'a pas → schéma par rôle et renommage des doublons ; (4) plan vide en 76 s. Chaque fois, validateDag a refusé ou rien n'a été proposé : **aucune action invalide exécutée** |

Conclusion honnête : l'exécution multi-agents hors ligne fonctionne (file d'inférence, limitation par la RAM,
6 agents logiques, preuves). La **planification** multi-agents par le modèle de 1,5 milliard de paramètres n'est
pas fiable : hors ligne, utiliser les gabarits (`formation`, `code_parallel`, `demo_video`, `desktop_goal`) et
le pont V1 → V2 (plan compact d'un seul agent, 50 à 94 s). Un modèle plus grand ou spécialisé (accord de
téléchargement requis) sera à mesurer sur ce même essai.
