# LOT 5 — Model Router v2 (coûts, budgets, API `/v2/models`)

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §6 (T26), §9.2-9.3 (ligne « Model Router »),
§11 (`shared/models/` = profils et tarifs ; `providers/{capabilities,usage,circuit,fake}.py` ;
`app/v2/` = API du routeur), §13 ligne « 5. Model Router v2 » (critères : ≥ 25 nouveaux tests sans
appel payant ; la vision n'est jamais routée vers un modèle non-vision ; un override inconnu → 400).

Périmètre : `backend/python-ia` uniquement (+ `backend/.env.example`, `backend/docker-compose.yml`,
`shared/models/`, ce document). Aucun changement dans node-api, agent, supabase ni `shared/tools`.

## 1. Déjà présent au LOT 1 / ajouté au LOT 5

| Brique | Déjà présent (LOT 1, LOT 3) | Ajouté au LOT 5 |
|---|---|---|
| Résultat d'appel | `CompletionResult` (texte, jetons, stop_reason, troncature, latence, `fallback_from`) | `cost_usd` (None si tarif inconnu) dans le résultat, `usage()`, le log `llm_call` et l'en-tête `x-llm-usage` (`cost_usd` = somme des coûts connus, `null` si aucun) |
| Profils par rôle | `PROFILES` planner / evaluator / vision / cheap (`LLM_MODEL_<RÔLE>`, `LLM_EFFORT_<RÔLE>`) | plafond `LLM_MAX_OUTPUT_TOKENS_<RÔLE>` (table `OUTPUT_TOKEN_CAPS`), exposé dans `status()["profiles"][rôle]["max_output_tokens_cap"]` |
| Capacités explicites | `capabilities.py` (vision=False par défaut, `LLM_CAPABILITIES`) | — (couvert ; tests complémentaires : disjoncteur ouvert sur le seul fournisseur vision → 503, jamais un non-vision) |
| Disjoncteur | `CircuitBreaker` dans `router.py` | déplacé dans `providers/circuit.py`, réexporté par `router.py` et `providers/__init__.py` (aucun import existant cassé) |
| Allowlist des overrides | `LLM_ALLOWED_OVERRIDES` → 400 « non autorisé » / « non configuré » | vérifié depuis `/v2/models/complete` (inconnu, non autorisé, autorisé mais non configuré, autorisé → utilisé sans repli) |
| Deadline | `x-deadline-ms`, `_hop_timeouts`, budget implicite par tâche | respecté par `/v2/models/complete` (délai transmis au fournisseur, 504 sans appel si expiré, coupure d'un fournisseur lent) |
| FakeProvider | `providers/fake.py` (LOT 3) | utilisé pour tous les tests du lot |
| Tarifs | — | `shared/models/pricing.json` + copie intégrée `usage._BUILTIN_PRICING` (test de non-dérive), `estimate_cost()`, `price_for()`, surcharges `LLM_PRICING` / `LLM_PRICING_FILE` |
| Consommation | métrage par requête (`request_context`) | `UsageMeter` par processus : totaux jetons / coût / appels par fournisseur et par rôle, cumul du jour UTC, dans `status()["usage"]` |
| Budget | — | `LLM_DAILY_BUDGET_USD` : 402 `kind="budget"` avant tout appel, sans repli ; avertissement à 80 % puis « ATTEINT » (une fois par jour) |
| API V2 | `GET /providers` | `GET /v2/models` (même contenu que `/providers`, enrichi : tarifs, consommation) et `POST /v2/models/complete` |
| Effort | effort du profil / `LLM_EFFORT_DEFAULT` | paramètre `effort` de `Orchestrator.generate()` (imposé à tous les sauts), exposé par `/v2/models/complete` |

## 2. Fichiers

| Fichier | Rôle |
|---|---|
| `backend/python-ia/app/providers/circuit.py` | `CircuitBreaker` (code inchangé, extrait de `router.py`) |
| `backend/python-ia/app/providers/usage.py` | tarifs, `estimate_cost`, `UsageMeter`, budget quotidien |
| `backend/python-ia/app/providers/router.py` | plafond de jetons, contrôle de budget, coût par appel, compteur, `status()` enrichi, `effort` |
| `backend/python-ia/app/providers/base.py` | `CompletionResult.cost_usd` |
| `backend/python-ia/app/request_context.py` | `usage_summary()["cost_usd"]` (en-tête `x-llm-usage`) |
| `backend/python-ia/app/v2/{__init__,models}.py` | routeur FastAPI `/v2/models`, monté dans `main.py` sous le middleware commun |
| `backend/python-ia/tests/test_lot5_router.py` | 70 tests, FakeProvider uniquement |
| `shared/models/pricing.json`, `shared/models/README.md` | tarifs partagés et règles de maintenance |
| `backend/.env.example`, `backend/docker-compose.yml` | nouvelles variables (section « Coûts et budgets du routeur (LOT 5) », ancre `x-llm-router-env`) |

## 3. Variables

| Variable | Défaut | Effet |
|---|---|---|
| `LLM_MAX_OUTPUT_TOKENS_PLANNER` / `_EVALUATOR` / `_VISION` / `_CHEAP` | vide = valeur demandée | `max_tokens` effectif = min(demandé, plafond) pour les tâches à profil (`automation`, `evaluation`, `vision`, `routing`). Valeur non entière ou ≤ 0 : ignorée avec avertissement. Sans effet sur les tâches sans profil. |
| `LLM_DAILY_BUDGET_USD` | vide = illimité | coût cumulé estimé par jour UTC (mémoire du processus). Atteint → `LLMError(402, kind="budget")` **avant** tout appel, sans repli. Journal à 80 % puis à l'atteinte (une fois par jour). 0, négatif ou invalide = illimité. |
| `LLM_PRICING` | vide | JSON `{fournisseur: {modèle|préfixe|"*": {input, output}}}` ajoutant ou corrigeant un tarif (USD / 1M jetons). |
| `LLM_PRICING_FILE` | vide = copie intégrée | autre `pricing.json` fusionné avec la copie intégrée. |

Recherche d'un tarif : fournisseur → identifiant de modèle exact → plus long préfixe
(`claude-haiku-4-5-20251001` → `claude-haiku-4-5`, `mistral-large-latest` → `mistral-large`,
`gpt-4o-mini-2024-07-18` → `gpt-4o-mini` et non `gpt-4o`) → `*`. `local` = 0 pour tout modèle.
Inconnu → `None`, jamais 0.

## 4. API `/v2/models`

- `GET /v2/models` → `orchestrator.status()` : `providers` (capacités), `configured`, `default`,
  `routing`, `profiles` (modèle, effort, plafond de jetons, tarif), `allowed_overrides`,
  `circuit_breakers`, `pricing` (`"fournisseur:modèle"` → tarif ou `null` pour les modèles en jeu),
  `usage` (`total`, `by_provider`, `by_role`, `today`, `daily_budget_usd`, `budget_remaining_usd`,
  `budget_exhausted`). Aucun secret.
- `POST /v2/models/complete` : `{task="general", system="", messages[1..200]{role user|assistant,
  content ≤ 100 000}, json_schema?, images?[≤ 10, ≤ 6 Mo chacune], max_tokens=4096 [1..128000],
  provider?, effort? (low|medium|high|xhigh|max)}` → `{text, json?, usage}`. `json` = objet parsé
  (`llm._parse_json`, tolère les clôtures markdown) quand `json_schema` est fourni ; sinon 502
  « Réponse IA non parsable ». 400 si le dernier message n'est pas `user` ou si tout est vide ;
  422 hors bornes ; 401 sans `x-ia-token` quand `IA_SERVICE_TOKEN` est défini ; les erreurs du
  routeur (400 override, 402 budget, 429/502/503/504) remontent telles quelles.
- Rôle de consommation (`by_role`) : nom du profil si la tâche en a un, sinon la tâche.

## 5. Critères de sortie ↔ tests (`tests/test_lot5_router.py`)

| Critère (audit §13) | Tests |
|---|---|
| ≥ 25 nouveaux tests sans appel payant | 70 tests, tous sur `FakeProvider` (suite : 342 → 412) |
| La vision n'est jamais routée vers un modèle non-vision | `TestVisionNeverNonVision` (seul fournisseur vision en panne → 429 sans toucher les non-vision ; disjoncteur ouvert → 503 ; `/v2` images → fournisseur vision seulement ; override non-vision → 400 ; aucun modèle vision → 503) + LOT 1 `TestVisionRouting` |
| Un override inconnu renvoie 400 | `TestOverridesV2` (inconnu, autorisé mais non configuré, configuré mais non autorisé, autorisé → utilisé sans repli) + LOT 1 `TestOverrideAllowlist` |
| Métrage / coût | `TestPricing` (connu, préfixe, inconnu → None, local → 0, surcharges, non-dérive JSON ↔ copie intégrée), `TestCostInUsage` (`usage()`, log, en-tête `x-llm-usage`) |
| Budgets | `TestOutputTokenCaps` (plafond appliqué, défaut, tâches sans profil, valeurs invalides, `status`), `TestDailyBudget` (402 sans appel ni repli, illimité, 80 % puis atteint, reset au jour UTC suivant, coût inconnu non compté, 402 via endpoints) |
| Disjoncteur extrait | `TestCircuitModule` (import depuis `circuit.py`, réexports, cycle fermé → ouvert → semi-ouvert → fermé) |
| API V2 | `TestV2ModelsEndpoints` (statut, égalité avec `/providers`, texte, JSON, squelette, 502 non parsable / vide, effort, 422, 400, 401, deadline transmise / expirée / coupure, 400 en-tête invalide) |
| Totaux de consommation | `TestConsumptionTotals` (par fournisseur et rôle, sauts échoués non comptés, réponse tronquée comptée, survie à `set_providers`, exposition HTTP) |

Commandes : `cd backend/python-ia && ./.venv/Scripts/python.exe -m pytest -q` (412 verts) ;
`./.venv/Scripts/python.exe -m compileall -q app` ; `backend/python-ia/.venv/Scripts/python.exe
scripts/ci/check_compose_env.py` (OK, 96 variables).

## 6. Décisions

- **Copie intégrée des tarifs** : l'image Docker de python-ia a pour contexte `backend/python-ia`
  et ne voit pas `shared/`. `usage.py` embarque donc la table ; `pricing.json` reste la source
  partagée et un test échoue à la moindre dérive (même principe que le catalogue d'outils du LOT 2).
- **Tarifs indicatifs** : Claude Opus 5.5 4 / 20, Sonnet 5.5 2 / 10, Haiku 4.5 1 / 5 (API Anthropic
  de première partie) ; les autres fournisseurs reprennent leurs tarifs publics courants. Ils servent
  au métrage et aux plafonds, pas à la facturation ; `LLM_PRICING` corrige sans redéploiement.
- **Coût inconnu = `None`, hors budget** : un modèle sans tarif ne doit ni passer pour gratuit ni
  bloquer la production ; il est compté dans `unknown_cost_calls`, visible dans `GET /v2/models`.
- **Compteur par processus** : en mémoire, remis à zéro au redémarrage et par jour UTC pour le
  budget (le cumul global `total` ne l'est pas). La persistance (table `tool_calls` / coûts par
  session) relève du plan de contrôle node-api (lots ultérieurs), qui lit `x-llm-usage`.
- **Contrôle de budget après `plan_hops`** : une requête invalide (override refusé, aucun modèle
  vision) reste 400/503 même budget épuisé ; le 402 n'est levé que pour un appel qui aurait eu lieu.
- **Bornes pydantic dupliquées dans `app/v2/models.py`** : importer `main.py` depuis `v2` créerait un
  cycle (main monte v2) ; les valeurs sont identiques et commentées comme telles.
- **`effort` ajouté à `Orchestrator.generate()`** (paramètre optionnel, défaut inchangé) : nécessaire
  au relais générique ; `complete()` et les appelants existants ne changent pas.
- **Rôle de consommation** : profil si la tâche en a un, sinon la tâche (`general`, `chat`…), pour
  que toute consommation soit attribuable sans table supplémentaire.

## 7. Plan de contrôle (node-api) : métrage dans `soulbah.tool_calls`

Critère §13 « métrage dans `tool_calls` » (table créée au LOT 4, migration 7/12) :

- `backend/node-api/src/lib/requestStore.ts` : contexte de requête (`AsyncLocalStorage`) installé par
  `app.ts` (hook `onRequest`) ; `currentUserId()` = utilisateur JWT ou propriétaire de la clé agent.
- `backend/node-api/src/services/llmUsage.ts` : `parseLlmUsage` lit désormais `cost_usd` (null si aucun
  tarif connu) ; `recordLlmUsage(path, usage, ctx?)` agrège, journalise et **écrit une ligne**
  `soulbah.tool_calls` (`kind='model'`, `name` = chemin pointé « agent.plan », fournisseur/modèle quand un
  seul couple a servi, jetons, `cost_usd`, `metadata.{path,calls,models,cost_known}`) pour l'utilisateur
  du contexte ou de la requête courante. Sans utilisateur attribuable, base non prête ou `calls = 0` :
  aucune ligne. Jamais bloquant (`void` dans `clients/iaClient.ts`).
- Tests : `test/toolCalls.test.ts` (FakeDb : parse, nom, couple fournisseur/modèle, contexte explicite,
  requête JWT / clé agent, aucun appel, erreur d'écriture) ; `test/integration/toolCalls.pg.test.ts`
  (Postgres réel : lignes écrites avec le schéma du LOT 4, coût NULL quand inconnu, cumul du jour par
  utilisateur sur l'index partiel `kind='model'`).
- Le budget quotidien **durable** par utilisateur (lecture de `tool_calls`, `user_settings.daily_budget_usd`)
  et son application avant l'appel relèvent du LOT 6 ; python-ia garde son plafond par processus
  (`LLM_DAILY_BUDGET_USD`).

