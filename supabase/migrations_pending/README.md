# Migrations préparées — mode d'emploi d'exécution (DB LOT 0)

Ce dossier contient des migrations **préparées et prouvées sur des copies locales**, jamais appliquées
automatiquement : ni la CI, ni `scripts/dev_db/dev_db.sh`, ni `supabase db push` ne lisent ce dossier. Seul le
gestionnaire `scripts/db/migrate.py` les applique, avec l'option `--pending`, sur une cible désignée explicitement.

Rapport complet, preuves et mode d'emploi détaillé : `docs/db/DB_LOT0_RESTORED_DATABASE_AUDIT.md` (§16-19).
Architecture cible et décisions par table : `docs/db/DB_TARGET_ARCHITECTURE.md`. Conventions :
`docs/db/DB_MIGRATION_CONVENTIONS.md`.

## Contenu

| Fichier | Rôle |
|---|---|
| `20261002100000_db00_migration_history.sql` | Historique (`soulbah.schema_migrations`, `schema_migration_runs`) — créé par `migrate.py baseline` |
| `20261002110100_db01_core.sql` → `20261002111700_db16_hardening.sql` (17 fichiers, dont `110650_db06_vector_embeddings`) | DB LOT 1 → 16 |
| `*.down.sql` | Retour arrière de chaque fichier (`rollback=YES` ; `PARTIAL` pour db00 et db16, documenté en tête) |
| `tests/*.test.sql` | Test de chaque fichier, joué dans une transaction annulée (gardes, semences, droits, RLS) |

## Règles

1. **Jamais sans sauvegarde vérifiée.** Avant toute écriture sur une base réelle : sauvegarde chiffrée
   (`scripts/backup_db.sh`) puis test de restauration (`scripts/db/restore_test.py`). Une sauvegarde non
   restaurée n'est pas considérée comme vérifiée.
2. **Jamais sans essai sur copie.** Toute séquence est d'abord jouée sur une copie locale de la base cible
   (restaurée depuis la sauvegarde), avec ses tests : `scripts/db/lot_selftest.py` (application, tests, rejeu,
   retour arrière intégral, réapplication) puis `scripts/db/integration_checks.py` (contrôles CI + tests node-api).
3. **Jamais sur une base distante sans validation.** `migrate.py` refuse d'écrire sur un hôte non local, sauf
   trois clés réunies : `--allow-remote`, la variable `SOULBAH_MIGRATION_ALLOW_REMOTE=1` et
   `--approval <empreinte du plan>` (l'empreinte affichée par `plan` : elle change si un fichier change).
4. **Historique obligatoire.** Toute migration appliquée est inscrite dans `soulbah.schema_migrations` (empreinte
   SHA-256, durée, auteur, commit, retour arrière possible) ; chaque tentative, réussie ou non, dans
   `soulbah.schema_migration_runs` (ajout seul). Un fichier modifié après application bloque tout (`verify`).
5. **Une migration = une transaction**, sous verrou consultatif : deux exécutions concurrentes ne peuvent pas
   appliquer deux fois la même migration ; une erreur annule la migration entière.
6. **Un lot = un fichier**, qui ne dépend que des précédents ; après application des lots, rejouer
   `scripts/sql/soulbah_api_grants.sql` si le rôle `soulbah_api` existe (le DB LOT 16 couvre les objets futurs).

## Commandes

```bash
PY=agent/.venv/Scripts/python.exe
T=postgresql://postgres@127.0.0.1:54329/<copie locale>

$PY scripts/db/migrate.py status   --target "$T" --pending            # état de chaque migration
$PY scripts/db/migrate.py plan     --target "$T" --pending            # en attente, risques, empreinte du plan
$PY scripts/db/migrate.py apply    --target "$T" --pending --dry-run  # essai à blanc : une transaction annulée
$PY scripts/db/migrate.py apply    --target "$T" --pending            # application (cible locale)
$PY scripts/db/migrate.py verify   --target "$T" --pending            # empreintes conformes aux fichiers
$PY scripts/db/migrate.py rollback --target "$T" --pending --versions 20261002111700,20261002111600   # .down.sql, de la plus récente à la plus ancienne

$PY scripts/db/lot_selftest.py --name essai --lots 01,02,03 --report db/dryrun/<date>/essai.json   # banc d'un ou plusieurs lots
$PY scripts/db/integration_checks.py --target "$T" --out db/dryrun/<date>/checks.json                # CI + node-api sur une copie
```

`--stub-vector` (cibles locales seulement) simule pgvector comme la CI quand l'extension manque ; c'est noté
dans l'historique de la copie. Sur Supabase, pgvector 0.8.0 est présent : l'option est refusée.

## Séquence pour la base Supabase restaurée

La base restaurée n'a aucun historique. L'état réel de chaque migration du dépôt a été établi objet par objet
(`scripts/db/migration_state.py`, preuve dans `db/baseline/2026-10-02_restored/migration_state.json`) et reste
valable au 2026-10-02 16:53 (`db/baseline/2026-10-02_preapply/` : aucun changement dans `public`).

| Étape | Commande | Effet |
|---|---|---|
| 0 | `scripts/backup_db.sh` + `restore_test.py` | Sauvegarde vérifiée (faite : `backups/soulbah_20261002_1654.*.gpg`, `restore_verified: true`) |
| 1 | `migrate.py baseline --versions <16 versions APPLIED> --evidence migration_state.json` | Crée l'historique (migration `20261002100000`) et y inscrit les 16 migrations déjà présentes, sans les rejouer |
| 2 | `migrate.py plan --pending --until 20261001121100` puis `apply --dry-run --until …` | Rattrapage listé et essayé à blanc : 15 migrations du dépôt (`20261001000000` → `20261001121100`) |
| 3 | `migrate.py apply --pending --until 20261001121100` | Rattrapage : la base rejoint le code actuel (obligatoire avant tout redémarrage de node-api dessus) |
| 4 | contrôles CI : `scripts/ci/schema_checks.sql`, `scripts/sql/post_restore_checks.sql` (transaction annulée) | Preuve de conformité |
| 5 | `migrate.py apply --pending --dry-run` puis `apply --pending` puis `verify` | DB LOT 1 → 16 (17 fichiers, prouvés : banc 56/56, CI 3/3, node-api 57/57) |
| 6 | rôle `soulbah_api` + `scripts/sql/soulbah_api_grants.sql` | Moindre privilège pour node-api (SEC-06) |
| 7 | `supabase migration repair --status applied <31 versions du dépôt>` | Historique de la CLI cohérent : `supabase db push` ne rejouera rien (jeton et mot de passe par variables d'environnement, jamais sur la ligne de commande) |
| 8 | `db_catalog.py supabase --out db/baseline/<date>_postapply` | Catalogue après application, à comparer à `db/baseline/2026-10-02_integrated/` |

Les commandes exactes, avec les empreintes de validation des fichiers de ce commit, sont au §18 du rapport.
Chaque écriture distante exige les trois clés (règle 3) : l'empreinte est la validation du PDG.

Preuves sur copie locale : `db/dryrun/2026-10-02/` (rattrapage : `build_catchup_template.json` ; lots :
`lots_integration.json`, `integration_checks.json`).
