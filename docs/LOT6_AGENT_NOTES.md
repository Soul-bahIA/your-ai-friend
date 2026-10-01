# LOT 6 — Notes côté agent local (`agent/`)

Complément de `docs/LOT6_SECURITE_AUDIT.md`. Trois chantiers : rédaction des secrets, clé agent
chiffrée par DPAPI, approbations distantes HMAC. Tests : `agent/tests/test_lot6_*.py`
(51 tests ; suite agent 488 → 623).

## 1. Rédaction des secrets — `agent/redaction.py`

- `redact_text(s)` : motifs de secrets connus (clés d'API `sk-…`, `sbk_…`, `sbap_…`, AWS, GitHub, Slack,
  JWT, blocs `PRIVATE KEY`, `password=…`/`secret=…`/`token=…`/`api_key=…`, `Authorization: Bearer …`,
  longues chaînes hexadécimales) + **valeurs connues** : la clé agent courante (`SOULBAH_AGENT_KEY`) et
  `SOULBAH_REDACT_VALUES` (séparateur `;`, p. ex. un canari de test). Libellé « [secret masqué] ».
  Idempotente : re-rédiger un texte déjà rédigé ne change rien.
- `redact_obj(value)` : copie profonde ; clés `is_secret_text` des manifestes (`text`, `content`) et
  clés de secrets (`password`, `secret`, `token`, `api_key`, `authorization`, `key_hash`…) deviennent
  « [texte masqué : N car.] » (libellé LOT 1) ; les autres chaînes passent par `redact_text` ;
  profondeur bornée ; un champ déjà masqué n'est pas remasqué.
- `RedactingFormatter` : formateur `logging` appliqué au message formaté (arguments et trace compris),
  branché sur la console et sur `agent/logs/agent.log` (`soulbah_agent._setup_logging`).
- `client.py` : `event()` et `update()` passent `data` / `result` par `redact_obj` avant envoi — le
  serveur ne reçoit jamais un secret (node-api rédige encore de son côté : défense en profondeur).

## 2. Clé agent chiffrée (DPAPI) — `agent/secrets.py`

- Windows uniquement : `CryptProtectData` / `CryptUnprotectData` via ctypes, portée utilisateur, aucune
  dépendance. Fichier `%LOCALAPPDATA%\Soulbah\agent_key.dpapi` (`SOULBAH_SECRETS_DIR` pour le dossier),
  déchiffrable seulement par le même compte Windows sur la même machine. Hors Windows :
  `NotImplementedError` (jamais de repli en clair).
- `python soulbah_agent.py --store-key` (clé lue dans `SOULBAH_AGENT_KEY` ou sur l'entrée standard, jamais
  journalisée) puis retirer `SOULBAH_AGENT_KEY` de `agent/.env` ; `--forget-key` efface le fichier.
  `config.load_config` charge la clé DPAPI quand la variable est vide ; avertissement si la clé vient
  encore de `.env` alors qu'une copie DPAPI existe.
- Le module porte le nom du module standard `secrets` : l'API publique de ce dernier est réexportée pour
  ne casser aucune bibliothèque.

## 3. Approbations distantes HMAC — `agent/approvals.py`

- `SOULBAH_APPROVAL_MODE = console` (défaut, comportement V1 inchangé) | `remote` | `both`.
- `RemoteApprover(client, timeout_s, poll_s=2)` : `POST /api/v2/approvals/request` (payload = l'étape
  COMPLÈTE, non rédigée : le serveur doit afficher et hacher exactement ce qui sera exécuté ; il la rédige
  lui-même pour l'affichage), puis `GET /api/v2/approvals/<id>` toutes les 2 s jusqu'à décision,
  expiration, `stop_check()` ou délai local ; si approuvée, `POST /api/v2/approvals/verify` avec le jeton
  et le payload réellement exécuté — `ok: false` ⇒ refus. Toute erreur réseau ou réponse inattendue ⇒
  refus. Aucune approbation par défaut.
- `canonical_sha256(step)` = `sha256(json.dumps(step, sort_keys=True, separators=(",", ":"),
  ensure_ascii=False))` : identique à `canonicalJson` de node-api (vérifié sur `{"b":1,"a":"é"}`).
- `PermissionGate._confirm` : console / remote / both (remote d'abord ; API absente → repli console avec
  avertissement). Évènements `approval_required` (`approval_id`, `level`) et `approval_result`
  (`approved`, `reason`, `remote`). Le jeton n'est jamais envoyé dans un évènement (seul `approval_id`).

## 4. Tests

| Fichier | Couvre |
|---|---|
| `test_lot6_policy.py` | pour CHAQUE outil du catalogue : L0 sans confirmation ; `requires_confirmation` → confirmation ; `shell` toujours confirmé ; `requires_desktop_input` sans `allow_input_control` → confirmation ; chemin hors dossiers autorisés → refus |
| `test_lot6_canary.py` | canari hors workspace → `read_file` refusé ; canari dans un `type_text`/`write_file` → absent des logs (caplog), des évènements et du rapport final ; clé `sbk_…` rédigée d'une ligne de log |
| `test_lot6_approvals.py` | approuvé / refusé / expiré / verify ko / 404 en mode both → console / 404 en mode remote → refus / stop pendant l'attente / rédaction de la demande hors payload |
| `test_lot6_secrets.py` | aller-retour DPAPI réel (Windows), fichier illisible → None, clé absente → sortie explicite |

## 5. Variables

| Variable | Rôle |
|---|---|
| `SOULBAH_APPROVAL_MODE` | `console` (défaut) · `remote` · `both` |
| `SOULBAH_REDACT_VALUES` | valeurs à rédiger partout (séparateur `;`) |
| `SOULBAH_SECRETS_DIR` | dossier du fichier DPAPI (défaut `%LOCALAPPDATA%\Soulbah`) |
