# V3 — NetworkGuard : le mode OFFLINE appliqué au niveau du réseau

Source : mission V3 §56 (« Ne te contente pas d'écrire dans le prompt : n'utilise pas Internet. Le système doit
techniquement empêcher les accès réseau non autorisés »), §57-58 (confidentialité, aucune télémétrie), rapport
LOT 0 §I risque 3. Complète le LOT 1 (`docs/V3_LOT1_MODES_PROFIL_CAPACITES.md`), qui applique le mode dans les
décisions du code.

## 1. Règle

Hors OFFLINE, NetworkGuard ne bloque rien. En OFFLINE, une connexion est permise vers :

- le bouclage (`127.0.0.1`, `localhost`, `::1`) ;
- un nom sans point (service Docker `python-ia`, `postgres`, machine du réseau local) ;
- un hôte déclaré dans `network.allow_hosts` ;
- une adresse IP non publique (réseau local, lien local, CGNAT, adresses de documentation).

Tout le reste (noms d'Internet, adresses publiques) est refusé **avant la résolution DNS** : aucun paquet ne part
vers Internet, pas même une requête DNS pour le nom refusé. La même règle est écrite trois fois (Python, Node du
plan de contrôle, Node des processus enfants) et vérifiée sur les mêmes cas : `shared/config/network_guard_cases.json`.

Au niveau des outils, la règle reste plus stricte (LOT 1) : `browser_get` en OFFLINE n'accepte que les hôtes
déclarés, pas une adresse du réseau local quelconque.

## 2. Trois couches

| Couche | Mécanisme | Fichier |
|---|---|---|
| Processus Python de Soulbah : agent V1, superviseur, workers, python-ia | Crochet d'audit `sys.addaudithook` sur `socket.getaddrinfo`, `socket.connect`, `socket.sendto` ; refus = `NetworkGuardError`. Couvre toutes les bibliothèques (httpx, requests, urllib, asyncio). | `shared/config/network_guard.py` (copies : `agent/network_guard.py`, `agent/guard_site/network_guard.py`, `backend/python-ia/app/network_guard.py`) |
| Plan de contrôle Node (node-api) | `net.Socket.prototype.connect` enveloppé dès `startupGuard.ts`, avant le pool Postgres : fetch (undici), pg et tls passent tous par là ; refus = erreur `ENETGUARD`. | `backend/node-api/src/lib/networkGuard.ts` |
| Processus enfants de l'agent (`run_command`, git, tests d'un projet) | `run_tree` leur donne `network_guard.child_env()` : `guard_site/` en tête de `PYTHONPATH` (son `sitecustomize.py` installe la garde dans tout Python enfant), `--require guard_site/network_guard_child.cjs` dans `NODE_OPTIONS` (Node, npm, npx), mandataires HTTP(S) inaccessibles `127.0.0.1:9` pour les autres outils (git en https, curl). | `shared/config/guard_site/` → `agent/guard_site/` |

Installation :

- node-api : `startupGuard.ts`, importé en premier par `server.ts` ;
- python-ia : au démarrage (`lifespan` de `app/main.py`) ;
- agent : `build_executor` (partagé par l'agent V1, le superviseur et chaque worker). En OFFLINE, l'agent refuse
  de démarrer si `SOULBAH_API_URL` vise un hôte d'Internet (sinon la garde couperait son propre plan de contrôle).

Observabilité : refus comptés et 50 derniers hôtes refusés gardés en mémoire (`status()`), journalisés par
node-api ; exposés par `GET /v2/models` (python-ia, sans la liste des hôtes), dans `capabilities.network_guard`
envoyé par chaque runtime, et par `GET /api/v2/capabilities` (`network.guard`).

## 3. Preuves (sans dépendre d'Internet)

| Preuve | Test |
|---|---|
| Résolution DNS et connexion vers Internet refusées dans le processus ; connexion locale permise ; refus comptés | `agent/tests/test_v3_network_guard.py::test_in_process_dns_and_connect_refused_local_allowed` |
| Toutes les bibliothèques couvertes (requests) | `test_libraries_are_covered` |
| Processus Python de Soulbah séparé démarré en OFFLINE | `test_separate_agent_process_offline` |
| Processus Python enfant lancé par `run_tree` : refusé vers Internet, permis en local | `test_child_processes_inherit_the_guard` |
| Processus Node enfant (`node -e`) : `ENETGUARD` vers Internet, connexion locale permise | `test_node_child_inherits_the_guard` |
| Mêmes cas pour les trois implémentations | `test_common_cases_offline`, `test_node_child_guard_follows_common_cases`, `backend/node-api/test/v3NetworkGuard.test.ts`, `backend/python-ia/tests/test_v3_network_guard.py` |
| node-api : fetch et net.connect refusés (`ENETGUARD`), local permis ; HYBRID transparent | `v3NetworkGuard.test.ts` |
| python-ia : garde installée au démarrage ; hôtes des fournisseurs (Anthropic, OpenAI, Google) refusés avant DNS | `test_v3_network_guard.py` |
| Agent : démarrage refusé en OFFLINE avec un plan de contrôle sur Internet | `test_agent_refuses_offline_with_remote_control_plane` |

## 4. Limites

- **Pas de pare-feu système.** Un programme natif lancé par l'agent qui ignore les mandataires et ouvre ses propres
  sockets (rare : git par SSH, un binaire réseau maison) n'est arrêté que par le pare-feu Windows. Une règle par
  programme bloquerait aussi l'interpréteur Python de base partagé par toute la machine (les venv Windows lancent
  l'interpréteur de base) : non appliquée automatiquement. Les commandes réseau connues sont déjà refusées en amont
  (`git_push`, `npm install`, `browser_get`) et `git fetch` / `git clone` ne sont pas dans la liste autorisée.
- **Applications de bureau.** Une application ouverte pour l'utilisateur (navigateur, VS Code) n'hérite pas de la
  garde : elle n'est pas un processus de Soulbah.
- **Coupure réelle d'Internet.** Les tests prouvent le refus sans couper le réseau de la machine de développement.
  Le benchmark hors ligne final (LOT 17) devra aussi être exécuté adaptateur réseau désactivé.
- Le crochet d'audit Python est permanent dans un processus (propriété de `sys.addaudithook`) ; il ne bloque que
  tant que le mode reçu est OFFLINE.
