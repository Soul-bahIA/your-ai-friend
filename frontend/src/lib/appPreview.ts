// Prévisualisation d'une application générée (S31).
//  - Tout contenu issu de l'architecture (générée par l'IA, modifiable par
//    l'utilisateur) est échappé avant d'être injecté dans le HTML de l'iframe.
//  - Les messages reçus de l'iframe ne sont acceptés que s'ils viennent de CETTE
//    iframe (event.source) avec l'origine opaque d'un srcdoc sandboxé ("null").

export interface AppArchitecture {
  frontend?: {
    framework?: string;
    components?: { name: string; description: string; code: string }[];
  };
  backend?: {
    endpoints?: { method: string; path: string; description: string }[];
  };
  database?: {
    tables?: { name: string; columns: string[]; description?: string }[];
  };
}

export interface SelectedElement {
  type: string;
  name: string;
  text: string;
}

/** Échappe une valeur quelconque pour un contexte HTML (texte ou attribut entre guillemets). */
export function escapeHtml(value: unknown): string {
  const str = value === null || value === undefined ? "" : typeof value === "string" ? value : String(value);
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Sérialise une chaîne pour l'insérer dans un <script> sans pouvoir le refermer. */
export function scriptString(value: string): string {
  return JSON.stringify(value).replace(/</g, "\\u003c").replace(/>/g, "\\u003e").replace(/&/g, "\\u0026");
}

const asArray = <T>(v: unknown): T[] => (Array.isArray(v) ? (v as T[]) : []);

const METHOD_COLORS: Record<string, string> = {
  GET: "#059669",
  POST: "#2563eb",
  PUT: "#d97706",
};

export function buildPreviewHtml(
  title: string,
  architecture: AppArchitecture | null,
  editMode: boolean,
  parentOrigin = "*",
): string {
  const components = asArray<{ name?: unknown; description?: unknown; code?: unknown }>(architecture?.frontend?.components);
  const tables = asArray<{ name?: unknown; columns?: unknown; description?: unknown }>(architecture?.database?.tables);
  const endpoints = asArray<{ method?: unknown; path?: unknown; description?: unknown }>(architecture?.backend?.endpoints);

  const navItems = components.map((c) => c?.name).slice(0, 5);
  const sel = editMode ? 'class="selectable"' : "";
  const cur = editMode ? "cursor:pointer;" : "";
  const e = escapeHtml;

  const tableCards = tables
    .map(
      (t) => `
    <div ${sel} data-element-type="table" data-element-name="${e(t?.name)}" style="background:#1e293b;border-radius:8px;padding:16px;margin-bottom:12px;${cur}transition:outline 0.15s;">
      <div style="font-weight:600;color:#e2e8f0;margin-bottom:4px;">📦 ${e(t?.name)}</div>
      <div style="font-size:11px;color:#94a3b8;margin-bottom:8px;">${e(t?.description)}</div>
      <div style="display:flex;flex-wrap:wrap;gap:4px;">
        ${asArray<unknown>(t?.columns)
          .map((c) => `<span style="background:#334155;color:#cbd5e1;padding:2px 8px;border-radius:4px;font-size:10px;font-family:monospace;">${e(c)}</span>`)
          .join("")}
      </div>
    </div>`,
    )
    .join("");

  const endpointRows = endpoints
    .map((ep) => {
      const method = typeof ep?.method === "string" ? ep.method.toUpperCase() : "";
      const color = METHOD_COLORS[method] ?? "#dc2626";
      return `
    <tr ${sel} data-element-type="endpoint" data-element-name="${e(`${method} ${ep?.path ?? ""}`)}" style="${cur}transition:outline 0.15s;">
      <td style="padding:6px 10px;"><span style="background:${color};color:white;padding:2px 8px;border-radius:4px;font-size:10px;font-weight:700;">${e(method)}</span></td>
      <td style="padding:6px 10px;font-family:monospace;font-size:12px;color:#e2e8f0;">${e(ep?.path)}</td>
      <td style="padding:6px 10px;font-size:11px;color:#94a3b8;">${e(ep?.description)}</td>
    </tr>`;
    })
    .join("");

  const componentPanels = components
    .map(
      (comp) => `
    <div ${sel} data-element-type="component" data-element-name="${e(comp?.name)}" style="background:#1e293b;border-radius:8px;padding:16px;margin-bottom:12px;${cur}transition:outline 0.15s;">
      <div style="font-weight:600;color:#e2e8f0;margin-bottom:2px;">🖥️ ${e(comp?.name)}</div>
      <div style="font-size:11px;color:#94a3b8;margin-bottom:8px;">${e(comp?.description)}</div>
      <pre style="background:#0f172a;color:#7dd3fc;padding:12px;border-radius:6px;font-size:10px;overflow-x:auto;max-height:200px;line-height:1.5;">${e(comp?.code)}</pre>
    </div>`,
    )
    .join("");

  const interactiveScript = editMode
    ? `<script>
    var PARENT_ORIGIN = ${scriptString(parentOrigin)};
    var selected = null;
    document.addEventListener('click', function(e) {
      var el = e.target.closest('.selectable');
      if (!el) return;
      e.preventDefault();
      e.stopPropagation();
      if (selected) {
        selected.style.outline = 'none';
        selected.style.outlineOffset = '0px';
      }
      selected = el;
      selected.style.outline = '2px solid #a855f7';
      selected.style.outlineOffset = '3px';
      selected.style.borderRadius = '6px';
      window.parent.postMessage({
        type: 'element-selected',
        elementType: el.dataset.elementType,
        elementName: el.dataset.elementName,
        text: el.innerText.substring(0, 120),
      }, PARENT_ORIGIN);
    });
    document.addEventListener('mouseover', function(e) {
      var el = e.target.closest('.selectable');
      if (el && el !== selected) {
        el.style.outline = '1px dashed #a855f780';
        el.style.outlineOffset = '2px';
      }
    });
    document.addEventListener('mouseout', function(e) {
      var el = e.target.closest('.selectable');
      if (el && el !== selected) {
        el.style.outline = 'none';
      }
    });
  </script>`
    : "";

  const selClass = editMode ? "selectable" : "";

  return `<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background:#0f172a; color:#e2e8f0; }
  .app-container { display:flex; min-height:100vh; }
  .sidebar { width:220px; background:#1e293b; padding:20px 16px; border-right:1px solid #334155; flex-shrink:0; }
  .sidebar h2 { font-size:16px; font-weight:700; margin-bottom:4px; color:#f8fafc; }
  .sidebar .subtitle { font-size:10px; color:#64748b; margin-bottom:20px; }
  .sidebar nav a { display:block; padding:8px 12px; border-radius:6px; color:#94a3b8; font-size:13px; text-decoration:none; margin-bottom:2px; transition:all 0.2s; }
  .sidebar nav a:hover, .sidebar nav a.active { background:#334155; color:#f8fafc; }
  .main { flex:1; padding:24px 32px; overflow-y:auto; }
  .main h1 { font-size:22px; font-weight:700; margin-bottom:4px; }
  .main .desc { font-size:12px; color:#64748b; margin-bottom:24px; }
  .stats { display:grid; grid-template-columns:repeat(3,1fr); gap:12px; margin-bottom:24px; }
  .stat-card { background:#1e293b; border-radius:8px; padding:16px; transition:outline 0.15s; }
  .stat-card .label { font-size:11px; color:#64748b; }
  .stat-card .value { font-size:24px; font-weight:700; color:#f8fafc; margin-top:4px; }
  .section-title { font-size:14px; font-weight:600; margin-bottom:12px; color:#f8fafc; }
  table { width:100%; border-collapse:collapse; background:#1e293b; border-radius:8px; overflow:hidden; margin-bottom:24px; }
  table th { text-align:left; padding:8px 10px; background:#334155; font-size:11px; color:#94a3b8; font-weight:600; }
  table td { border-top:1px solid #334155; }
  ${
    editMode
      ? `.edit-banner { background:linear-gradient(135deg,#7c3aed20,#a855f720); border:1px solid #a855f740; border-radius:8px; padding:10px 16px; margin-bottom:20px; display:flex; align-items:center; gap:8px; }
  .edit-banner .dot { width:8px; height:8px; border-radius:50%; background:#a855f7; animation:pulse 1.5s infinite; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
  .edit-banner span { font-size:12px; color:#c4b5fd; }`
      : ""
  }
</style>
</head>
<body>
<div class="app-container">
  <div class="sidebar">
    <h2 ${sel} data-element-type="title" data-element-name="Titre de l'app" style="${cur}">${e(title)}</h2>
    <div class="subtitle">Prévisualisation IA</div>
    <nav>
      <a href="#" class="active ${selClass}" data-element-type="nav" data-element-name="Dashboard" style="${cur}">Dashboard</a>
      ${navItems.map((n) => `<a href="#" ${sel} data-element-type="nav" data-element-name="${e(n)}" style="${cur}">${e(n)}</a>`).join("")}
    </nav>
  </div>
  <div class="main">
    ${editMode ? '<div class="edit-banner"><div class="dot"></div><span>Mode édition actif — Cliquez sur un élément pour le modifier</span></div>' : ""}
    <h1 ${sel} data-element-type="heading" data-element-name="Titre principal" style="${cur}">Dashboard</h1>
    <div class="desc ${selClass}" data-element-type="description" data-element-name="Description" style="${cur}">Application générée par SOULBAH IA</div>
    <div class="stats">
      <div class="stat-card ${selClass}" data-element-type="stat" data-element-name="Composants" style="${cur}"><div class="label">Composants</div><div class="value">${components.length}</div></div>
      <div class="stat-card ${selClass}" data-element-type="stat" data-element-name="Endpoints API" style="${cur}"><div class="label">Endpoints API</div><div class="value">${endpoints.length}</div></div>
      <div class="stat-card ${selClass}" data-element-type="stat" data-element-name="Tables DB" style="${cur}"><div class="label">Tables DB</div><div class="value">${tables.length}</div></div>
    </div>
    ${endpoints.length > 0 ? `<div class="section-title ${selClass}" data-element-type="section" data-element-name="API Backend" style="${cur}">⚡ API Backend</div><table><thead><tr><th>Méthode</th><th>Route</th><th>Description</th></tr></thead><tbody>${endpointRows}</tbody></table>` : ""}
    ${tables.length > 0 ? `<div class="section-title ${selClass}" data-element-type="section" data-element-name="Base de données" style="${cur}">📦 Base de données</div>${tableCards}` : ""}
    ${components.length > 0 ? `<div class="section-title ${selClass}" data-element-type="section" data-element-name="Composants Frontend" style="${cur}">🖥️ Composants Frontend</div>${componentPanels}` : ""}
  </div>
</div>
${interactiveScript}
</body>
</html>`;
}

export const PREVIEW_ELEMENT_TYPES: ReadonlySet<string> = new Set([
  "table",
  "endpoint",
  "component",
  "nav",
  "title",
  "heading",
  "description",
  "stat",
  "section",
]);

/** Sous-ensemble de MessageEvent utilisé (testable sans DOM). */
export interface PreviewMessageEvent {
  origin: string;
  source: unknown;
  data: unknown;
}

/**
 * Valide un message reçu de l'iframe de prévisualisation. Accepté seulement si :
 *  - il provient de la fenêtre de l'iframe attendue (event.source) ;
 *  - son origine est l'origine opaque d'un srcdoc sandboxé sans allow-same-origin ("null") ;
 *  - sa forme est exactement celle d'une sélection d'élément.
 */
export function parsePreviewMessage(event: PreviewMessageEvent, frameWindow: unknown): SelectedElement | null {
  if (!frameWindow || event.source !== frameWindow) return null;
  if (event.origin !== "null") return null;
  const d = event.data;
  if (!d || typeof d !== "object") return null;
  const msg = d as Record<string, unknown>;
  if (msg.type !== "element-selected") return null;
  if (typeof msg.elementType !== "string" || !PREVIEW_ELEMENT_TYPES.has(msg.elementType)) return null;
  if (typeof msg.elementName !== "string" || !msg.elementName.trim()) return null;
  const text = typeof msg.text === "string" ? msg.text : "";
  return { type: msg.elementType, name: msg.elementName.slice(0, 200), text: text.slice(0, 120) };
}
