# LOT 12 — Ordinateur, navigateur, VS Code, worktrees

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §9.7 (codeur en worktree, inspection d'interface, DPI),
§9.10 (niveaux L0–L3), §13 ligne « 12 » (critères : scénario Bloc-notes vérifié par sha256 et inspection d'interface
en moins de 2 s par itération ; 3 codeurs en worktrees, fusion avec tests verts ; `branch -D` refusé sans L3).

## 1. Nouveaux outils (catalogue `shared/tools/catalog.json`)

| Outil | Catégorie | Niveau | Rôle | Effet et garde-fous |
|---|---|---|---|---|
| `git_worktree` | git | L1 | coder | Crée ou retire la worktree d'une tâche sur `soulbah/<session>/<tâche>`. Idempotent. Dossier non vide refusé. |
| `git_commit` | git | L1 | coder | `add -A` puis commit, uniquement sur une branche `soulbah/…`. Rien à valider = succès. |
| `git_merge` | git | L2, toujours confirmé | coder | Fusionne une branche de tâche dans `soulbah/<session>/integration`, dans la worktree d'intégration, puis lance les tests. Conflit : fusion abandonnée. Tests rouges : intégration remise à son état d'avant. Verrou inter-processus. |
| `git_branch_delete` | git | **L3** | aucun | Supprime une branche `soulbah/…`. Toujours confirmé au niveau 3, jamais couvert par un grant. |
| `git_push` | git | **L3** | aucun | Pousse une branche `soulbah/…`, jamais en force. Toujours confirmé au niveau 3. |
| `browser_get` | web | L1 | researcher, coder | Lecture seule http/https. Adresses privées, locales et métadonnées cloud refusées (sauf `SOULBAH_BROWSER_ALLOW_PRIVATE=1`). Redirections revérifiées, 5 Mo au plus. Playwright facultatif (`engine: "browser"`). |
| `ui_snapshot` | screen | L0 | desktop_operator, researcher | Inspecte une fenêtre (Win32 via ctypes) : titre, classe, processus, DPI, état, contrôles. Le texte d'un champ n'est jamais renvoyé, seulement sa longueur et son sha256. Champs mot de passe ignorés. |
| `vscode_open` | app_launch | L2 | desktop_operator | Lance `Code.exe` directement, jamais `code.cmd` (pas de cmd.exe). Chemin contrôlé par le gate. |

Git est toujours lancé sans shell, avec le durcissement de `run_command` (hooks désactivés, fsmonitor coupé, dépôts
nus refusés). Les branches de l'utilisateur ne sont jamais touchées : tous les noms suivent
`^soulbah/[a-z0-9][a-z0-9_-]{0,63}/[a-z0-9][a-z0-9_.-]{0,63}$`.

Nouveaux types de preuves déclarés par les manifestes : `http_status`, `sha256`, `test_report`, `ui_state`.

## 2. Gate de l'agent (`agent/permissions.py`)

- Un outil de niveau L3 (manifeste ou `confirm_level` = 3) est **toujours** confirmé au niveau 3, quel que soit le
  mode, `allow_input_control` ou un grant. Sur la console il faut taper « confirmer » ; dans l'app, l'approbation
  demandée est de niveau L3.
- Un skill avec `always_confirm` (ici `git_merge`, qui exécute les tests du dépôt) est toujours confirmé, comme la
  catégorie `shell`.
- `skills.manifests.declared_param_error` applique les contraintes déclarées (type, enum, bornes, longueur, motif,
  nombre d'éléments) : le manifeste est la seule source de ces règles pour les nouveaux skills.
- Sensibilité DPI : `ensure_dpi_awareness()` (par moniteur v2) est appelé par `build_executor`. Clics, positions et
  captures sont en pixels physiques.

## 3. Plan de contrôle (node-api)

- Rôles 1.1.0 (`shared/roles/roles.json`) : coder + `git_worktree`, `git_commit`, `git_merge`, `browser_get` ;
  desktop_operator + `ui_snapshot`, `vscode_open` ; researcher + `browser_get`, `ui_snapshot`. Aucun rôle ne porte
  `git_branch_delete` ni `git_push`.
- `validateDag` :
  - règle 7 : `ui_snapshot` compte comme observation avant d'agir ;
  - règle 9 : une relecture planifiée (`qa_reviewer`) désigne la tâche relue par `spec.review_of_key` et en dépend
    (dépendance dure). `spec.review_of` brut est interdit dans un plan ;
  - règle 10 : un nœud `git_merge` dépend (dépendance dure, même indirecte) d'une relecture QA.
- `setPlan` résout `review_of_key` en identifiant de tâche (`spec.review_of`).
- Relecteur P1 : une relecture **planifiée** refusée poste `ERROR policy_refused` (tâche FAILED, sans nouvel essai).
  Les dépendants passent BLOCKED : la fusion n'a jamais lieu. Les relectures créées par `REVIEW_REQUEST` (LOT 10)
  gardent leur comportement.
- Critère `git_branch_contains` : alimenté aussi par `git_commit` et `git_merge` (confiance haute).
- Gabarit `code_parallel` : N codeurs (1 à 8) en worktrees, sans dépendance entre eux, puis une relecture par codeur,
  puis un nœud `merge` (ressource exclusive `git.merge:<session>`, critères `tests_pass` et `git_branch_contains`).
- Politique (`decide`) : `git_branch_delete` et `git_push` sont L3, donc refusés au plafond L2 par défaut, et
  approuvés action par action avec payload complet au plafond L3.

## 4. Critères de sortie et preuves

| Critère (§13) | Preuve | Statut |
|---|---|---|
| Bloc-notes vérifié par sha256 et inspection d'interface < 2 s/itération | `agent/tests/test_lot12_web_ui.py::test_notepad_file_hash_matches_ui_hash` : le vrai Bloc-notes ouvre un fichier, l'empreinte lue dans l'interface est celle du fichier, 5 itérations sous 2 s. Test de bureau, lancé avec `SOULBAH_DESKTOP_TESTS=1` (exécuté le 2026-10-01 sur le PC de développement : réussi). En CI : fenêtre Win32 de test (`test_ui_snapshot_hashes_text_without_returning_it`). | Vérifié |
| 3 codeurs en worktrees, fusion avec tests verts | `agent/tests/test_lot12_git.py` (vrai git) : 3 codeurs simultanés dans leurs worktrees, fusions avec tests verts ; tests rouges annulés ; conflit abandonné. `backend/node-api/test/integration/v2Worktrees.pg.test.ts` (Postgres) : 3 codeurs pris en même temps, 3 relectures P1, fusion seulement après, mission COMPLETED. | Vérifié |
| `branch -D` refusé sans L3 | Agent : `run_command git branch -D` toujours refusé ; `git_branch_delete` refusé en mode auto sans console, refusé avec « o », refusé avec `allow_input_control`, accepté seulement avec « confirmer » ; approbation distante demandée au niveau L3. Node : `decide` = deny au plafond L2, approve_each L3 au plafond L3 ; validateDag refuse l'outil pour tout rôle. | Vérifié |

Tests ajoutés : agent `test_lot12_git.py` (12), `test_lot12_web_ui.py` (32 dont 1 de bureau) ; node `v2Lot12.test.ts`
(11), 9 cas golden (`fixtures/plans/golden.json`, 27 au total), `v2Worktrees.pg.test.ts` (4).

## 5. Limites

- La boucle LLM « observer → décider → agir » du desktop_operator n'est pas encore branchée : un nœud exécute les étapes
  fournies par le plan. `ui_snapshot` donne la structure de l'interface, pas encore la localisation d'un bouton par
  son nom dans une application non Win32 (UI Automation complète, OCR, vision locale : V3).
- `ui_snapshot` lit les contrôles Win32 classiques. Les applications Electron, WinUI ou Chromium exposent peu de
  contrôles enfants par cette voie.
- Playwright n'est pas installé : `browser_get` utilise HTTP simple par défaut ; `engine: "browser"` renvoie une
  erreur explicite tant que Playwright manque.
- Le contrôle DNS puis la connexion de `browser_get` laissent une fenêtre de « DNS rebinding » théorique.
- `vscode_open` est testé sur ses règles, son message d'absence et le nettoyage de l'environnement, pas sur un
  lancement réel (il ouvrirait une fenêtre pendant la session de travail). Défaut corrigé pendant l'audit : un agent
  lancé depuis un terminal de VS Code hérite de `ELECTRON_RUN_AS_NODE=1`, et Code.exe démarrait alors comme Node,
  sans fenêtre et sans erreur visible. Le lancement retire désormais les variables `ELECTRON_*` et `VSCODE_*`.
