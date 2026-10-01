# `shared/models/` — profils et tarifs des modèles d'IA

Source unique, partagée par les services, des informations « métier » sur les modèles
(audit `docs/SOULBAH_V2_LOT0_AUDIT.md` §11).

| Fichier | Contenu | Consommateur |
|---|---|---|
| `pricing.json` | Tarifs **indicatifs** en USD par million de jetons (entrée / sortie), par fournisseur puis par modèle (identifiant exact ou préfixe ; `*` = tout modèle). `local` = 0. | `backend/python-ia/app/providers/usage.py` (`estimate_cost`, budget quotidien, totaux de consommation, en-tête `x-llm-usage`). |

Règles :

- Les tarifs sont ceux des API de première partie, à titre indicatif : ils servent au **métrage et
  aux plafonds** (`LLM_DAILY_BUDGET_USD`), jamais à la facturation. Un modèle absent → coût `null`
  (inconnu), qui ne compte pas dans le budget mais est compté dans `unknown_cost_calls`.
- `usage.py` embarque une copie (`_BUILTIN_PRICING`) pour fonctionner sans ce dossier (image Docker
  dont le contexte de build est `backend/python-ia`). Le test
  `tests/test_lot5_router.py::TestPricing::test_builtin_matches_shared_json` échoue à la moindre
  dérive entre les deux : modifier le JSON **puis** la copie Python.
- Surcharge sans code : `LLM_PRICING` (JSON, même forme que `providers`) ajoute ou corrige un tarif.
- Les profils par rôle (planner / evaluator / vision / cheap) restent pour l'instant dans
  `router.PROFILES` (variables `LLM_MODEL_<RÔLE>`) ; ils seront déplacés ici quand node-api en aura
  besoin.
