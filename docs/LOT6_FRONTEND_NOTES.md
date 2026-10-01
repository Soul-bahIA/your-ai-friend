# LOT 6 — Sécurité et audit : partie frontend (ApprovalsInbox)

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §7 (S7 : confirmations sans contenu ;
S22 : l'UI ne voit pas qu'une approbation est en attente), §9.10 (niveaux L0–L3), §13 ligne
« 6. Sécurité et audit » (« ApprovalsInbox »).

Périmètre : `frontend/` uniquement (+ ce document). Aucune dépendance ajoutée.

## 1. Fichiers

| Fichier | Rôle |
|---|---|
| `frontend/src/lib/approvals.ts` | Types du contrat, appels API (`listApprovals`, `approveApproval`, `denyApproval`, `verifyAuditChain`, `listAudit`) et fonctions pures (libellés, tonalités, échéances, résumé, `formatPayload`, `sortApprovals`, partition en attente / historique, textes d'audit). |
| `frontend/src/lib/approvals.test.ts` | 24 tests : toutes les fonctions pures + appels API avec `fetch` mocké (URL, jeton, corps, 404, 409). |
| `frontend/src/hooks/useApprovals.ts` | Polling des approbations : intervalle configurable, suspendu quand l'onglet est masqué (relecture immédiate au retour), arrêt définitif sur 404 (serveur V1), annulation au démontage. |
| `frontend/src/components/ApprovalsInbox.tsx` | Boîte de réception : onglets « En attente » / « Historique », cartes de demande, dialogue de décision (L3 : mot « AUTORISER » ; refus : motif optionnel), encart « Journal d'audit ». |
| `frontend/src/components/ApprovalsInbox.test.tsx` | 6 tests de composant (testing-library déjà présent) : état vide, carte complète + approbation L2 directe avec l'empreinte affichée, confirmation L3, 409 → toast « demande périmée », 404 → message et arrêt du polling, vérification de la chaîne + entrées. |
| `frontend/src/pages/Security.tsx` | Nouvelle carte « Approbations en attente » en tête de page, qui monte `ApprovalsInbox`. |
| `frontend/src/components/Sidebar.tsx` | Compteur d'approbations en attente à côté de « Sécurité » (polling 15 s, masqué sur serveur V1 ou à zéro). |

## 2. Contrat API utilisé (node-api, JWT via `apiFetch`)

- `GET /api/v2/approvals?status=pending|approved|denied|expired|revoked|all&limit=50` → `{ approvals: Approval[] }`
- `POST /api/v2/approvals/:id/approve` body `{ payload_sha256 }` → `{ id, status: "approved", expires_at }` ; 409 si l'empreinte diffère ou si la demande n'est plus en attente.
- `POST /api/v2/approvals/:id/deny` body `{ reason? }` → `{ id, status: "denied" }`
- `GET /api/v2/audit/verify` → `{ ok, checked, broken_at }`
- `GET /api/v2/audit?limit=100` → `{ entries: AuditEntry[] }`

`Approval` : `id, status, security_level (L0–L3), kind (request|grant), tool, summary, task_id, attempt,
step_index, payload_presented, payload_sha256, reason, created_at, expires_at, decided_at` — identique au
DTO `toApprovalDto` de `backend/node-api/src/v2/routes/approvals.ts`.

Serveur V1 (routes absentes → 404) : le hook s'arrête après la première réponse, l'inbox affiche
« Approbations distantes indisponibles sur ce serveur (API V2 absente)… », le compteur de la barre
latérale reste masqué. Aucune erreur console, aucune boucle.

## 3. Décisions

- **S7 — contenu exact.** `formatPayload` affiche le payload complet (JSON indenté, clés triées) sans
  aucun masquage côté client. Seules les valeurs texte de plus de 2000 caractères sont repliées avec
  « … (N car.) » (N = longueur réelle), et un bouton « Afficher tout, sans troncature » les déplie.
- **Empreinte liée à l'affichage.** Le bouton « Approuver » renvoie `payload_sha256` tel que reçu avec la
  demande affichée ; il est désactivé si l'empreinte manque. Un 409 est présenté comme « Demande
  modifiée ou plus en attente » et déclenche un rafraîchissement.
- **Niveaux.** L0 « lecture » (muted), L1 « réversible » (primary), L2 « effet réel » (warning),
  L3 « irréversible » (destructive). Seul L3 exige la saisie du mot `AUTORISER` (`ConfirmAction.tsx`
  n'a pas de champ de saisie : un dialogue dédié `DecisionDialog` est utilisé, `ConfirmAction` reste intact).
- **Tri.** En attente d'abord, L3 avant L2, puis la plus ancienne d'abord. Une demande en attente
  dont l'échéance est passée disparaît de la liste active et est présentée « Expirée » dans l'historique.
- **Compte à rebours** : tick d'une seconde uniquement s'il existe une échéance à suivre ;
  rouge sous 60 s.
- **Polling** : 5 s dans l'inbox, 15 s dans la barre latérale, seulement onglet visible et
  utilisateur connecté. Les deux instances s'arrêtent indépendamment sur 404.
- **Toasts** : `useToast` (hook existant, déjà utilisé par `Security.tsx`).
- **Historique** : lecture `status=all` puis filtrage client (`historyOf`) — une seule requête, et les
  « pending » dépassées sont bien reclassées.
- **Journal d'audit** : « Vérifier la chaîne » appelle `/audit/verify` et `/audit?limit=20` en
  parallèle ; affiche « Chaîne intègre : N entrées vérifiées. » ou « Chaîne ROMPUE à la ligne N (…) ».

## 4. Vérifications

`cd frontend && npm run lint && npx tsc -b && npm test` : lint sans avertissement, `tsc` sans erreur,
tests 16 fichiers / 187 verts (avant : 14 / 157). Les `*.tsbuildinfo` générés ont été supprimés.

## 5. Non fait / à suivre

- Pas d'indicateur dans `AgentCockpit.tsx` : le cockpit garde ses bannières V1 (« En attente de
  confirmation sur le PC ») issues des événements ; le compteur global est dans la barre latérale.
- Pas de test E2E Playwright (prévu au LOT 16).
- La révocation d'un grant de session (`revoked`) est affichée dans l'historique mais aucune action de
  révocation n'est exposée : le contrat ne prévoit pas encore de route pour cela.
