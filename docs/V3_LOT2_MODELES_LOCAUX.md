# V3 LOT 2 — Couche de modèles locaux

Source : mission V3 §4-7 (pas de modèle unique imposé, registre `local_models`, modèles open source),
§11-13 (un serveur partagé, agent ≠ instance de modèle), §44-47 (banc d'essai, repli local), §62 (installeur avec
consentement), §81-82 (licences, sécurité des modèles). **Aucun modèle n'a été téléchargé** : l'installation attend
ton accord, modèle par modèle.

## 1. Composants (`agent/local_models/`)

| Module | Rôle |
|---|---|
| `registry.py` | Registre `local_models` : `%LOCALAPPDATA%\Soulbah\models\registry.json` (écriture atomique). Par modèle : id, nom, famille, version, rôles, chemin, taille, sha256, quantification, contexte maximal, RAM et VRAM estimées, moteur, capacités, licence acceptée (date), source et révision figée, benchmark, statut (`installed`, `verified`, `failed`). `models_for_role` renvoie les modèles sains du plus grand au plus petit (repli Grand → Moyen → Petit). |
| `catalog.py` | Candidats PROPOSÉS. `resolve` lit en ligne les métadonnées exactes (quelques Ko) : taille, sha256, licence déclarée, révision figée ; dépôts Hugging Face et publications GitHub de llama.cpp. |
| `installer.py` | Téléchargement seulement avec `--yes` ET `--accept-license`, après affichage du résumé. Refusé en OFFLINE, sans sha256 publiée, pour un modèle à accès restreint, ou si l'espace libre passerait sous 5 Go. Reprise (`.part` + Range), vérification sha256, déplacement atomique. GGUF uniquement (poids sans code). Archive du moteur extraite sans chemin sortant. `register` pour un fichier GGUF copié hors ligne. |
| `server.py` | Serveur partagé `llama-server` : une copie des poids, `parallel` contextes ; bouclage uniquement ; threads = cœurs physiques et contextes tirés du profil matériel ; démarrage vérifié par `/health` ; état, arrêt, mémoire de pointe du processus. |
| `bench.py` | Banc d'essai standard sur tout serveur compatible OpenAI : plan JSON contraint par schéma, raisonnement numérique, revue de code (ligne fautive), lecture de document, consigne en français. Notation par règles (jamais par un autre modèle, jamais en exécutant le code produit) ; jetons/s et mémoire de pointe ; résultat rangé dans le registre. |

Commande : `agent\.venv\Scripts\python.exe agent\soulbah_models.py catalog | resolve | install | install-engine | register | list | serve | status | stop | bench | remove`.

python-ia : vers un modèle local (`LOCAL_LLM_URL`, famille `local`), le schéma JSON demandé part dans
`response_format.schema` ; llama-server contraint alors la génération par grammaire (JSON valide garanti), ce qui
compte beaucoup pour un petit modèle. Les fournisseurs cloud reçoivent toujours `json_object` seul.

## 2. Candidats vérifiés en ligne le 2026-10-01

Métadonnées lues par `resolve` (révision figée, sha256 publiée, licence déclarée par la source) :

| Identifiant | Rôles | Taille | Licence déclarée | Remarque |
|---|---|---|---|---|
| `qwen2.5-1.5b-instruct-q4_k_m` | chat, planification, rapide | 1,04 Go | apache-2.0 | Le plus léger ; candidat principal pour 8 Go |
| `phi-3.5-mini-instruct-q4_k_m` | chat, planification, raisonnement | 2,23 Go | mit | Meilleure qualité attendue, plus lent (≈ 6 jetons/s estimés ici) |
| `llama-3.2-3b-instruct-q4_k_m` | chat, planification | 1,88 Go | llama3.2 | Licence communautaire Llama 3.2 (politique d'usage, mention) |
| `qwen2.5-3b-instruct-q4_k_m` | chat, planification | 1,96 Go | other (qwen-research) | **Licence de recherche, non commerciale** : déconseillé si usage commercial |
| `qwen2.5-coder-1.5b-instruct-q4_k_m` | code | 1,04 Go | apache-2.0 | Modèle de code |
| `nomic-embed-text-v1.5-q8_0` | embeddings | 0,14 Go | apache-2.0 | Pour la base de connaissances locale (LOT 7) |
| `llama.cpp-win-cpu-x64` (moteur) | — | 18 Mo | MIT | Publication b11325, sha256 publiée |
| `llama.cpp-win-vulkan-x64` (moteur) | — | 31 Mo | MIT | À comparer sur l'Intel HD 520 |

Sur ce PC (profil du LOT 1) : fichier de modèle ≤ 2,7 Go, une inférence à la fois, environ 7 Go de budget disque
pour les modèles. Un premier pack réaliste : moteur CPU + `qwen2.5-1.5b-instruct` + `nomic-embed-text` (≈ 1,2 Go),
puis `phi-3.5-mini-instruct` (2,2 Go) pour comparaison au banc d'essai.

## 3. Preuves

`agent/tests/test_v3_lot2_models.py` (16 tests, aucun téléchargement réel) :

- registre : écriture, relecture, retrait, identifiants refusés, ordre de repli par taille, modèles absents ou en
  échec écartés ;
- résolution : révision figée dans l'URL, licence lue, empreinte absente = refus ; moteur trouvé dans la plus
  récente publication qui contient l'archive ;
- installeur : aucun octet sans `--yes` ni licence acceptée ; refus en OFFLINE, sans empreinte, à accès restreint,
  sans réserve disque ; empreinte fausse = fichier supprimé et rien d'enregistré ; reprise par Range ; fichier déjà
  présent non retéléchargé ; archive avec chemin sortant refusée ;
- serveur : démarrage vérifié, bouclage seul, deux contextes sur une seule instance, réutilisation, refus d'un second
  modèle, arrêt, échec de démarrage signalé (faux llama-server `tests/fake_llama_server.py`) ;
- banc d'essai : 5/5 et jetons/s sur le faux serveur, statut `verified` enregistré ; réponses fausses comptées en
  échecs.

python-ia : `tests/test_v3_network_guard.py::test_local_provider_sends_schema_for_constrained_json`.

## 4. Installation réalisée (accord « pack minimal » du 2026-10-01)

| Élément | Résultat |
|---|---|
| Moteur `llama.cpp-win-cpu-x64` b11325 (18 Mo, MIT) | installé, sha256 vérifiée, `llama-server --version` OK (backend CPU AVX2 choisi automatiquement) |
| `qwen2.5-1.5b-instruct-q4_k_m` (1,04 Go, Apache-2.0) | installé, sha256 vérifiée, statut `verified` après banc d'essai |
| `nomic-embed-text-v1.5-q8_0` (0,14 Go, Apache-2.0) | installé, sha256 vérifiée (servira au LOT 7) |
| Écartés d'office | Qwen2.5 3B (licence de recherche non commerciale), Llama 3.2 3B (licence communautaire) |

Banc d'essai sur ce PC (i5-6300U, 8 Go, RAM très sollicitée par les applications ouvertes), serveur partagé à
1 contexte, 2 threads :

| Tâche | Résultat | Durée | Jetons/s |
|---|---|---|---|
| plan_json (sortie contrainte par schéma) | réussi | 6,6 s | 10,4 |
| reasoning (calcul 12 × 7 − 5) | **échoué** | 1,6 s | 20,8 |
| code_review (ligne fautive) | réussi | 2,2 s | 25,3 |
| doc_qa (lecture d'un passage) | réussi | 3,5 s | 12,6 |
| french_summary (consigne en français) | réussi | 3,5 s | 11,9 |
| **Total** | **4/5** | 17,4 s | 11,5 en moyenne ; mémoire de pointe 1,34 Go |

L'estimation du LOT 1 (≈ 13,5 jetons/s pour un fichier de 1 Go) était du bon ordre. L'échec au calcul confirme
qu'un modèle de 1,5 milliard de paramètres ne doit pas faire seul les calculs : les outils et les critères à règles
restent indispensables.

**Raisonnement hors ligne prouvé** : `backend/python-ia/tests/test_v3_local_live.py` (lancé avec
`LIVE_LOCAL_LLM_URL=http://127.0.0.1:8091/v1`) — mode OFFLINE, NetworkGuard actif (résolution de
`api.anthropic.com` refusée), clé cloud présente mais ignorée ; le routeur ne retient que `local` et le modèle
produit en 19 s un plan JSON valide : écrire « bonjour hors ligne » dans `C:\w
ote.txt` puis le relire.

Pour l'utiliser :

```text
cd agent
.venv\Scripts\python.exe soulbah_models.py serve qwen2.5-1.5b-instruct-q4_k_m --parallel 1
set LOCAL_LLM_URL=http://127.0.0.1:8091/v1
set LOCAL_LLM_MODEL=qwen2.5-1.5b-instruct-q4_k_m
set SOULBAH_MODE=OFFLINE
```
