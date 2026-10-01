# Reprise du projet Supabase — check-list ordonnée

> À suivre **dans l'ordre**, le jour où le projet Supabase (`ntvwbafvjgzsjoumtcmb`, cf.
> `supabase/config.toml`) est réactivé. Source : audit LOT 0
> ([`SOULBAH_V2_LOT0_AUDIT.md`](SOULBAH_V2_LOT0_AUDIT.md) §12, §13, annexe) et contrat LOT 1
> ([`LOT1_CONTRAT.md`](LOT1_CONTRAT.md)). Commandes pour ce PC Windows (PowerShell ou git-bash).
>
> **Interdits** (audit §12 « Jamais ») : exécuter `RESTAURATION_BASE.sql` sur ce projet ;
> modifier le CHECK de statut d'`agent_tasks` ; ajouter une FK sur `agent_events.task_id` ;
> supprimer `modules_status`.

## 0. Outils à avoir sous la main

- Outils client PostgreSQL ≥ version du serveur (`C:\Program Files\PostgreSQL\18\bin` : `psql`, `pg_dump`, `pg_restore`).
- Supabase CLI (`npm i -g supabase` ou `scoop install supabase`).
- `gpg` (fourni par Git for Windows) ou `age`, pour chiffrer les sauvegardes.
- Le mot de passe de la base (`postgres`) : tableau de bord → *Project Settings → Database*.

Ne jamais coller un mot de passe dans une ligne de commande : utiliser `backend/.env`,
`$env:BACKUP_DATABASE_URL` le temps d'une session, ou `SUPABASE_DB_PASSWORD` pour la CLI.

## 1. Restaurer le projet

Tableau de bord Supabase → projet → **Restore project**. Attendre l'état *Healthy*.
Si la restauration n'est plus proposée (pause trop longue), télécharger la sauvegarde
offerte par le tableau de bord et la restaurer dans un nouveau projet ; mettre alors à jour
`project_id` (`supabase/config.toml`), `frontend/.env` et `backend/.env`.

## 2. Sauvegarde IMMÉDIATE (avant toute autre action)

```powershell
# Chiffrement symétrique : phrase de passe dans un fichier HORS du dépôt
$env:BACKUP_GPG_PASSPHRASE_FILE = "$env:USERPROFILE\.soulbah\backup_passphrase.txt"
powershell -ExecutionPolicy Bypass -File scripts\backup_db.ps1
```

- Le script lit `DATABASE_URL` dans `backend/.env` (ou `$env:BACKUP_DATABASE_URL`), passe de
  6543 à 5432 pour le pooler, et transmet le mot de passe via un fichier pgpass temporaire
  (jamais en argument). Sans variable de chiffrement, il **refuse** de s'exécuter (code 2),
  sauf `BACKUP_ALLOW_PLAINTEXT=1` (S30).
- Le dump garde les droits (GRANT/REVOKE) : une restauration ne rend pas `has_role` /
  `is_admin` à `anon` (S19). Procédure de restauration : `README.md`, « Sauvegardes ».
- Vérifier : deux fichiers `backups\soulbah_AAAAMMJJ_HHMM.{dump,sql}[.gpg]` non vides. Contrôle
  de lecture du dump : le déchiffrer dans un dossier temporaire, puis `pg_restore -l <fichier>.dump`.
- Copier les fichiers chiffrés hors du PC (disque externe, stockage cloud).

## 3. Version du serveur → épingler la CI

```sql
SHOW server_version;
SELECT extversion FROM pg_extension WHERE extname = 'vector';
```

Dans `.github/workflows/ci.yml`, job `db`, remplacer l'image provisoire
`pgvector/pgvector:pg17` par la **même version majeure** que Supabase. Pour être exact,
épingler aussi pgvector, par exemple `pgvector/pgvector:0.8.0-pg15` si la requête renvoie
pgvector 0.8.0 sur PostgreSQL 15. Attendre ensuite un run CI vert (job `db` : migrations ×2
+ assertions avec le vrai pgvector) **avant** l'étape 5.

## 4. État réel du schéma distant

```powershell
supabase link --project-ref ntvwbafvjgzsjoumtcmb     # demande le mot de passe (ou $env:SUPABASE_DB_PASSWORD)
supabase migration list                               # colonnes Local / Remote
```

Contrôles SQL (éditeur SQL du tableau de bord) :

```sql
-- Historique des migrations connu de la CLI
SELECT version FROM supabase_migrations.schema_migrations ORDER BY version;
-- hardening (20261001000000) appliquée ?
SELECT count(*) FROM pg_constraint WHERE conname IN ('agent_tasks_status_check', 'agent_tasks_control_check');
-- LOT 1 (20261001090000_lot1_fixes) appliquée ?
SELECT count(*) FROM information_schema.columns
 WHERE table_name = 'agent_tasks' AND column_name IN ('target_agent_key_id', 'claimed_by_key_id');
-- Suite LOT 1 (20261001100000_lot1_verif) appliquée ?
SELECT to_regclass('public.idx_agent_memory_goal_gin_trgm') IS NOT NULL AS lot1_verif;
-- Policies qui utilisent encore has_role (créées à la main ?) : doit être vide (vague G4)
SELECT schemaname, tablename, policyname FROM pg_policies
 WHERE qual ~ 'has_role' OR with_check ~ 'has_role';
```

La migration LOT 1 s'appelait `20261002000000_lot1_fixes.sql` avant d'être renommée en
`20261001090000_lot1_fixes.sql` (sa date était dans le futur : toute migration créée le
jour même avec `supabase migration new` se serait classée avant elle). Si une base a reçu
l'ancienne version (`schema_migrations` contient `20261002000000`), la marquer comme
annulée puis laisser `db push` appliquer la nouvelle, qui est idempotente :

```powershell
supabase migration repair --status reverted 20261002000000
```

Si des migrations ont été appliquées à la main (éditeur SQL) et manquent dans
`schema_migrations`, `supabase db push` tenterait de les rejouer. Les 4 migrations de
février ne sont **pas** rejouables. Après avoir vérifié leurs objets, les marquer comme
appliquées :

```powershell
supabase migration repair --status applied 20260218031213   # une commande par version vérifiée
```

Les migrations à partir de `20260703000000` sont rejouables, ce que la CI vérifie : en cas
de doute, les laisser à `db push`.

## 5. Appliquer les migrations

```powershell
supabase db push --dry-run    # attendu : hardening, lot1_fixes et/ou lot1_verif
supabase db push
```

Chaque migration s'exécute dans sa propre transaction. Les NOTICE « non validée » signalent
des lignes historiques qui violent une nouvelle contrainte : elle reste `NOT VALID`, sans
erreur (voir l'étape 7). Un WARNING « G4 non appliquée » signale une policy (créée hors
migrations) qui appelle encore `has_role` : la réécrire avec `public.is_admin()`, puis
exécuter `REVOKE EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) FROM authenticated;`.

**Déployer le front du même commit** que les migrations : `lot1_verif` retire au client
l'écriture directe dans `knowledge_base`, `agent_memory` et `agent_keys`, et la suppression
directe dans `agent_tasks` (vagues G2/G3 de l'audit §12 ; le front actuel passe par l'API).
Un ancien front encore en ligne verrait ces écritures refusées (INSERT) ou sans effet
(UPDATE/DELETE).

## 6. Supprimer les 5 anciennes edge functions

Leur logique vit dans `backend/node-api` (voir `backend/MIGRATION.md`). Elles ne sont plus
dans le dépôt mais peuvent encore être déployées :

```powershell
supabase functions list --project-ref ntvwbafvjgzsjoumtcmb
supabase functions delete chat                 --project-ref ntvwbafvjgzsjoumtcmb
supabase functions delete generate-formation   --project-ref ntvwbafvjgzsjoumtcmb
supabase functions delete generate-application --project-ref ntvwbafvjgzsjoumtcmb
supabase functions delete manage-database      --project-ref ntvwbafvjgzsjoumtcmb
supabase functions delete agent-tasks          --project-ref ntvwbafvjgzsjoumtcmb
supabase functions list --project-ref ntvwbafvjgzsjoumtcmb   # doit être vide
```

## 7. Contraintes NOT VALID et lignes orphelines

```sql
-- Contraintes non validées (hardening + LOT 1 : FK user_id, CHECK, FK agent_keys)
SELECT conrelid::regclass AS table_name, conname, contype
  FROM pg_constraint
 WHERE connamespace = 'public'::regnamespace AND NOT convalidated
 ORDER BY 1, 2;

-- Orphelins user_id → auth.users (une ligne par table concernée)
SELECT t.relname, (xpath('/row/n/text()',
         query_to_xml(format('SELECT count(*) AS n FROM public.%I x
                               WHERE x.user_id IS NOT NULL
                                 AND NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = x.user_id)',
                             t.relname), false, true, '')))[1]::text::int AS orphelins
  FROM pg_class t
  JOIN pg_attribute a ON a.attrelid = t.oid AND a.attname = 'user_id' AND NOT a.attisdropped
 WHERE t.relnamespace = 'public'::regnamespace AND t.relkind = 'r'
 ORDER BY 2 DESC;

-- agent_tasks → agent_keys (colonnes LOT 1)
SELECT count(*) FROM public.agent_tasks t
 WHERE (t.target_agent_key_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.agent_keys k WHERE k.id = t.target_agent_key_id))
    OR (t.claimed_by_key_id   IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.agent_keys k WHERE k.id = t.claimed_by_key_id));

-- Valeurs hors CHECK (LOT 1) dans agent_memory
SELECT level, status, count(*) FROM public.agent_memory
 WHERE status NOT IN ('proposed', 'validated', 'rejected')
    OR level  NOT IN ('working', 'project', 'user', 'technical', 'documentary', 'workflow', 'error', 'optimization')
 GROUP BY 1, 2;

-- Tâches in_progress orphelines (agent arrêté pendant la pause)
SELECT id, task_type, updated_at FROM public.agent_tasks WHERE status = 'in_progress' ORDER BY updated_at;
```

Puis les contrôles de droits, RLS et policies (lecture seule ; échec avec un message qui
dit quoi corriger) : coller `scripts/sql/post_restore_checks.sql` dans l'éditeur SQL, ou

```powershell
psql "<URL postgres>" -X -v ON_ERROR_STOP=1 -f scripts\sql\post_restore_checks.sql
```

- `agent_events.task_id` n'a volontairement **pas** de FK : ses orphelins sont purgés par la
  maintenance de node-api (3 jours).
- Corriger ou supprimer les orphelins **seulement après** la sauvegarde de l'étape 2, puis
  valider : `ALTER TABLE public.<table> VALIDATE CONSTRAINT <nom>;`. La validation
  systématique des CHECK relève de la vague G6 (audit §12) : ne pas la forcer si des lignes
  historiques posent question.
- Les tâches `in_progress` orphelines seront reprises ou annulées par le reaper de node-api
  au démarrage. On peut aussi les passer en `failed` à la main.

## 8. Rotation des secrets

| Secret | Action |
|---|---|
| **Clé agent** affichée en clair lors du premier audit | Page *Sécurité* de l'app → révoquer la clé (DELETE `/api/agent-keys/:id`), en créer une nouvelle, la copier dans `agent/.env` (`SOULBAH_AGENT_KEY`). Elle n'est affichée qu'une fois. Les clés **n'expirent pas** en V1 (S20, partie « expiration » reportée au LOT 4 : colonne `expires_at` de la table des agents, audit §12) : les faire tourner à la main. |
| **Mot de passe `postgres`** | Le réinitialiser (*Project Settings → Database → Reset database password*) au moment de l'étape 10 : node-api n'utilisera plus `postgres`. Le nouveau mot de passe ne sert qu'aux sauvegardes et migrations et n'est stocké dans aucun `.env` permanent. |
| Clés des fournisseurs IA (`backend/.env`) | À faire tourner seulement si elles ont pu fuiter. |
| **Clé anon** (dans l'historique git public, `.env` du commit `55b39dd`) | Aucune action : publique **par conception** (embarquée dans le front, bornée par la RLS ; S33). Seule cette empreinte est tolérée par gitleaks (`.github/.gitleaksignore`). Une clé `service_role` ne doit jamais être commitée ni ajoutée à cette liste. |

## 9. Variables d'environnement (contrat LOT 1 §1)

Dans `backend/.env`, lu à la fois par node-api et par python-ia :

```dotenv
SOULBAH_ENV=dev                 # dev | test | staging | production
IA_SERVICE_TOKEN=<aléatoire>    # même valeur pour node-api et python-ia
DATABASE_SSL=true
PG_SSL_CA=C:\Users\SOUL-BAH\.soulbah\supabase-ca.crt
```

- **IA_SERVICE_TOKEN** se génère ainsi :
  `python -c "import secrets; print(secrets.token_urlsafe(48))"`.
  Hors `dev`/`test`, node-api et python-ia **refusent de démarrer** sans lui.
- **PG_SSL_CA**, le certificat CA de Supabase :
  1. Le télécharger : tableau de bord → *Project Settings → Database → SSL Configuration →
     Download certificate* (fichier `prod-ca-2021.crt`).
  2. L'enregistrer **hors du dépôt**, par exemple `%USERPROFILE%\.soulbah\supabase-ca.crt`.
  3. Définir `PG_SSL_CA` avec ce chemin, et `DATABASE_SSL=true`.

  Sous Docker, monter le fichier dans le conteneur et donner le chemin **interne**. Hors
  `dev`/`test`, node-api refuse de démarrer si `DATABASE_SSL=true` sans `PG_SSL_CA`.
  Vérification manuelle :
  ```powershell
  psql "host=<hôte> port=5432 dbname=postgres user=<utilisateur> sslmode=verify-full sslrootcert=$env:USERPROFILE\.soulbah\supabase-ca.crt" -c "select 1"
  ```
  Les sauvegardes peuvent utiliser le même CA : `$env:PGSSLMODE='verify-full'; $env:PGSSLROOTCERT='<chemin>'`.

## 10. Rôle de moindre privilège pour node-api (S4)

Aujourd'hui, node-api se connecte en `postgres`, qui peut tout faire : DDL, schéma `auth`,
toutes les tables. Le rôle `soulbah_api` limite le rayon d'action aux seules tables et
opérations que node-api utilise. Inventaire relevé dans `backend/node-api/src` (requêtes
SQL) au LOT 1.

Les droits sont dans **`scripts/sql/soulbah_api_grants.sql`** (source unique). La CI vérifie
qu'ils couvrent chaque requête SQL de node-api (`scripts/ci/check_api_grants.py`) et les
exécute réellement en `soulbah_api` (`scripts/ci/api_role_checks.sql`).

Limite à connaître : node-api filtre lui-même chaque requête par `user_id`, et les routes de
l'agent (clé `x-agent-key`) n'ont pas de JWT. Le rôle garde donc **BYPASSRLS**, comme
aujourd'hui. Pour appliquer réellement la RLS à node-api, il faudrait poser
`SET LOCAL ROLE authenticated` et `request.jwt.claims` à chaque requête, ce qui demande des
changements de code dans un lot ultérieur.

```sql
-- À exécuter en `postgres` (éditeur SQL). Mot de passe fort, généré, jamais commité.
CREATE ROLE soulbah_api LOGIN PASSWORD '<mot de passe fort>'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOINHERIT BYPASSRLS;
ALTER ROLE soulbah_api SET search_path = public, extensions;   -- opérateurs pgvector (<=>)
ALTER ROLE soulbah_api SET statement_timeout = '60s';

-- Puis : coller ici le contenu de scripts/sql/soulbah_api_grants.sql et l'exécuter.
-- (Résumé : SELECT/INSERT/UPDATE/DELETE sur agent_tasks, agent_events, agent_keys,
--  agent_memory, knowledge_base, user_schemas, user_table_data ; SELECT/INSERT/UPDATE sur
--  formations, applications, analysis_requests, knowledge_domains ; SELECT/INSERT sur
--  knowledge_versions, user_migrations ; INSERT sur system_logs ; EXECUTE sur has_role.)

-- Vérifications
SELECT rolname, rolsuper, rolbypassrls, rolcreaterole FROM pg_roles WHERE rolname = 'soulbah_api';
SELECT table_name, string_agg(privilege_type, ', ' ORDER BY privilege_type)
  FROM information_schema.role_table_grants
 WHERE grantee = 'soulbah_api' GROUP BY 1 ORDER BY 1;
```

**Ce que `soulbah_api` ne peut pas faire** : lire ni écrire `profiles`, `user_roles`,
`chat_*` ou `modules_status`, supprimer dans `system_logs`, accéder au schéma `auth` ou
exécuter du DDL. Il peut supprimer des tâches : `DELETE /api/agent-tasks/:id` ne supprime
que des tâches **terminales** de l'utilisateur (filtre dans la requête de l'API), et la
maintenance horaire met à jour (`image_b64` retiré) puis purge `agent_events`.

**Si `CREATE ROLE … BYPASSRLS` est refusé**, ne pas revenir à `postgres` par défaut. Le
refus est possible : certaines versions de Postgres réservent cet attribut aux
superutilisateurs, et le `postgres` de Supabase n'en est pas un. Deux options :

1. Créer le rôle **sans** BYPASSRLS et ajouter, par une migration dédiée, une policy
   `TO soulbah_api USING (true) WITH CHECK (true)` sur chacune des tables ci-dessus. Le
   résultat est équivalent, et la décision est tracée dans le dépôt.
2. Garder `postgres` temporairement et consigner ce choix (S4 reste ouvert).

**Basculer `DATABASE_URL`** (`backend/.env`) :

```dotenv
# Pooler Supavisor, mode session (5432) : utilisateur = <rôle>.<project_ref>
DATABASE_URL=postgresql://soulbah_api.ntvwbafvjgzsjoumtcmb:<mot de passe encodé URL>@<hôte-pooler>.pooler.supabase.com:5432/postgres
# (connexion directe : postgresql://soulbah_api:<mdp>@db.ntvwbafvjgzsjoumtcmb.supabase.co:5432/postgres)
```

1. Encoder les caractères spéciaux du mot de passe : `@` → `%40`, `:` → `%3A`, `/` → `%2F`.
2. Redémarrer node-api, puis appeler `GET /health/deep`.
3. Parcourir l'app : chat, formation, base de connaissances, tâche agent, page Sécurité.
4. Rechercher dans les logs `permission denied for table …`. Chaque occurrence révèle un
   GRANT manquant : l'ajouter, et compléter la liste de cette page.
5. Les **sauvegardes et migrations** ont besoin de `postgres` (lecture du schéma `auth`,
   DDL). Fournir `BACKUP_DATABASE_URL` / `SUPABASE_DB_PASSWORD` le temps de l'opération,
   sans les écrire dans `backend/.env`.
6. Chaque nouvelle table utilisée par node-api (schéma `soulbah` en V2) exigera un GRANT
   explicite pour `soulbah_api` : les privilèges par défaut de Supabase ne couvrent que
   anon, authenticated et service_role.

## 11. Contrôle final

- [ ] Sauvegarde chiffrée, copiée hors du PC (étape 2)
- [ ] Image CI `db` épinglée sur la version Supabase, run vert (étape 3)
- [ ] `supabase migration list` : Local = Remote (étapes 4 et 5)
- [ ] `supabase functions list` vide (étape 6)
- [ ] Contraintes NOT VALID et orphelins examinés, `post_restore_checks.sql` passé (étape 7)
- [ ] Clé agent remplacée, mot de passe `postgres` réinitialisé (étape 8)
- [ ] `SOULBAH_ENV`, `IA_SERVICE_TOKEN`, `PG_SSL_CA` définis ; node-api et python-ia démarrent (étape 9)
- [ ] node-api tourne sous `soulbah_api` ; aucun `permission denied` dans les logs (étape 10)
- [ ] Une nouvelle sauvegarde après toutes ces opérations
