# Conventions des migrations Soulbah (DB LOT 0)

Contrat commun à toutes les migrations préparées dans `supabase/migrations_pending/`. Il prolonge les
conventions des migrations V2 (`supabase/migrations/20261001120000_v2_schema.sql` à `20261001121100_v2_audit.sql`)
au lieu de les remplacer.

## 1. Emplacement et nom

- Fichier : `supabase/migrations_pending/<AAAAMMJJHHMMSS>_dbNN_<sujet>.sql`, une migration par sujet cohérent.
- Test : `supabase/migrations_pending/tests/<même nom>.test.sql`.
- Retour arrière quand il est possible : `supabase/migrations_pending/<même nom>.down.sql`.
- En-têtes obligatoires, lus par `scripts/db/migrate.py` :
  ```sql
  -- soulbah:rollback=YES|PARTIAL|NO
  -- soulbah:recovery=<plan de reprise en une phrase, obligatoire si PARTIAL ou NO>
  -- soulbah:transaction=single|none
  ```
  `none` seulement pour `CREATE INDEX CONCURRENTLY` sur une table existante volumineuse.

## 2. Schéma

Tout objet de Soulbah va dans le schéma **`soulbah`**, déjà prévu pour le plan de contrôle (node-api est son
seul écrivain, jamais exposé à PostgREST). Pas de nouveau schéma tant qu'un besoin d'accès différent ne le
justifie pas (évaluation §103 dans le rapport). Les domaines se distinguent par un préfixe de table :
`project_`, `brain_`, `code_`, `db_`, `api_`, `ui_`, `flow_`, `agent_`, `policy_`, `guardrail_`, `memory_`,
`research_`, `knowledge_`, `skill_`, `tool_`, `model_`, `benchmark_`, `dataset_`, `training_`, `improvement_`,
`security_`, `incident_`, `mission_`, `context_`, `computer_`, `health_`.

Les schémas gérés par Supabase (`auth`, `storage`, `realtime`, `vault`, `graphql`, `extensions`…) ne sont
jamais modifiés. Le schéma `public` (V1) n'est modifié que par des changements additifs justifiés.

## 3. Réutiliser avant de créer

Aucune table parallèle à une table existante : une mission est une `soulbah.sessions`, une tâche de mission une
`soulbah.tasks`, un journal d'audit `soulbah.audit_logs`, une preuve `soulbah.artifacts` ou une action
`soulbah.actions`, un résultat d'évaluation `soulbah.evaluations`, une compétence `soulbah.skills`. On ajoute
des colonnes ou des tables filles ; on ne duplique pas.

## 4. Tables

- Clé `id uuid PRIMARY KEY DEFAULT gen_random_uuid()` (identité `bigint` seulement pour les journaux en ajout
  seul à fort volume).
- `created_at timestamptz NOT NULL DEFAULT now()` ; `updated_at` + trigger `soulbah.set_updated_at()` si la
  ligne évolue.
- Propriété : `user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE` pour les données d'un utilisateur ;
  `project_id uuid REFERENCES soulbah.projects(id)` pour les données d'un projet.
- Statuts et énumérations : `text` + contrainte `CHECK (col IN (...))` nommée (pas de type ENUM : plus simple
  à faire évoluer).
- JSON : `jsonb NOT NULL DEFAULT '{}'::jsonb` + `CHECK (soulbah.is_json_object(col))`.
- Textes libres bornés : `CHECK (length(col) <= N)`.
- Contraintes nommées : `<table>_<colonne>_check`, `<table>_<colonne>_fkey`, index `idx_<table>_<colonnes>`.
- `ALTER TABLE … ENABLE ROW LEVEL SECURITY` sur toute table, **sans policy** : refus pour anon et
  authenticated ; `REVOKE ALL … FROM PUBLIC, anon, authenticated`. Le rôle `soulbah_api` reçoit ses droits par
  `scripts/sql/soulbah_api_grants.sql` (déjà « ALL TABLES IN SCHEMA soulbah »).
- `COMMENT ON TABLE` : rôle de la table en une phrase.
- Journaux, décisions et événements : **ajout seul** par trigger (refus d'UPDATE, DELETE, TRUNCATE), comme
  `soulbah.audit_logs` et `soulbah.schema_migration_runs`.

## 5. Idempotence sans masquer une incompatibilité (§9)

`CREATE TABLE IF NOT EXISTS` seul est interdit quand un objet pourrait déjà exister avec une autre forme : la
migration vérifie ensuite la forme réelle avec `soulbah.assert_table_shape(table, colonnes_attendues)` (créée
au DB LOT 1), qui lève une exception si une colonne attendue manque ou n'a pas le type attendu. Un objet
compatible existant est accepté ; un objet incompatible arrête la migration avec un message clair.
Colonnes ajoutées : `ADD COLUMN IF NOT EXISTS` suivi de la même vérification. Contraintes et index :
`DO $$ … IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = …) …`.

## 6. Verrous et indisponibilité

- Tables neuves : index créés dans la transaction (table vide, aucun blocage).
- Tables existantes : contraintes ajoutées `NOT VALID` puis `VALIDATE CONSTRAINT` dans une étape séparée si des
  lignes existent ; index volumineux en `CONCURRENTLY` (migration `transaction=none`).
- Données à transformer : par lots, avec reprise (stratégie expand → backfill → verify → switch → contract).
- `lock_timeout` de 10 s imposé par le gestionnaire.

## 7. Vecteurs

Les colonnes `vector` et les index HNSW vivent dans des migrations dédiées. pgvector 0.8.0 est présent sur
Supabase ; il manque au PostgreSQL local (installation à décider, téléchargement soumis à accord). Chaque
vecteur porte son modèle (`embedding_model_id`), sa version et sa dimension : deux modèles ne sont jamais mélangés
dans un même index.

## 8. Tests

Chaque migration a son fichier de test, exécuté dans une transaction annulée : présence et forme des objets,
contraintes qui refusent les valeurs interdites (dans un `SAVEPOINT`), RLS activée, aucun droit pour anon ni
authenticated, ajout seul effectif, rejeu de la migration sans changement de schéma.

## 9. Interdits

Jamais : `DROP` de table, de colonne ou de schéma de données ; `TRUNCATE` ; `DELETE` ou `UPDATE` sans `WHERE` ;
désactivation de RLS ; droit accordé à anon ou authenticated sur `soulbah` ; modification des schémas gérés par
Supabase ; modification des « interdits » de `docs/SUPABASE_REPRISE.md` (CHECK de statut d'`agent_tasks`, FK sur
`agent_events.task_id`, suppression de `modules_status`).
