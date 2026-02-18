# SOULBAH Agent Local

Agent d'automatisation PC pour la production de vidéos de formation.

## Prérequis

- **Python 3.9+**
- **FFmpeg** installé et accessible dans le PATH
- **Système** : Windows, macOS ou Linux

## Installation

```bash
# 1. Installer FFmpeg
# Windows: choco install ffmpeg  (ou télécharger depuis ffmpeg.org)
# macOS:   brew install ffmpeg
# Linux:   sudo apt install ffmpeg

# 2. Installer les dépendances Python
pip install -r requirements.txt

# 3. Lancer l'agent
python agent.py \
  --url "https://VOTRE_URL_SUPABASE" \
  --user-id "VOTRE_USER_ID" \
  --agent-key "VOTRE_CLE"
```

## Types de tâches supportées

| Type | Description |
|------|------------|
| `screen_recording` | Capture d'écran avec FFmpeg |
| `tts_generation` | Synthèse vocale locale |
| `open_software` | Ouvrir VS Code, terminal, navigateur... |
| `keyboard_action` | Simuler des frappes clavier |
| `mouse_action` | Simuler des clics/mouvements souris |
| `demo_execution` | Séquence de démonstration automatique |
| `video_production` | Assembler vidéo + audio |
| `full_training_video` | Pipeline complet (narration + capture + assemblage) |

## Architecture

```
Application Web (SOULBAH IA)
        │
        ▼
   Base de données (agent_tasks)
        │
        ▼
   Agent Local (ce programme)
        │
        ├── FFmpeg (capture écran)
        ├── PyAutoGUI (souris/clavier)
        ├── pyttsx3 (synthèse vocale)
        └── Assemblage vidéo finale
```

## Sécurité

- Communication HTTPS chiffrée
- Authentification par clé agent
- Aucune donnée stockée en clair
- Journalisation complète dans `soulbah-agent.log`
