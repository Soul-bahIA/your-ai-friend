# Migrations préparées — zone d'attente avant validation

Ce dossier reçoit les migrations **préparées mais pas encore validées** : risquées, destinées d'abord à une
copie, ou en attente d'une décision. Ni la CI, ni `scripts/dev_db/dev_db.sh`, ni `supabase db push` ne le lisent.
Seul `scripts/db/migrate.py --pending` les applique, sur une cible désignée explicitement (trois clés pour une
base distante : `--allow-remote`, `SOULBAH_MIGRATION_ALLOW_REMOTE=1`, `--approval <empreinte du plan>`).

Disposition d'une migration préparée : `<version>_<nom>.sql`, `<version>_<nom>.down.sql` et
`tests/<version>_<nom>.test.sql`. Banc d'essai sur copie : `scripts/db/lot_selftest.py` (application, tests,
rejeu, retour arrière intégral, réapplication) puis `scripts/db/integration_checks.py` (contrôles CI + node-api).

## Historique

Les lots DB 00 à 16 (DB LOT 0, 2026-10-02) ont été préparés ici, prouvés sur copie, appliqués sur la base Supabase
le 2026-10-02 (49 migrations enregistrées et vérifiées, compte rendu : `docs/db/DB_LOT0_RESTORED_DATABASE_AUDIT.md`
§18), puis **intégrés au circuit normal** le même jour :

| Contenu | Nouvel emplacement |
|---|---|
| migrations | `supabase/migrations/20261002100000_db00_…` à `20261002111700_db16_hardening.sql` |
| retours arrière | `supabase/rollbacks/*.down.sql` |
| tests | `supabase/migration_tests/*.test.sql` (joués par la CI après les migrations) |

Historique de la CLI Supabase réparé pour ces 18 versions : `supabase migration list` affiche 49 migrations
alignées (Local = Remote).

Règles inchangées : jamais sans sauvegarde vérifiée (sauvegarde chiffrée + `restore_test.py`), jamais sans essai
sur copie, jamais sur une base distante sans validation, historique obligatoire (`soulbah.schema_migrations`),
une migration = une transaction sous verrou consultatif. Conventions : `docs/db/DB_MIGRATION_CONVENTIONS.md`.
