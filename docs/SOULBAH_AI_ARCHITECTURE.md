# SoulBah AI — Analyse de l'existant & Architecture cible

> Document vivant. Objectif : cadrer le passage d'une plateforme web (chat + génération)
> vers un **agent IA autonome capable de contrôler l'ordinateur**, en réutilisant au
> maximum l'existant et **sans supprimer de fonctionnalité** sans justification.

---

## 1. Ce qui existe déjà (audit)

### Plan « cloud » (Supabase + React) — mature
| Brique | Emplacement | État |
|---|---|---|
| Interface utilisateur | `src/` (React/Vite/TS) | ✅ Dashboard complet (Chat, Formations, Applications, KnowledgeBase, DatabaseAdmin, Automation…) |
| Auth & permissions | `useAuth`, RLS SQL, `user_roles` | ✅ JWT + Row Level Security par `user_id` |
| Moteur IA (LLM) | `supabase/functions/chat` | ✅ Appel Gateway (Gemini) + **tool-calling** (create_formation/application, save_knowledge) |
| Générateur de code | `supabase/functions/generate-application` | ✅ Génère architecture d'app par IA |
| Générateur de formation | `supabase/functions/generate-formation` | ✅ |
| Mémoire (permanente) | table `knowledge_base` | ✅ Contexte injecté dans le chat |
| Mémoire (conversation) | `chat_conversations` / `chat_messages` | ✅ |
| Journalisation | table `system_logs` + `ActivityFeed` | ✅ Historique d'événements temps réel |
| BDD dynamique | `manage-database` + `user_schemas/…` | ✅ CRUD de tables utilisateur |
| **File de tâches agent** | table `agent_tasks` + `supabase/functions/agent-tasks` | ⚠️ **Germe de l'agent** (voir §2) |
| Backend polyglotte | `backend/` (Node/Python/Rust/Postgres) | ✅ Scaffold récent, prêt à héberger raisonnement/vision |

### Le germe déjà présent : `agent_tasks`
La table et l'edge function `agent-tasks` implémentent **déjà** le bon patron pour un agent :

```
Web app (JWT) ── crée une tâche ──▶ agent_tasks (file, status=pending)
                                          ▲
Worker LOCAL ── poll (x-agent-key) ───────┘
   exécute ── update(status: in_progress → completed/failed) ──▶ realtime ──▶ UI
```
- `task_type` prévus : `screen_recording`, `demo_execution`, `video_production`, `tts_generation`.
- Cycle de vie : `pending → in_progress → completed | failed | cancelled`.
- `payload` JSONB = instructions ; `result` / `error_message` = retour.
- Auth worker par clé (`x-agent-key`), séparée du JWT web.

**Conclusion : l'ossature d'orchestration existe. Ce qui manque, c'est le worker local qui
touche réellement la machine, la vision, et la boucle de raisonnement.**

---

## 2. Les deux plans de l'architecture cible

L'erreur à éviter : croire que l'agent tourne « dans le cloud ». Pour contrôler souris,
clavier, fenêtres et logiciels installés, **un processus doit s'exécuter nativement sur le
poste de l'utilisateur**. D'où deux plans :

```
┌──────────────────────── PLAN CLOUD (existe déjà en grande partie) ────────────────────────┐
│  React UI  ·  Supabase (auth, mémoire, logs)  ·  file agent_tasks  ·  LLM Gateway         │
│  Node API (backend/)  ·  raisonnement/planif (Python)  ·  calculs (Rust)                   │
└───────────────────────────────────────────┬───────────────────────────────────────────────┘
                                             │  file de tâches + résultats (polling / WS)
┌───────────────────────────────────────────▼───────────────────────────────────────────────┐
│                    PLAN LOCAL — « SoulBah Agent » (À CONSTRUIRE, cœur du projet)            │
│                                                                                            │
│   Boucle : Observer → Comprendre → Planifier → Exécuter → Vérifier → Corriger → Continuer  │
│                                                                                            │
│   ┌──────────┐  ┌──────────┐  ┌──────────────┐  ┌───────────────┐  ┌────────────────────┐  │
│   │ Vision   │  │ Contrôle │  │ Gestionnaire │  │ Moteur vidéo  │  │ Système de         │  │
│   │ (écran,  │  │ (souris, │  │ d'outils /   │  │ (enregistr.,  │  │ permissions        │  │
│   │  OCR, UI)│  │  clavier,│  │ plugins      │  │  montage)     │  │ (validation user)  │  │
│   │          │  │  fenêtres│  │              │  │               │  │                    │  │
│   └──────────┘  └──────────┘  └──────────────┘  └───────────────┘  └────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Où se branche le backend polyglotte déjà scaffoldé
- **Python (`python-ia/`)** → hôte naturel du **raisonnement, planification, vision** (écosystème ML/CV).
- **Rust (`rust-compute/`)** → traitements lourds temps réel (diff d'images entre frames, encodage, matching visuel).
- **Node (`node-api/`)** → API interne / passerelle, orchestration, persistance.
- **Agent local** → nouveau service **hors conteneur**, sur le poste, qui parle à ce backend.

---

## 3. Cartographie : composants cibles → assets existants

| # | Composant cible | Statut | Base réutilisable / à créer |
|---|---|---|---|
| 1 | Moteur IA (LLM) | 🟡 Partiel | `chat` edge fn → généraliser en client LLM multi-fournisseur |
| 2 | Moteur de raisonnement | 🔴 À créer | boucle ReAct/planner (Python) |
| 3 | Planificateur | 🔴 À créer | décompose objectif → DAG de sous-tâches |
| 4 | Mémoire | 🟢 Bon | `knowledge_base`, `chat_*`, `system_logs` ; +ajouter mémoire tâches/erreurs/préférences |
| 5 | Vision | 🔴 À créer | capture (`mss`) + OCR (`tesseract`) + détection UI (template/OCR/modèle) |
| 6 | Contrôle ordinateur | 🟡 Germe | file `agent_tasks` ✅ ; **worker local à écrire** (`pyautogui`/OS APIs) |
| 7 | Gestionnaire d'outils | 🟡 Partiel | 3 outils codés en dur → **registre + plugins** |
| 8 | Générateur de code | 🟢 Bon | `generate-application` réutilisable |
| 9 | Moteur vidéo | 🟡 Germe | `task_type` vidéo + `FormationVideoPlayer` ; exécuteur local à écrire |
| 10 | Système de plugins | 🔴 À créer | interface `Skill`/`Tool` chargée dynamiquement |
| 11 | Système de permissions | 🟡 Partiel | RLS + `x-agent-key` ✅ ; **+gate d'approbation d'actions sensibles** |
| 12 | Moteur d'apprentissage | 🔴 À créer | post-mortem → `knowledge_base` (erreurs/corrections) |
| 13 | Journalisation | 🟢 Bon | `system_logs` + `ActivityFeed` |
| 14 | Observabilité | 🟡 Partiel | logs ✅ ; +métriques/traces (health deep existe) |
| 15 | API interne | 🟢 Bon | edge functions + `backend/node-api` |
| 16 | Interface utilisateur | 🟢 Bon | dashboard React |

Légende : 🟢 réutilisable tel quel · 🟡 à étendre · 🔴 nouveau.

---

## 4. Roadmap par phases (incrémentale, livrable à chaque étape)

Chaque phase produit quelque chose d'utilisable et testable. On ne construit **pas** tout d'un bloc.

### Phase 0 — Consolidation (fait / en cours)
- Audit + correctifs bugs (fait : 5 bugs corrigés).
- Backend polyglotte scaffoldé (fait).
- **Ce document** (fait).

### Phase 1 — Agent local « squelette » + gate de permissions ⭐ recommandé pour démarrer
Un worker local (Python) qui :
- poll `agent_tasks` (protocole déjà défini) ;
- **demande confirmation** avant toute action sensible (gate de permissions) ;
- exécute un petit jeu de *skills* sûrs et déterministes : `open_app`, `screenshot`, `type_text`, `wait`, `move_file` ;
- remonte `status` + `result` + logs.
> Débloque toute la suite car la file de tâches existe déjà. Risque maîtrisé (skills limités, confirmation).

### Phase 2 — Vision de base
- Capture d'écran + OCR (lire le texte à l'écran).
- Détection d'éléments par *template matching* + OCR (cliquer « le bouton Enregistrer » sans coordonnées fixes).
- Skill `click_on(description)` / `find_on_screen(text)`.

### Phase 3 — Boucle agentique (raisonnement + planification)
- Planner LLM : objectif → plan de sous-tâches → tâches `agent_tasks`.
- Boucle Observer→…→Corriger avec vérification par la vision après chaque action.
- Reprise de tâche interrompue (état persistant).

### Phase 4 — Gestionnaire d'outils & plugins
- Registre d'outils typé, découverte dynamique, autorisations par outil.
- Migration des 3 outils du chat vers ce registre.

### Phase 5 — Moteur vidéo générique
- Pipeline enregistrement → montage → export, piloté par la vision (générique, non lié à un logiciel précis).

### Phase 6 — Apprentissage & observabilité
- Post-mortem d'exécution → `knowledge_base` (erreurs/corrections réutilisées).
- Métriques, traces, tableau de bord de fiabilité.

---

## 5. Sécurité (transversal, non négociable)

Un agent qui contrôle la machine est **sensible par nature**. Principes :
- **Consentement explicite** par catégorie d'action (fichiers, réseau, exécution de scripts, saisie clavier).
- **Gate de confirmation** avant toute action destructive ou irréversible.
- **Journal d'audit** de chaque action réalisée par l'agent (horodaté, rejouable).
- **Périmètre restreint** : dossiers autorisés, applications en liste blanche.
- **Clé agent** stockée localement, révocable ; jamais dans le code.
- **Mode « dry-run »** : l'agent décrit ce qu'il ferait sans l'exécuter.
- Respect des permissions OS (l'agent n'a que les droits de l'utilisateur qui le lance).

---

## 6. Améliorations proposées sur l'existant (sans rien retirer)

Détectées pendant l'audit — à traiter en continu :
1. **Lint edge functions** : 57 erreurs `any`/regex (Deno). Typage à renforcer.
2. **Découplage LLM** : le modèle est codé en dur (`google/gemini-3-flash-preview`) dans plusieurs fonctions → centraliser dans un client configurable.
3. **Données factices** du dashboard (CPU/RAM/menaces) → brancher sur de vraies métriques (lien avec l'observabilité, Phase 6).
4. **Code-splitting** du bundle front (689 KB) → lazy-load des pages.
5. **`.env` versionné** : la clé exposée est publique (anon), mais retirer `.env` du suivi git reste sain.
6. **Mémoire agent** : ajouter tables `task_history`, `error_history`, `user_preferences` (extension de `profiles`).

Aucune suppression de fonctionnalité proposée à ce stade.

---

## 7. Prochaine action recommandée

**Démarrer la Phase 1** : écrire le worker local `SoulBah Agent` (Python) qui poll `agent_tasks`,
avec gate de permissions et 5 skills sûrs. C'est le plus petit incrément qui rend l'agent *réel*
et exploite l'ossature déjà présente.
```

