import { useState } from "react";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import AppChatPanel from "@/components/AppChatPanel";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Eye, Code2, Database, Globe, MessageSquare } from "lucide-react";

interface AppArchitecture {
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

interface AppPreviewProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description: string | null;
  appType: string | null;
  techStack: string | null;
  architecture: AppArchitecture | null;
  applicationId?: string;
  sourceCode?: any;
  onAppUpdated?: (result: any) => void;
}

function buildPreviewHtml(title: string, architecture: AppArchitecture | null): string {
  const components = architecture?.frontend?.components || [];
  const tables = architecture?.database?.tables || [];
  const endpoints = architecture?.backend?.endpoints || [];

  // Build a visual mockup HTML from the architecture
  const navItems = components.map((c) => c.name).slice(0, 5);
  const tableCards = tables
    .map(
      (t) => `
    <div style="background:#1e293b;border-radius:8px;padding:16px;margin-bottom:12px;">
      <div style="font-weight:600;color:#e2e8f0;margin-bottom:4px;">📦 ${t.name}</div>
      <div style="font-size:11px;color:#94a3b8;margin-bottom:8px;">${t.description || ""}</div>
      <div style="display:flex;flex-wrap:wrap;gap:4px;">
        ${t.columns.map((c) => `<span style="background:#334155;color:#cbd5e1;padding:2px 8px;border-radius:4px;font-size:10px;font-family:monospace;">${c}</span>`).join("")}
      </div>
    </div>`
    )
    .join("");

  const endpointRows = endpoints
    .map(
      (ep) => `
    <tr>
      <td style="padding:6px 10px;"><span style="background:${ep.method === "GET" ? "#059669" : ep.method === "POST" ? "#2563eb" : ep.method === "PUT" ? "#d97706" : "#dc2626"};color:white;padding:2px 8px;border-radius:4px;font-size:10px;font-weight:700;">${ep.method}</span></td>
      <td style="padding:6px 10px;font-family:monospace;font-size:12px;color:#e2e8f0;">${ep.path}</td>
      <td style="padding:6px 10px;font-size:11px;color:#94a3b8;">${ep.description}</td>
    </tr>`
    )
    .join("");

  const componentPanels = components
    .map(
      (comp) => `
    <div style="background:#1e293b;border-radius:8px;padding:16px;margin-bottom:12px;">
      <div style="font-weight:600;color:#e2e8f0;margin-bottom:2px;">🖥️ ${comp.name}</div>
      <div style="font-size:11px;color:#94a3b8;margin-bottom:8px;">${comp.description}</div>
      <pre style="background:#0f172a;color:#7dd3fc;padding:12px;border-radius:6px;font-size:10px;overflow-x:auto;max-height:200px;line-height:1.5;">${escapeHtml(comp.code)}</pre>
    </div>`
    )
    .join("");

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
  .stat-card { background:#1e293b; border-radius:8px; padding:16px; }
  .stat-card .label { font-size:11px; color:#64748b; }
  .stat-card .value { font-size:24px; font-weight:700; color:#f8fafc; margin-top:4px; }
  .section-title { font-size:14px; font-weight:600; margin-bottom:12px; color:#f8fafc; }
  table { width:100%; border-collapse:collapse; background:#1e293b; border-radius:8px; overflow:hidden; margin-bottom:24px; }
  table th { text-align:left; padding:8px 10px; background:#334155; font-size:11px; color:#94a3b8; font-weight:600; }
  table td { border-top:1px solid #334155; }
</style>
</head>
<body>
<div class="app-container">
  <div class="sidebar">
    <h2>${escapeHtml(title)}</h2>
    <div class="subtitle">Prévisualisation IA</div>
    <nav>
      <a href="#" class="active">Dashboard</a>
      ${navItems.map((n) => `<a href="#">${escapeHtml(n)}</a>`).join("")}
    </nav>
  </div>
  <div class="main">
    <h1>Dashboard</h1>
    <div class="desc">Application générée par SOULBAH IA</div>
    <div class="stats">
      <div class="stat-card"><div class="label">Composants</div><div class="value">${components.length}</div></div>
      <div class="stat-card"><div class="label">Endpoints API</div><div class="value">${endpoints.length}</div></div>
      <div class="stat-card"><div class="label">Tables DB</div><div class="value">${tables.length}</div></div>
    </div>

    ${endpoints.length > 0 ? `<div class="section-title">⚡ API Backend</div><table><thead><tr><th>Méthode</th><th>Route</th><th>Description</th></tr></thead><tbody>${endpointRows}</tbody></table>` : ""}

    ${tables.length > 0 ? `<div class="section-title">📦 Base de données</div>${tableCards}` : ""}

    ${components.length > 0 ? `<div class="section-title">🖥️ Composants Frontend</div>${componentPanels}` : ""}
  </div>
</div>
</body>
</html>`;
}

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const AppPreview = ({ open, onOpenChange, title, description, appType, techStack, architecture, applicationId, sourceCode, onAppUpdated }: AppPreviewProps) => {
  const [tab, setTab] = useState("preview");
  const previewHtml = buildPreviewHtml(title, architecture);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-[90vw] w-[1200px] h-[85vh] flex flex-col p-0 gap-0">
        <DialogHeader className="px-6 py-4 border-b border-border flex-shrink-0">
          <DialogTitle className="flex items-center gap-2 text-base">
            <Eye className="h-4 w-4 text-primary" />
            Prévisualisation — {title}
          </DialogTitle>
          <div className="flex items-center gap-3 text-xs text-muted-foreground mt-1">
            {appType && (
              <span className="flex items-center gap-1">
                <Globe className="h-3 w-3" /> {appType}
              </span>
            )}
            {techStack && (
              <span className="flex items-center gap-1">
                <Code2 className="h-3 w-3" /> {techStack}
              </span>
            )}
            {architecture?.database?.tables && (
              <span className="flex items-center gap-1">
                <Database className="h-3 w-3" /> {architecture.database.tables.length} tables
              </span>
            )}
          </div>
        </DialogHeader>

        <Tabs value={tab} onValueChange={setTab} className="flex-1 flex flex-col min-h-0">
          <TabsList className="mx-6 mt-3 w-fit">
            <TabsTrigger value="preview" className="text-xs gap-1.5">
              <Eye className="h-3.5 w-3.5" /> Aperçu Visuel
            </TabsTrigger>
            <TabsTrigger value="code" className="text-xs gap-1.5">
              <Code2 className="h-3.5 w-3.5" /> Code Source
            </TabsTrigger>
            <TabsTrigger value="api" className="text-xs gap-1.5">
              <Globe className="h-3.5 w-3.5" /> Architecture
            </TabsTrigger>
            {applicationId && onAppUpdated && (
              <TabsTrigger value="modify" className="text-xs gap-1.5">
                <MessageSquare className="h-3.5 w-3.5" /> Modifier
              </TabsTrigger>
            )}
          </TabsList>

          <TabsContent value="preview" className="flex-1 m-0 p-4 min-h-0">
            <div className="w-full h-full rounded-lg overflow-hidden border border-border">
              <iframe
                srcDoc={previewHtml}
                className="w-full h-full bg-background"
                sandbox="allow-scripts"
                title={`Prévisualisation de ${title}`}
              />
            </div>
          </TabsContent>

          <TabsContent value="code" className="flex-1 m-0 p-4 overflow-auto min-h-0">
            <div className="space-y-4">
              {architecture?.frontend?.components?.map((comp, i) => (
                <div key={i} className="rounded-lg border border-border bg-card p-4">
                  <h3 className="text-sm font-semibold text-foreground mb-1">{comp.name}</h3>
                  <p className="text-xs text-muted-foreground mb-3">{comp.description}</p>
                  <pre className="text-[11px] bg-secondary p-4 rounded-md overflow-x-auto max-h-60 font-mono leading-relaxed text-foreground">
                    {comp.code}
                  </pre>
                </div>
              ))}
              {(!architecture?.frontend?.components || architecture.frontend.components.length === 0) && (
                <p className="text-sm text-muted-foreground">Aucun composant généré.</p>
              )}
            </div>
          </TabsContent>

          <TabsContent value="api" className="flex-1 m-0 p-4 overflow-auto min-h-0">
            <div className="space-y-6">
              {/* Database */}
              {architecture?.database?.tables && architecture.database.tables.length > 0 && (
                <div>
                  <h3 className="text-sm font-semibold text-foreground mb-3 flex items-center gap-2">
                    <Database className="h-4 w-4 text-primary" /> Base de données
                  </h3>
                  <div className="space-y-3">
                    {architecture.database.tables.map((t, i) => (
                      <div key={i} className="rounded-lg border border-border bg-card p-4">
                        <span className="text-xs font-mono font-bold text-foreground">{t.name}</span>
                        {t.description && <p className="text-[10px] text-muted-foreground mt-1">{t.description}</p>}
                        <div className="flex flex-wrap gap-1.5 mt-2">
                          {t.columns.map((c, ci) => (
                            <span key={ci} className="text-[10px] bg-secondary px-2 py-0.5 rounded font-mono text-muted-foreground">{c}</span>
                          ))}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* Endpoints */}
              {architecture?.backend?.endpoints && architecture.backend.endpoints.length > 0 && (
                <div>
                  <h3 className="text-sm font-semibold text-foreground mb-3 flex items-center gap-2">
                    <Globe className="h-4 w-4 text-accent" /> API Backend
                  </h3>
                  <div className="space-y-2">
                    {architecture.backend.endpoints.map((ep, i) => (
                      <div key={i} className="flex items-center gap-3 text-xs p-2 rounded-md bg-card border border-border">
                        <span className={`font-mono font-bold px-2 py-0.5 rounded text-[10px] ${
                          ep.method === "GET" ? "bg-green-500/20 text-green-400" :
                          ep.method === "POST" ? "bg-blue-500/20 text-blue-400" :
                          ep.method === "PUT" ? "bg-yellow-500/20 text-yellow-400" :
                          "bg-red-500/20 text-red-400"
                        }`}>{ep.method}</span>
                        <span className="font-mono text-foreground">{ep.path}</span>
                        <span className="text-muted-foreground">— {ep.description}</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </TabsContent>
          {applicationId && onAppUpdated && (
            <TabsContent value="modify" className="flex-1 m-0 min-h-0">
              <AppChatPanel
                applicationId={applicationId}
                appTitle={title}
                existingArchitecture={sourceCode}
                onAppUpdated={onAppUpdated}
              />
            </TabsContent>
          )}
        </Tabs>
      </DialogContent>
    </Dialog>
  );
};

export default AppPreview;
