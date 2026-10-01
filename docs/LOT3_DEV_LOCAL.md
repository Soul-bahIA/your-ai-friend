# LOT 3 — Base locale, auth de développement, FakeProvider, CI

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §12 (chemin pgvector), §13 ligne « 3. Base
locale, auth de dev, CI », §15 (stratégie de tests : « Fastify inject avec un JWT de dev »,
« PG18 local avec stub vectoriel »).

## 1. Objectif

Développer et tester **toute la pile sans Supabase, sans clé d'IA et sans réseau** :

| Brique | Avant le LOT 3 | Après |
|---|---|---|
| Base de données | Supabase (en pause depuis l'audit) ou rien | PostgreSQL local jetable, schéma du dépôt appliqué ×2 (`scripts/dev_db/`) |
| Auth des routes JWT | vérification `/auth/v1/user` chez Supabase | `AUTH_MODE=dev-local` : jeton de dev partagé, boucle locale uniquement |
| Modèles d'IA | une clé fournisseur obligatoire | `LLM_FAKE_PROVIDER=1` : fournisseur factice déterministe (`app/providers/fake.py`) |
| Tests node-api | unitaires avec `FakeDb` | + intégration : Fastify inject sur un **vrai** Postgres (`test/integration/`) |
| CI | job `db` (migrations ×2) | + tests d'intégration node-api dans le job `db`, `tsc -b` du frontend |

Rien de tout cela n'est actif par défaut : `AUTH_MODE=supabase`, `LLM_FAKE_PROVIDER` vide, suite
d'intégration sautée sans `TEST_DATABASE_URL`.

## 2. Base locale jetable : `scripts/dev_db/`

```bash
bash scripts/dev_db/dev_db.sh up      # init + start + migrate + seed → .dev_db/dev.env
bash scripts/dev_db/dev_db.sh test    # tests d'intégration node-api sur cette base
bash scripts/dev_db/dev_db.sh status | stop | start | psql | reset | destroy
# PowerShell : powershell -ExecutionPolicy Bypass -File scripts\dev_db\dev_db.ps1 up
```

- **Cluster** : `initdb`/`pg_ctl` dans `.dev_db/pg` (hors git), écoute **127.0.0.1:54329**
  (`DEV_DB_PORT`), authentification `trust` (base de dev, aucune donnée réelle). Binaires détectés
  dans le PATH, via `pg_config`, ou dans `C:\Program Files\PostgreSQL\<version la plus récente>\bin`
  (`PG_BIN` pour forcer). Les chemins avec espaces sont gérés en mettant le dossier en tête du PATH.
- **Schéma** : `scripts/ci/auth_stub.sql` (stub de Supabase : rôles, `auth.users`, `auth.uid()`,
  publication) puis **toutes** les migrations de `supabase/migrations/`, appliquées **deux fois** avec
  comparaison de schéma et assertions (`scripts/ci/apply_migrations.sh --checks`), exactement comme
  le job CI `db`. Les 4 migrations de février 2026 n'étant pas rejouables, `migrate` ne s'exécute
  qu'une fois par cluster : `reset` repart de zéro (le jeton de `dev.env` est conservé).
- **pgvector** : absent de PG18 sous Windows (ni binaire, ni MSVC). Le DDL vectoriel est réécrit à
  la volée (`CREATE EXTENSION vector` supprimé, `vector(N)` → `real[]`, index HNSW sautés). Tout le
  schéma est validé **sauf** la sémantique vectorielle, couverte par le job CI `db` (image
  `pgvector/pgvector`). Si pgvector est disponible, le script l'utilise tel quel.
- **Seed** (`seed_dev.sql`, idempotent) : utilisateur de dev fixe `a0000000-0000-4000-8000-000000000001`
  (`dev@soulbah.local`, profil et rôle créés par le trigger `handle_new_user`) et une clé agent
  (hash SHA-256 en base, clé en clair dans `dev.env`) dont `allowed_dirs` = `~/SoulbahWorkspace`
  (`SOULBAH_WORKSPACE`).
- **`.dev_db/dev.env`** (mode 600, ignoré par git) : `DATABASE_URL`, `AUTH_MODE=dev-local`,
  `DEV_LOCAL_USER_ID`, `DEV_LOCAL_TOKEN`, `LLM_FAKE_PROVIDER=1`, `IA_SERVICE_URL`, et pour l'agent
  `SOULBAH_API_URL`, `SOULBAH_AGENT_KEY`, `SOULBAH_ALLOWED_DIRS`, plus `TEST_DATABASE_URL`.
  Charger : `set -a && source .dev_db/dev.env && set +a`.

Garde-fous : `apply_migrations.sh` **refuse** une base qui ressemble à un vrai projet Supabase
(`supabase_migrations` ou `auth.users.encrypted_password` présents) ; le seed n'est jamais exécuté
ailleurs que sur ce cluster.

## 3. `AUTH_MODE=dev-local` (node-api)

| Élément | Fichier |
|---|---|
| Configuration (`authMode`, `devLocalUserId`, `devLocalToken`) | `backend/node-api/src/config.ts` |
| Garde-fous de démarrage | `backend/node-api/src/lib/envChecks.ts` |
| `requireUser` | `backend/node-api/src/auth.ts` |
| Tests | `backend/node-api/test/devLocalAuth.test.ts` |

Règles, toutes vérifiées **avant toute connexion** (`startupGuard.ts`, sortie 1 sinon) :

1. `AUTH_MODE` ∈ { `supabase` (défaut), `dev-local` } ; toute autre valeur refuse le démarrage.
2. `dev-local` est **interdit hors `SOULBAH_ENV=dev|test`**, même parfaitement configuré.
3. `dev-local` exige `HOST` en boucle locale (`127.0.0.1`, `localhost`, `::1` ; vide = `127.0.0.1`).
   `HOST=0.0.0.0` refuse le démarrage : c'est pourquoi ce mode n'existe pas sous Docker
   (`scripts/ci/check_compose_env.py` l'exclut explicitement).
4. `DEV_LOCAL_TOKEN` ≥ 32 caractères, `DEV_LOCAL_USER_ID` uuid.

À l'exécution, `requireUser` en mode dev-local **n'appelle jamais Supabase** : pair non local → 403,
jeton absent ou différent (comparaison en temps constant) → 401, sinon `request.user` =
`{ id: DEV_LOCAL_USER_ID, email: "dev@soulbah.local" }`. La clé de limitation de débit reconnaît
cet utilisateur sans requête. Les routes à clé agent (`x-agent-key`) sont inchangées : la clé du seed
est une vraie clé hachée en base.

## 4. `LLM_FAKE_PROVIDER=1` (python-ia)

- `backend/python-ia/app/providers/fake.py` : `FakeProvider` (ex-`tests/fakes.py`, que les tests
  réexportent). Sans script, il répond un **squelette conforme au `json_schema`** demandé
  (`skeleton_from_schema` : champs requis avec une valeur neutre) ou `{"ok": true}`. Il déclare la
  vision et le JSON natif ; usage 11/7 jetons, `stop_reason=end_turn`.
- `registry.build_providers()` renvoie **uniquement** `{"fake": …}` quand la variable vaut
  `1|true|yes|on` : toutes les clés fournisseur sont ignorées. Le routage par tâche retombe sur le
  fournisseur par défaut, donc sur `fake`.
- Refusé hors dev/test : `config.check_startup_config()` lève `RuntimeError` (le service ne démarre
  pas) et `build_providers()` aussi (défense en profondeur). En dev/test, un avertissement est journalisé.
- Il valide la **plomberie** (jeton inter-services, routage, délais, usage, en-têtes, parsing), jamais
  la qualité : sans script, `/agent/plan` renvoie `feasible=false` et aucune étape.
- Tests : `backend/python-ia/tests/test_fake_provider.py`.

## 5. Tests d'intégration node-api sur Postgres

`backend/node-api/test/integration/agentQueue.pg.test.ts`, exécuté par `npm run test:pg` (ou `npm
test`, où il est **sauté** sans `TEST_DATABASE_URL`). Il démarre l'application réelle (`buildApp`) en
dev-local sur la base indiquée, crée son propre utilisateur dans `auth.users` et deux clés agent, puis
vérifie de bout en bout : 401 sans jeton, 401 clé agent inconnue, création d'une tâche ciblant la
seule clé, poll, **claim → 200 puis 409**, disparition du poll, heartbeat (attempt courant 200,
périmé 409), évènement `step_done` avec `source=agent`, final `completed` (mauvais attempt 409, bon
attempt 200, rejeu 409), liste et suppression, ciblage d'un second PC (400 sans `agent_key_id`, 409
pour la mauvaise clé), annulation en cours → `control=stop` → final `cancelled`. Il nettoie ses lignes.

En local : `bash scripts/dev_db/dev_db.sh test`. En CI : job `db`, après les migrations, sur le même
conteneur (`TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/postgres`).

## 6. CI (`.github/workflows/ci.yml`)

| Point de l'audit | État |
|---|---|
| `tsc` racine (T35) | Frontend : `npx tsc -b` type `tsconfig.app.json` **et** `tsconfig.node.json` (`vite.config.ts`). node-api : `tsc --noEmit` déjà en place. |
| Job `db` épinglé sur la version Supabase | **Impossible au 2026-10-01** : le projet est toujours en pause (le pooler répond « tenant not found » à `SHOW server_version`). `pgvector/pgvector:pg17` reste l'hypothèse provisoire ; le job affiche désormais la version du serveur et de pgvector pour la comparaison le jour de la reprise (`docs/SUPABASE_REPRISE.md` §3). |
| Job `db` + node-api | Le service Postgres publie le port 5432 ; après les migrations ×2 et les assertions, `npm run test:pg`. |
| `windows-latest` | Déjà en place depuis le LOT 1 (job `agent`, imports réels de pyautogui/mss). |
| Police PDF (T6) | Déjà corrigé au LOT 1 (DejaVu TTF embarquées, tests multi-pages non-Windows). |

## 7. Critères de sortie (audit §13) et preuves

| Critère | Preuve |
|---|---|
| Migrations ×2 sans erreur, en local | `dev_db.sh up` sur PG 18.1 (Windows, stub vectoriel) : 19 migrations appliquées, 15 rejouées, schéma identique, assertions et contrôles post-restauration passés |
| Migrations ×2 sans erreur, en CI | job `db` (inchangé sur ce point) ; run vert à obtenir après le push |
| Test HTTP poll/claim/409 réussi | `agentQueue.pg.test.ts` : 12 tests verts sur la base locale (`dev_db.sh test`) ; même suite dans le job `db` |
| Un run CI vert, avec son URL | **à compléter après le push** (`https://github.com/Soul-bahIA/your-ai-friend/actions`) : la CI n'a jamais tourné sur ce dépôt, le premier run peut révéler des écarts Ubuntu/Windows |

État au 2026-10-01 : node-api 209 tests unitaires + 12 d'intégration, python-ia 342, agent 488,
`tsc` propre (node-api et `tsc -b` frontend), `check_compose_env.py` OK (89 variables).

## 8. Procédure de développement hors Docker

```bash
bash scripts/dev_db/dev_db.sh up
set -a && source .dev_db/dev.env && set +a
(cd backend/python-ia && .venv/Scripts/python -m uvicorn app.main:app --port 8000)   # LLM factice
(cd backend/node-api && npm run dev)                                                  # dev-local + base locale
curl -H "Authorization: Bearer $DEV_LOCAL_TOKEN" http://127.0.0.1:3000/api/agent-tasks
# agent local : agent/.env ← SOULBAH_API_URL, SOULBAH_AGENT_KEY, SOULBAH_ALLOWED_DIRS de dev.env
```

Le frontend (`VITE_API_URL=http://127.0.0.1:3000`) continue d'exiger un JWT Supabase : son usage
en dev-local (jeton de dev côté client) est hors périmètre de ce lot.
