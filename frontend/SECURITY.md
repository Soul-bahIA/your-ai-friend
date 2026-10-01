# Sécurité des dépendances — `frontend/` (S16)

## État `npm audit`

| Périmètre | Résultat | Détail |
|---|---|---|
| Production (`npm audit --omit=dev`) | **0 vulnérabilité** | `react-router-dom` 6.30 → **7.18.4** : corrige GHSA-wrjc-x8rr-h8h6 (redirection ouverte via `\` dans `<Link>` / `useNavigate`) et GHSA-337j-9hxr-rhxg (hydratation SSR, non utilisée ici). |
| Développement | 1 élevée, 3 modérées | `vite` 5.4.21 (GHSA-fx2h-pf6j-xcff contournement de `server.fs.deny` sous Windows, GHSA-4w7w-66w2-5vf9, GHSA-v6wh-96g9-6wx3), `esbuild` 0.21.5 (GHSA-67mh-4wv8-2f99), `vitest` 3.2.x / `@vitest/mocker` (GHSA-82fw-gwwq-j7x9). |

## Exception acceptée (temporaire) — dépendances de développement

- **Portée** : serveur de développement Vite (`npm run dev`) et lanceur de tests uniquement.
  Aucun de ces paquets n'est embarqué dans le bundle de production (`dist/`).
- **Atténuations** : le serveur de dev n'écoute que sur `localhost` (`VITE_DEV_HOST=0.0.0.0` pour
  l'exposer volontairement — à éviter sur un réseau non fiable) ; ne pas naviguer sur des sites non
  fiables pendant que `npm run dev` tourne (avis esbuild).
- **Levée de l'exception** — montée de version vérifiée (tsc, lint, tests, build verts, `npm audit` à 0) :

  ```bash
  # serveur de dev ARRÊTÉ (sous Windows, esbuild.exe est verrouillé tant qu'il tourne → EBUSY)
  npm install -D vite@^7.3.6 vitest@^4.1.11
  ```

  Garder `@vitejs/plugin-react-swc` en **3.x** : la 4.x impose `@swc/core` ≥ 1.15.46, dont la 1.16.x
  refuse de charger son binaire natif sur un poste où la racine `C:\` accorde des droits de
  remplacement aux « Utilisateurs authentifiés » (`ERR_SWC_NATIVE_CACHE`).
- **CI** : le contrôle actuel est `npm audit --omit=dev --audit-level=high` ; passer à
  `--audit-level=moderate` pour la production est désormais possible (0 vulnérabilité).
