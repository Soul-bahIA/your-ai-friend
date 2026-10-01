# LOT 1 — Contrat commun des corrections (référence pour tous les chantiers)

Source des items : `docs/SOULBAH_V2_LOT0_AUDIT.md` (sections 6 « T# » et 7 « S# »).

1. **SOULBAH_ENV** = `dev` | `test` | `staging` | `production` (défaut `dev`). Hors `dev`/`test` :
   node-api refuse de démarrer sans `IA_SERVICE_TOKEN`, et sans `PG_SSL_CA` quand `DATABASE_SSL=true` ;
   python-ia refuse de démarrer sans `IA_SERVICE_TOKEN`.
2. **Annulation** : `POST /api/agent-tasks/:id/cancel` (JWT, propriétaire). `pending` → statut `cancelled`
   immédiatement ; `in_progress` → `control='stop'`. L'agent termine l'étape courante puis envoie un final
   `status='cancelled'` (avec `attempt`). Node accepte `cancelled` comme terminal (garde attempt) et
   **n'évalue jamais** une tâche `cancelled`.
3. **Tâche disparue** : pour une tâche supprimée/inexistante, `GET /:id/control`, `POST /event`, `POST /update`
   (et heartbeat) répondent **410** `{error:"gone"}`. L'agent abandonne immédiatement la tâche et retire
   toute mise à jour en attente pour elle.
4. **Plan vide** : 0 étape → l'agent échoue la tâche (`failed`, `result.empty_plan=true`). Node n'évalue et
   ne mémorise jamais un résultat avec `result.empty_plan` ou `result.simulated`.
5. **Dry-run** : en `--dry-run`, l'agent **ne réclame aucune tâche du serveur** ; il exécute un plan local
   (`--plan fichier.json`) en simulation. Tout résultat simulé porte `result.simulated=true`.
6. **Corrections soumises à approbation** : une tâche de correction créée par l'évaluateur porte
   `payload.goal_meta.awaiting_approval=true`, `payload.goal_meta.parent_task_id=<tâche évaluée>` et
   `payload.goal_meta.root_task_id=<première tâche de l'objectif>`. Le poll exclut les tâches
   `awaiting_approval=true`. `POST /api/agent-tasks/:id/approve` (JWT, propriétaire) passe le drapeau à
   false ; le rejet = `/cancel`.
7. **Ciblage d'un PC** : colonnes nullables `agent_tasks.target_agent_key_id` et `claimed_by_key_id`
   (FK `agent_keys(id) ON DELETE SET NULL`). `POST /api/agent/goal` et `POST /api/agent-tasks` acceptent
   `agent_key_id` optionnel (doit appartenir à l'utilisateur, non révoqué). Le planner utilise les
   `allowed_dirs` de CETTE clé. Sans `agent_key_id` : si l'utilisateur a une seule clé active, elle est
   ciblée ; s'il en a plusieurs → 400 `{error, agents:[{id,name}]}`. Le poll ne renvoie que les tâches
   `target_agent_key_id IS NULL OR = clé appelante` ; le claim écrit `claimed_by_key_id`.
8. **Événements** : `agent_events.data.source` = `agent` (défaut) | `formation`. Node écrit les événements de
   progression de formation avec `data.source='formation'` ; le cockpit ignore `source='formation'`.
   **Captures** : node retire `image_b64` avant d'insérer un événement, met `data.has_image=true`, et garde
   en mémoire la dernière capture par tâche (TTL 10 min) servie par
   `GET /api/agent-tasks/:id/screenshot` (JWT, propriétaire) → `{image_b64, mime, at}` ou 404.
9. **Mémoire** : l'évaluateur écrit les mémoires en `status='proposed'` (jamais `validated`). La récupération
   exclut `rejected`, inclut les leçons générales (`goal='(général)'`, par niveau), et ne passe en
   `validated` que par une action explicite de l'utilisateur.
10. **Outils du chat** : le navigateur n'exécute **jamais** automatiquement un tool call ; il affiche une carte
    de confirmation. Le contexte KB injecté dans le chat est marqué « données non fiables », jamais comme
    instruction système.
11. **Base de connaissances** : l'UI écrit uniquement via `/api/knowledge` (POST/PATCH/DELETE), qui calcule
    hash, version et embedding.
12. **Texte saisi masqué** : l'agent remplace le paramètre `text` (type_text, write_file content…) par
    `[texte masqué : N car.]` dans les logs, événements et résultats. Node masque aussi ces champs avant
    tout envoi au LLM évaluateur.
13. **Confirmations visibles** : avant de demander une confirmation, l'agent émet l'événement
    `approval_required` (`data: {step_index, action, summary}`), puis `approval_result`
    (`data: {step_index, approved}`). Le cockpit affiche « En attente de confirmation sur le PC ».
14. **Workspace** : `SOULBAH_ALLOWED_DIRS` par défaut = `%USERPROFILE%\SoulbahWorkspace` (créé au besoin).
    L'agent refuse de démarrer si un dossier autorisé contient le dossier de l'agent ou le dépôt SoulBah.
    Deny-list permanente : code/config de l'agent, `*.env`, `.ssh`, clés privées, `.git/hooks`, options git
    `--separate-git-dir`/`--template`.
15. **Non-régression** : aucun compteur de tests ne baisse (agent 156, python-ia 55, node-api 38, front 48).
