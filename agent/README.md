# SoulBah Agent — worker local (Phase 1)

Le processus qui tourne **sur votre poste** et exécute réellement les tâches créées
depuis l'app web. Il récupère les tâches de la file `agent_tasks` (Supabase), les
exécute via des *skills* sûrs, et remonte le résultat en temps réel.

C'est la première brique du « plan local » décrit dans
[../docs/SOULBAH_AI_ARCHITECTURE.md](../docs/SOULBAH_AI_ARCHITECTURE.md).

## Ce que fait cette Phase 1
- Poll la file `agent_tasks` (protocole `x-agent-key` déjà en place côté edge function).
- **Gate de permissions** : toute action sensible demande une confirmation (mode `confirm`).
- 5 skills sûrs et déterministes :

| Skill | Types d'étape | Catégorie | Sensible |
|---|---|---|---|
| `open_app` | `open_app`, `open_software`, `launch` | app_launch | ✅ |
| `screenshot` | `screenshot`, `capture` | screen | ❌ (lecture) |
| `type_text` | `type_text`, `type`, `keyboard` | keyboard | ✅ |
| `wait` | `wait`, `sleep` | generic | ❌ |
| `move_file` | `move_file`, `move` | filesystem | ✅ (whitelist) |

- Remonte `status` (`in_progress → completed/failed`), `result` (rapport par étape) et `error_message`.

## Installation

```bash
cd agent
python -m venv .venv
# Windows : .venv\Scripts\activate    |    Unix : source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env          # puis renseignez vos valeurs
```

`SOULBAH_AGENT_KEY` = clé générée depuis la page **Sécurité** de l'app
(« Clés de l'agent local »). Le backend la valide par hash et en déduit votre user_id
(vous n'avez plus besoin de fournir d'UUID).

## Utilisation

```bash
python soulbah_agent.py --dry-run     # décrit les actions sans rien exécuter (recommandé pour tester)
python soulbah_agent.py --once        # un seul cycle de poll
python soulbah_agent.py               # boucle continue, confirmation avant chaque action sensible
python soulbah_agent.py --auto        # sans confirmation — à n'utiliser qu'en connaissance de cause
```

Ctrl+C arrête proprement après le cycle en cours.

## Format d'une tâche

L'app web (`AgentTasksPanel`) crée une tâche avec ce `payload` :

```json
{
  "title": "Démo VS Code",
  "steps": [
    { "type": "open_software", "software": "vscode", "description": "Ouvrir VS Code" },
    { "type": "wait", "seconds": 3 },
    { "type": "type_text", "text": "console.log('hello')" },
    { "type": "screenshot", "path": "C:\\Users\\...\\demo.png" }
  ]
}
```

L'agent exécute les étapes **dans l'ordre** et s'arrête à la première qui échoue ou est refusée.
Ajouter un nouveau type d'action = ajouter un skill dans `skills/` et l'enregistrer dans `skills/__init__.py`.

## 🔒 Sécurité (à lire)
- **Confirmation** par défaut avant chaque action sensible (clavier, lancement d'app, fichiers).
- **Whitelist de dossiers** (`SOULBAH_ALLOWED_DIRS`) : `move_file` refuse tout chemin hors de cette liste.
- **Dry-run** pour visualiser un plan sans risque.
- **Borne de sécurité** sur `wait` (max 300 s).
- ✅ **Clé validée par hash** : le backend compare le hash SHA-256 de `x-agent-key` à ceux
  stockés en base (table `agent_keys`) et en déduit le propriétaire. `poll`/`update` sont
  scopés par cet utilisateur — une clé ne donne accès qu'aux tâches de son propriétaire.
  Révoquez une clé à tout moment depuis la page Sécurité.
- L'agent n'a que les droits de l'utilisateur qui le lance (permissions OS respectées).

## Structure
```
agent/
├── soulbah_agent.py     # boucle principale + CLI
├── config.py            # chargement .env
├── client.py            # poll / update vers agent-tasks
├── permissions.py       # gate (confirmation, whitelist, dry-run)
├── executor.py          # déroule les steps d'une tâche
└── skills/
    ├── __init__.py      # registre type d'étape → skill
    ├── base.py          # contrat Skill + SkillResult
    ├── open_app.py  screenshot.py  type_text.py  wait.py  move_file.py
```

## Prochaine étape (Phase 2)
Vision : capture + OCR + détection d'éléments à l'écran, pour un skill `click_on("Enregistrer")`
qui ne dépend pas de coordonnées fixes. Voir la roadmap dans `docs/`.
