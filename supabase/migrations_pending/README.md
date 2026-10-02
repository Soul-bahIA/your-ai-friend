# Migrations préparées — mode d'emploi d'exécution (DB LOT 0)

Ce dossier contient des migrations **préparées et testées sur une copie**, jamais appliquées automatiquement :
ni la CI, ni `scripts/dev_db/dev_db.sh`, ni `supabase db push` ne lisent ce dossier. Seul le gestionnaire
`scripts/db/migrate.py` les applique, avec l'option `--pending`, sur une cible désignée explicitement.

Rapport complet et preuves : `docs/db/DB_LOT0_RESTORED_DATABASE_AUDIT.md`.

## Règles

1. **Jamais sans sauvegarde vérifiée.** Avant toute écriture sur une base réelle : sauvegarde chiffrée
   (`scripts/backup_db.sh`) puis test de restauration (`scripts/db/restore_test.py`). Une sauvegarde non
   restaurée n'est pas considérée comme vérifiée.
2. **Jamais sans essai sur copie.** Toute séquence est d'abord jouée sur une copie locale de la base cible
   (restaurée depuis la sauvegarde), avec ses tests.
3. **Jamais sur une base distante sans validation.** `migrate.py` refuse d'écrire sur un hôte non local, sauf
   trois clés réunies : `--allow-remote`, la variable `SOULBAH_MIGRATION_ALLOW_REMOTE=1` et
   `--approval <empreinte du plan>` (l'empreinte affichée par `plan` : elle change si un fichier change).
4. **Historique obligatoire.** Toute migration appliquée est inscrite dans `soulbah.schema_migrations` (empreinte
   SHA-256, durée, auteur, commit, retour arrière possible) ; chaque tentative, réussie ou non, dans
   `soulbah.schema_migration_runs` (ajout seul). Un fichier modifié après application bloque tout (`verify`).
5. **Une migration = une transaction**, sous verrou consultatif : deux exécutions concurrentes ne peuvent pas
   appliquer deux fois la même migration ; une erreur annule la migration entière.

## Commandes

```bash
PY=agent/.venv/Scripts/python.exe
T=postgresql://postgres@127.0.0.1:54329/<copie locale>

$PY scripts/db/migrate.py status  --target "$T" --pending            # état de chaque migration
$PY scripts/db/migrate.py plan    --target "$T" --pending            # en attente, risques, empreinte du plan
$PY scripts/db/migrate.py apply   --target "$T" --pending --dry-run  # essai à blanc : une transaction annulée
$PY scripts/db/migrate.py apply   --target "$T" --pending            # application (cible locale)
$PY scripts/db/migrate.py verify  --target "$T" --pending            # empreintes conformes aux fichiers
```

`--stub-vector` (cibles locales seulement) simule pgvector comme la CI quand l'extension manque ; c'est noté
dans l'historique de la copie. Sur Supabase, pgvector 0.8.0 est présent : l'option est refusée.

## Séquence prévue pour la base Supabase restaurée

La base restaurée n'a aucun historique. L'état réel de chaque migration du dépôt a été établi objet par objet
(`scripts/db/migration_state.py`, preuve dans `db/baseline/2026-10-02_restored/migration_state.json`).

| Étape | Commande | Effet |
|---|---|---|
| 1 | `migrate.py baseline --versions <16 versions APPLIED> --evidence migration_state.json` | Crée l'historique (migration `20261002100000`) et y inscrit les 16 migrations déjà présentes, sans les rejouer |
| 2 | `migrate.py plan --pending` | Liste le rattrapage : 15 migrations du dépôt (`20261001000000` → `20261001121100`) |
| 3 | `migrate.py apply --pending --dry-run` | Essai à blanc de la séquence entière |
| 4 | `migrate.py apply --pending --until 20261001121100` | Rattrapage : la base rejoint le code actuel |
| 5 | contrôles CI : `scripts/ci/schema_checks.sql`, `scripts/sql/post_restore_checks.sql`, `scripts/ci/api_role_checks.sql` | Preuve de conformité |
| 6 | lots DB 1 → 16 (fichiers de ce dossier), un par un, après validation | Architecture cible |

Sur une base Supabase réelle, garder aussi l'historique de la CLI cohérent : après l'étape 4,
`supabase migration repair --status applied <version>` pour chaque migration du dépôt appliquée
(voir `docs/SUPABASE_REPRISE.md` §4), pour que `supabase db push` ne tente jamais de les rejouer.

Preuve de cette séquence sur une copie locale de la base restaurée : `db/dryrun/2026-10-02/`.
