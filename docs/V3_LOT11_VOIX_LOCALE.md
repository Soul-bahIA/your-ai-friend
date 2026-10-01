# V3 LOT 11 (première brique) — Synthèse vocale locale

Source : mission V3 §33-35 (Voice Engine sans API cloud, TTS local). Première brique livrée sans aucun
téléchargement : les voix Windows déjà installées.

## 1. Outil `speak_text` (catégorie « voice », niveau L1)

- Énonce un texte sur le haut-parleur, ou l'écrit dans un fichier `.wav` (narration d'une vidéo).
- Moteur : voix SAPI 5 de Windows via `System.Speech`. Sur ce PC : Hortense (français) et Zira (anglais) côté
  SAPI 5 ; Julie et Paul (français) sont des voix « OneCore », détectées par le profil mais pas utilisables par
  `System.Speech`.
- Voix par défaut : la première voix française ; `voice` choisit par nom ; `rate` de -10 à 10.
- Sécurité : le texte passe par un fichier JSON temporaire lu par un script PowerShell statique
  (`agent/skills/sapi_speak.ps1`), jamais par la ligne de commande ; il est masqué dans les journaux. Le fichier de
  sortie doit être dans un dossier autorisé.
- Preuve : chemin du WAV et durée lue dans l'en-tête RIFF ; un fichier vide est un échec.
- Permis en OFFLINE (aucune connexion). Rôles : `desktop_operator` 1.2.0, `video_editor` 1.1.0.

## 2. Preuves

`agent/tests/test_v3_lot11_voice.py` : WAV réel produit par une voix française (en-tête RIFF, durée > 0,5 s) ; texte
contenant des commandes PowerShell et shell jamais exécuté (fichier témoin intact) ; voix inconnue signalée ; chemin
hors dossier autorisé et extension autre que `.wav` refusés ; permis en OFFLINE.

## 3. Reste du LOT 11

- Reconnaissance vocale locale (Whisper via whisper.cpp ou faster-whisper) et détection de parole : téléchargement
  d'un modèle requis, à proposer avec ton accord.
- Narration des vidéos de formation de python-ia : aujourd'hui OpenAI TTS (refusée hors HYBRID) ; à brancher sur la
  voix locale.
- Voix neuronales de meilleure qualité (Piper) : licence à vérifier voix par voix.
