# V3 LOT 3 — Routeur de modèles local

Source : mission V3 §5 (Local Model Router par tâche), §8 (HYBRID : local prioritaire), §47 (repli Grand → Moyen →
Petit, jamais vers le cloud en OFFLINE), §80 (indépendance des fournisseurs). S'appuie sur le routeur V2 de
python-ia (`app/providers/router.py`) au lieu de le remplacer.

## 1. Serveurs locaux par rôle

| Variable | Fournisseur | Utilisé pour |
|---|---|---|
| `LOCAL_LLM_URL` (+ `LOCAL_LLM_MODEL`) | `local` | Toutes les tâches (serveur général) |
| `LOCAL_LLM_URL_PLANNER` | `local_planner` | Planification (`automation`) |
| `LOCAL_LLM_URL_EVALUATOR` | `local_evaluator` | Évaluation (`evaluation`) |
| `LOCAL_LLM_URL_VISION` | `local_vision` | Vision : déclaré capable de lire des images |
| `LOCAL_LLM_URL_CHEAP` | `local_cheap` | Classification rapide (`routing`) |
| `LOCAL_LLM_URL_CODE` | `local_code` | Génération de code (`code`) |
| `LOCAL_LLM_URL_SMALL` | `local_small` | Repli vers un modèle plus petit |

Chaque `LOCAL_LLM_MODEL_<RÔLE>` nomme le modèle servi. Hors HYBRID, chaque URL doit viser une machine de
l'utilisateur (bouclage, nom local, hôte déclaré), sinon le fournisseur n'est pas construit et apparaît dans
`blocked_by_mode`. Tout serveur local accepte le JSON contraint par schéma (`response_format.schema`, grammaire
llama.cpp).

Sur une machine de 8 Go, un seul serveur général (`LOCAL_LLM_URL`) suffit au départ : les autres variables servent
quand plusieurs modèles peuvent tourner, ou sur une machine du réseau local.

## 2. Ordre des tentatives

Chaîne locale d'une tâche : serveur du rôle → serveur général → petit modèle. Puis, selon `model_policy` :

| `SOULBAH_MODEL_POLICY` | Ordre |
|---|---|
| `auto` (défaut) | chaîne locale, puis fournisseurs cloud (HYBRID seulement) |
| `local-only` | chaîne locale seulement, même en HYBRID |
| `cloud-first` | cloud d'abord, puis chaîne locale (ordre V2) |
| `fournisseur[:modèle]` | ce fournisseur (et ce modèle) d'abord, puis le reste |

En OFFLINE et LOCAL_INTERNET, les fournisseurs cloud ne sont jamais construits (LOT 1) : une politique qui nomme un
fournisseur cloud retombe sur la chaîne locale. Le disjoncteur et la limite de sauts du routeur V2 s'appliquent
aux serveurs locaux comme aux autres. Le chat de node-api suit la même politique.

`GET /v2/models` expose `model_policy` et `local_chains` (chaîne par tâche).

## 3. Preuves

`backend/python-ia/tests/test_v3_lot3_router.py` (8 tests) : chaîne spécialisé → général → petit ; local avant le
cloud en HYBRID ; `cloud-first`, `local-only`, fournisseur et modèle imposés ; OFFLINE jamais vers le cloud ; serveur
de vision local seul retenu pour une image ; serveur d'un rôle sur Internet refusé hors HYBRID.
`backend/node-api/test/v3Lot1Modes.test.ts` : ordre du chat selon la politique.

## 4. Limites

- Le routeur choisit parmi des serveurs déjà démarrés ; il ne charge ni ne décharge un modèle à la demande.
  Le Resource Manager (LOT 6) décidera quand changer de modèle selon la RAM.
- Le choix « sur mesures » s'appuie aujourd'hui sur la configuration : le banc d'essai du LOT 2 range ses
  résultats dans le registre, l'affectation automatique d'après ces scores viendra avec les modèles réels.
