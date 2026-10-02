# SOULBAH INTELLIGENCE BASELINE REPORT

Première étape de la mission « Soulbah Intelligence Lab ». Mesure de l'état actuel le 2026-10-02, sur le dépôt
au commit `f98bcd3` et sur le PC de développement. Aucun modèle téléchargé, aucun entraînement, aucun
garde-fou modifié.

Rapports liés : `docs/CC_LOT0_CONTROL_CENTER_READINESS.md` (gouvernance) et
`docs/AUTONOMY_LOT0_PROJECT_INTELLIGENCE_READINESS.md` (projets 224, dépendances, plan unifié).

## Règles de lecture

- **Aucun score global.** Chaque domaine est mesuré à part.
- **Aucun chiffre sans test reproductible.** Quand rien ne mesure un domaine, le rapport l'écrit : « non
  mesuré ».
- **Aucune comparaison avec des systèmes externes.** Aucun benchmark comparable et reproductible n'existe
  aujourd'hui entre Soulbah et un assistant du marché.
- Preuves : **[T]** test automatisé vert aujourd'hui ; **[R]** essai réel aujourd'hui sur cette machine ;
  **[B]** banc d'essai du modèle local (`agent/local_models/bench.py`, 5 tâches notées par règles,
  température 0) ; **[C]** lecture du code.

## Mesures de référence

**Matériel** : Intel i5-6300U (2 cœurs, 4 fils, AVX2), 8 Go de RAM dont 0,3 à 1,2 Go libres pendant les
essais (0,56 Go au moment du banc : VS Code, Chrome et les sessions Claude occupent environ 2,5 Go), Intel HD
520 sans CUDA, 10,9 Go libres sur C:.

**Modèle local** : qwen2.5-1.5b-instruct Q4_K_M (1,04 Go, Apache-2.0, empreinte vérifiée), llama.cpp b11325
sur CPU, 1 slot, contexte de 8 192 jetons.

| Banc de 5 tâches [B] | 2026-10-01 (modèle seul) | 2026-10-02, passage 1 | Passage 2 | Passage 3 |
|---|---|---|---|---|
| Score | 4/5 | 4/5 | 4/5 | 4/5 |
| Plan JSON contraint | réussi | réussi | réussi | réussi |
| Calcul simple (réponse 79) | échoué (47) | échoué | échoué | échoué |
| Ligne fautive d'une fonction | réussi | réussi | réussi | réussi |
| Question sur un texte fourni | réussi | réussi | réussi | réussi |
| Consigne de rédaction en français | réussi | réussi | réussi | réussi |
| Jetons générés par seconde | 11,5 | 2,0 | 3,2 | 4,9 |
| Mémoire de pointe du serveur | 1 337 Mo | 1 585 Mo | 1 585 Mo | 1 585 Mo |

Lecture : la qualité est stable sur ce petit banc ; la vitesse est divisée par 2 à 5 quand toute la pile et
les applications de bureau tournent. Cinq tâches ne suffisent pas à juger un modèle : c'est un témoin, pas un
benchmark.

| Essai réel du jour [R] | Résultat |
|---|---|
| Ordre « crée un dossier et écris bonjour dans note.txt » planifié par le modèle local | Plan valide en 94 s puis 50 s ; action réelle exécutée et vérifiée |
| 6 agents demandent une inférence en même temps | 6/6 réussies en 63 s, une seule inférence à la fois |
| Mission de 6 agents logiques (plan fourni) | 6/6 fichiers vérifiés en 32 s |
| Plan multi-agents proposé par le modèle local | **0/4** (délai dépassé, faux « irréalisable », clés en double et outil hors rôle, plan vide) |
| Vitesse sous grammaire JSON | 3,4 à 7,5 jetons/s ; lecture du prompt 24 à 31 jetons/s |

---

## Domaines

### 1. Reasoning

| | |
|---|---|
| CURRENT | Raisonnement court correct (plan d'un seul agent, lecture de texte). Échec constant sur un calcul en deux étapes. Échec de la planification multi-agents (0/4). |
| LIMITATION | Modèle de 1,5 milliard de paramètres sur CPU ; un seul exercice de raisonnement dans le banc. |
| TARGET | Banc de raisonnement d'au moins 50 problèmes vérifiables (logique, calcul, planification, cas réels) ; champion choisi sur ce banc ; planification multi-agents réussie à 80 % sur un jeu étiqueté. |
| EVIDENCE | [B] 4 passages ; [R] 4 essais de plan multi-agents (`docs/V3_LOT4_6_ORCHESTRATEUR_RESSOURCES.md`). |
| NEXT STEP | Golden tasks de raisonnement (lot 16 du plan unifié) ; challengers soumis à accord : phi-3.5-mini (2,23 Go, MIT), llama-3.2-3b (1,88 Go) — à mesurer contre la RAM disponible (lot 9). |

### 2. Coding

| | |
|---|---|
| CURRENT | Aucun modèle de code. Le modèle général trouve la ligne fautive d'une fonction (4/4). L'outillage existe et est testé : worktree par tâche, terminal, fusion seulement avec tests verts et relecture QA. |
| LIMITATION | Génération et correction de code jamais mesurées. |
| TARGET | Banc de code (correction de bug avec tests, SQL, API, frontend, git) et tâches privées assainies de 224Connect ; champion de code. |
| EVIDENCE | [B] tâche « ligne fautive » ; [T] tests du LOT 12 V2 (worktrees, fusion testée). |
| NEXT STEP | Candidat qwen2.5-coder-1.5b (1,04 Go, Apache-2.0, accord requis) au lot 9 ; tests hors ligne n° 68 et 70 au lot 12. |

### 3. Vision

| | |
|---|---|
| CURRENT | Aucune vision locale. En mode OFFLINE, `vision_available` est faux et l'évaluation juge sur le rapport seul. L'inspection de l'arbre d'interface Windows (`ui_snapshot`) donne une compréhension structurée de l'écran sans image. |
| LIMITATION | Pas de GPU : un petit modèle de vision prendrait plusieurs secondes à plusieurs dizaines de secondes par capture. |
| TARGET | Petit modèle de vision local mesuré sur un jeu de captures (erreurs, boutons, états). |
| EVIDENCE | [R] `GET /v2/models` ; [T] tests de `ui_snapshot`. |
| NEXT STEP | Candidat soumis à accord au lot 9 ; d'ici là, s'appuyer sur `ui_snapshot`. L'OCR intégré à Windows est une piste sans téléchargement, pas encore branchée. |

### 4. Image Generation

| | |
|---|---|
| CURRENT | Absente. |
| LIMITATION | Sans GPU et avec 8 Go de RAM, un modèle de diffusion demanderait plusieurs minutes par image et saturerait la mémoire. |
| TARGET | Image Engine sur une machine équipée d'un GPU, avec évaluation et auto-critique bornée. |
| EVIDENCE | Profil matériel. |
| NEXT STEP | Décision matérielle (machine GPU du réseau local) ; reporté dans le plan unifié. |

### 5. Memory

| | |
|---|---|
| CURRENT | Mémoire de leçons validées par l'humain, injectée dans le planificateur à un agent. Portée par projet déclarée, jamais appliquée. Pas de mémoire épisodique, sémantique ni de projet. |
| LIMITATION | Aucune mesure de rappel ni de fraîcheur. |
| TARGET | Mémoire à plusieurs niveaux, consolidation périodique, banc de rappel (précision, rappel, latence, fraîcheur). |
| EVIDENCE | [T] tests de la mémoire V1 ; [C] colonnes de portée inutilisées. |
| NEXT STEP | Lot 8 du plan unifié. |

### 6. RAG

| | |
|---|---|
| CURRENT | Hors ligne : recherche plein texte seulement. Recherche vectorielle uniquement avec les embeddings OpenAI (mode HYBRID). Modèle d'embeddings local installé, non branché. Pas de reranker. |
| LIMITATION | Pas d'index vectoriel local ; rappel jamais mesuré. |
| TARGET | Recherche hybride (lexicale, vecteurs locaux, graphe de code) avec fusion et reranker ; Recall@5 hybride supérieur à chaque méthode seule. |
| EVIDENCE | [C] `services/knowledge/embeddings.ts`, `supabaseStore.ts`. |
| NEXT STEP | Lot 6 (Project Brain et RAG local). |

### 7. Research

| | |
|---|---|
| CURRENT | Base de connaissances consultée d'abord, puis recherche web (Tavily, Serper ou Brave) et synthèse, avec provenance et sources marquées vérifiées seulement si la page a été lue. |
| LIMITATION | Indisponible hors ligne ; qualité jamais mesurée ; pas de date par source ni de politique de fraîcheur. |
| TARGET | Research Memory avec fraîcheur, comparaison de sources, priorité à la documentation officielle ; documentation des technologies utilisées indexée pour le hors ligne. |
| EVIDENCE | [T] tests de la recherche. |
| NEXT STEP | Lots 6 et 8. |

### 8. Speed

| | |
|---|---|
| CURRENT | Génération 11,5 jetons/s modèle seul, 2 à 5 avec toute la pile ; lecture du prompt 24 à 31 jetons/s, soit environ 2 s avant le premier jeton pour un prompt de 55 jetons et 45 s pour 1 270 jetons ; plan d'un agent 50 à 94 s ; plan multi-agents 76 à 306 s. |
| LIMITATION | 2 cœurs et mémoire saturée ; aucune mesure continue. |
| TARGET | Performance Engine : premier jeton, jetons/s, latence des outils et de la recherche, mesurés à chaque version ; profils FAST, BALANCED, MAX QUALITY. |
| EVIDENCE | [B] ; [R] journaux du serveur de modèle. |
| NEXT STEP | Lot 16 ; mesurer le gain du cache de préfixe (prompts système identiques) avant de l'activer. |

### 9. Security

| | |
|---|---|
| CURRENT | Sécurité d'exécution solide : niveaux L0 à L3, approbations liées à l'empreinte, audit chaîné en ajout seul, liste noire, coffre DPAPI, blocage réseau réel en OFFLINE. Aucune capacité d'analyse de sécurité. |
| LIMITATION | Contrôles de sécurité de la CI (npm audit, pip-audit, gitleaks, CodeQL) jamais exécutés sur le code actuel. |
| TARGET | Defense System : scanners par adaptateurs, findings avec preuves, patterns, red team sur copies. |
| EVIDENCE | [T] tests de sécurité V2 ; [R] approbation refusée sans empreinte. |
| NEXT STEP | Lot 1 (Trusted Core), lot 13, lot 20. |

### 10. Bug Detection

| | |
|---|---|
| CURRENT | Aucune détection automatique de bugs dans les projets. Le moteur d'évaluation détecte les actions échouées par leurs preuves. |
| LIMITATION | Rien à mesurer tant que le Project Brain n'existe pas. |
| TARGET | Bugs injectés en environnement de test détectés, diagnostiqués et corrigés (test n° 70). |
| EVIDENCE | [T] critères d'acceptation sur preuves. |
| NEXT STEP | Lots 12 et 16. |

### 11. 224Solutions Knowledge

| | |
|---|---|
| CURRENT | **0 %**. Le code de l'application n'est pas sur cette machine (seulement une Lambda d'authentification de 173 lignes). |
| LIMITATION | Prérequis P3 : fournir le code. |
| TARGET | Couverture calculée (code, base, API, interface, documentation), jamais affichée à 100 % sans mesure. |
| EVIDENCE | [C] inventaire du Bureau et de Documents. |
| NEXT STEP | P3, puis lots 2 à 7. |

### 12. 224Connect Knowledge

| | |
|---|---|
| CURRENT | **0 % indexé.** Environ 650 fichiers source présents ; seul l'inventaire structurel de cet audit existe (modules, pages, 47 migrations, 43 tests SQL). |
| LIMITATION | Pas de dépôt git (prérequis P2) ; aucun indexeur. |
| TARGET | Test hors ligne n° 69 : architecture du module Canaux avec fichiers, APIs et tables, depuis la connaissance locale. |
| EVIDENCE | [C] structure de `Desktop\224`. |
| NEXT STEP | P2, puis lots 2 à 7. |

### 13. Agent Reliability

| | |
|---|---|
| CURRENT | Suites vertes : agent 792, python-ia 473, node-api 387 + 57 en intégration, frontend 194. Essais réels du jour : 3 réussites sur 4 scénarios (le plan multi-agents par le modèle local échoue). Instabilités vues : 1 test de l'agent sous forte charge (vert en relance) ; tests d'intégration en parallèle (corrigé : exécution en série comme la CI). |
| LIMITATION | Aucun suivi du taux de réussite par agent, des reprises ni des interventions humaines. |
| TARGET | Fiche agent avec réussites, échecs, reprises, durée, ressources, interventions. |
| EVIDENCE | [T] [R]. |
| NEXT STEP | Lots 10 et 11. |

### 14. Local Model Capabilities

| | |
|---|---|
| CURRENT | Plan JSON contraint, lecture de documentation, consignes en français, repérage d'une ligne fautive : oui. Calcul en deux étapes, planification multi-agents, vision : non. Embeddings : disponibles, non branchés. |
| LIMITATION | Un seul modèle de raisonnement, petit, sur CPU. |
| TARGET | Une pile par capacité (raisonnement, code, vision, embeddings, reranker, voix) avec un champion mesuré pour chacune. |
| EVIDENCE | [B] [R]. |
| NEXT STEP | Lot 9, accords de téléchargement un par un. |

### 15. Hardware Limitations

| | |
|---|---|
| CURRENT | 2 cœurs, 8 Go (0,3 à 1,2 Go libres), pas de GPU, 10,9 Go de disque libre. Le gestionnaire de ressources limite déjà les workers (1 à la fois sous 530 Mo libres) et les inférences (1 à la fois). |
| LIMITATION | Interdit en pratique : génération d'images, entraînement, plusieurs modèles chargés en même temps, modèles de plus de 3 à 4 milliards de paramètres. |
| TARGET | Adapter les modèles au matériel automatiquement ; machine GPU sur le réseau local pour l'image et l'entraînement. |
| EVIDENCE | [R] mesures mémoire du jour ; profil matériel (`agent/hardware.py`). |
| NEXT STEP | Décision P6 du plan unifié. |

### 16. External API Dependencies

| | |
|---|---|
| CURRENT | Aucune dépendance obligatoire en mode OFFLINE : toute la journée d'essais s'est faite sans appel à une IA externe. Optionnels en HYBRID : 7 fournisseurs de modèles, embeddings et synthèse vocale OpenAI, recherche web. |
| LIMITATION | Pas d'interrupteur « IA externes » indépendant de l'interrupteur « Internet » dans le Control Center (seulement le mode LOCAL_INTERNET). |
| TARGET | Deux interrupteurs maîtres séparés, appliqués côté serveur et audités. |
| EVIDENCE | [T] tests des modes ; [R] mode OFFLINE toute la session. Liste complète dans le rapport Autonomie. |
| NEXT STEP | Lot 1. |

### 17. Security Architecture

| | |
|---|---|
| CURRENT | Bonne séparation des plans ; base de Soulbah accessible par un rôle à moindre privilège ; audit chaîné. Manquent : rôles PDG, double authentification, arrêt d'urgence global, Trusted Core, moteur de politiques. |
| LIMITATION | Réglages critiques dans des fichiers et variables, sans historique ; un réglage annoncé sans effet (auto-amélioration) et un plafond utilisateur ignoré. |
| TARGET | Trusted Core que les modèles ne pilotent jamais. |
| EVIDENCE | [C] rapport Control Center, sections 4, 5 et 21. |
| NEXT STEP | Lot 1. |

### 18. Self-Protection

| | |
|---|---|
| CURRENT | Journal d'audit protégé en base (mise à jour et suppression refusées, chaîne vérifiable). Les outils de fichiers de l'agent sont limités au dossier `SoulbahWorkspace`, et son terminal n'accepte qu'une liste fermée de programmes avec confirmation humaine à chaque commande. Un script lancé par l'agent n'est cependant pas en bac à sable. Sauvegarde chiffrée de la base disponible et testée (`scripts/backup_db.sh`). |
| LIMITATION | Pas d'empreintes des composants critiques, pas de surveillance du superviseur, pas de quarantaine d'agent ou de modèle, pas de test périodique de restauration. |
| TARGET | Empreintes comparées régulièrement, quarantaine, restauration testée dans un environnement isolé. |
| EVIDENCE | [T] tests de l'audit et de la sauvegarde ; [C] liste blanche de l'agent. |
| NEXT STEP | Lots 11, 17 et 20. |

### 19. Self-Improvement Readiness

| | |
|---|---|
| CURRENT | Suggestions tirées des échecs, rangées comme propositions à valider. |
| LIMITATION | Interrupteur jamais vérifié ; pas de version candidate, de benchmark, de comparaison ni de rollback. |
| TARGET | Soulbah Lab : candidat isolé, benchmark, comparaison, activation selon la politique, rollback. |
| EVIDENCE | [T] ; [C] `routes/agentMemory.ts:179-233`. |
| NEXT STEP | Lot 1 (respect de l'interrupteur), lot 15. |

### 20. Training Readiness

| | |
|---|---|
| CURRENT | Aucune donnée d'entraînement, aucun pipeline, pas de PyTorch, pas de GPU. |
| LIMITATION | Ce PC ne peut pas entraîner utilement, même un petit adaptateur LoRA. Le volume de solutions validées est encore faible. |
| TARGET | Dataset Factory (déduplication, filtrage des secrets et des données personnelles, licences, contamination des tests) avant toute idée d'entraînement ; entraînement seulement sur machine GPU et seulement si un benchmark montre le besoin. |
| EVIDENCE | Profil matériel ; [C] absence de pipeline. |
| NEXT STEP | Lot 16 (Dataset Factory seulement). |

---

## Prochaines mesures proposées

Le banc actuel de 5 tâches restera le témoin rapide. Il faut construire, dans l'ordre du plan unifié : un banc
de raisonnement et de planification (golden tasks), un banc de code avec tests, un banc de rappel pour le
RAG, puis des tâches privées tirées de 224Connect et 224Solutions, séparées strictement en entraînement,
validation et test.

**En attente de validation.**
