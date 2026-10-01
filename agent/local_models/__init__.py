"""Couche de modèles locaux (V3 LOT 2, mission V3 §4-7, §46-47, §62, §81-82).

  registry   registre `local_models` (fichier JSON local, écriture atomique) : modèles et moteurs
             installés, empreinte, licence acceptée, estimations mémoire, benchmark, statut ;
  catalog    candidats PROPOSÉS (jamais téléchargés sans accord) — métadonnées vérifiées en ligne
             par `resolve` avant toute proposition ;
  installer  téléchargement explicite (--yes + acceptation de licence), budget disque, reprise,
             vérification sha256, refusé en mode OFFLINE ;
  server     serveur de modèle PARTAGÉ (llama-server) : une seule copie des poids, N contextes ;
  bench      banc d'essai standard sur tout serveur compatible OpenAI (qualité JSON, raisonnement,
             lecture de document, jetons/s, mémoire de pointe).

Emplacements : %LOCALAPPDATA%\\Soulbah\\models (SOULBAH_MODELS_DIR) et
%LOCALAPPDATA%\\Soulbah\\engines (SOULBAH_ENGINES_DIR). CLI : agent/soulbah_models.py.
"""
