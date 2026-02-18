import { useState, useEffect, useCallback } from "react";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Eye, Code2, Database, Globe, MousePointer, Send, Loader2, X, Pencil } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { useToast } from "@/hooks/use-toast";
import type { Json } from "@/integrations/supabase/types";

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
  sourceCode?: Json | null;
  onAppUpdated?: (result: any) => void;
}

function buildPreviewHtml(title: string, architecture: AppArchitecture | null, editMode: boolean): string {
  const components = architecture?.frontend?.components || [];
  const tables = architecture?.database?.tables || [];
  const endpoints = architecture?.backend?.endpoints || [];

  const navItems = components.map((c) => c.name).slice(0, 5);
  const sel = editMode ? 'class="selectable"' : '';
  const cur = editMode ? 'cursor:pointer;' : '';

  const tableCards = tables.map((t) => `
    <div ${sel} data-element-type="table" data-element-name="${t.name}" style="background:#1e293b;border-radius:8px;padding:16px;margin-bottom:12px;${cur}transition:outline 0.15s;">
      <div style="font-weight:600;color:#e2e8f0;margin-bottom:4px;">📦 ${t.name}</div>
      <div style="font-size:11px;color:#94a3b8;margin-bottom:8px;">${t.description || ""}</div>
      <div style="display:flex;flex-wrap:wrap;gap:4px;">
        ${t.columns.map((c) => `<span style="background:#334155;color:#cbd5e1;padding:2px 8px;border-radius:4px;font-size:10px;font-family:monospace;">${c}</span>`).join("")}
      </div>
    </div>`).join("");

  const endpointRows = endpoints.map((ep) => `
    <tr ${sel} data-element-type="endpoint" data-element-name="${ep.method} ${ep.path}" style="${cur}transition:outline 0.15s;">
      <td style="padding:6px 10px;"><span style="background:${ep.method === "GET" ? "#059669" : ep.method === "POST" ? "#2563eb" : ep.method === "PUT" ? "#d97706" : "#dc2626"};color:white;padding:2px 8px;border-radius:4px;font-size:10px;font-weight:700;">${ep.method}</span></td>
      <td style="padding:6px 10px;font-family:monospace;font-size:12px;color:#e2e8f0;">${ep.path}</td>
      <td style="padding:6px 10px;font-size:11px;color:#94a3b8;">${ep.description}</td>
    </tr>`).join("");

  const componentPanels = components.map((comp) => `
    <div ${sel} data-element-type="component" data-element-name="${comp.name}" style="background:#1e293b;border-radius:8px;padding:16px;margin-bottom:12px;${cur}transition:outline 0.15s;">
      <div style="font-weight:600;color:#e2e8f0;margin-bottom:2px;">🖥️ ${comp.name}</div>
      <div style="font-size:11px;color:#94a3b8;margin-bottom:8px;">${comp.description}</div>
      <pre style="background:#0f172a;color:#7dd3fc;padding:12px;border-radius:6px;font-size:10px;overflow-x:auto;max-height:200px;line-height:1.5;">${escapeHtml(comp.code)}</pre>
    </div>`).join("");

  const interactiveScript = editMode ? `<script>
    let selected = null;
    document.addEventListener('click', function(e) {
      const el = e.target.closest('.selectable');
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
      }, '*');
    });
    document.addEventListener('mouseover', function(e) {
      const el = e.target.closest('.selectable');
      if (el && el !== selected) {
        el.style.outline = '1px dashed #a855f780';
        el.style.outlineOffset = '2px';
      }
    });
    document.addEventListener('mouseout', function(e) {
      const el = e.target.closest('.selectable');
      if (el && el !== selected) {
        el.style.outline = 'none';
      }
    });
  </script>` : "";

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
  ${editMode ? `.edit-banner { background:linear-gradient(135deg,#7c3aed20,#a855f720); border:1px solid #a855f740; border-radius:8px; padding:10px 16px; margin-bottom:20px; display:flex; align-items:center; gap:8px; }
  .edit-banner .dot { width:8px; height:8px; border-radius:50%; background:#a855f7; animation:pulse 1.5s infinite; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
  .edit-banner span { font-size:12px; color:#c4b5fd; }` : ""}
</style>
</head>
<body>
<div class="app-container">
  <div class="sidebar">
    <h2 ${sel} data-element-type="title" data-element-name="Titre de l'app" style="${cur}">${escapeHtml(title)}</h2>
    <div class="subtitle">Prévisualisation IA</div>
    <nav>
      <a href="#" class="active ${editMode ? 'selectable' : ''}" data-element-type="nav" data-element-name="Dashboard" style="${cur}">Dashboard</a>
      ${navItems.map((n) => `<a href="#" ${sel} data-element-type="nav" data-element-name="${escapeHtml(n)}" style="${cur}">${escapeHtml(n)}</a>`).join("")}
    </nav>
  </div>
  <div class="main">
    ${editMode ? '<div class="edit-banner"><div class="dot"></div><span>Mode édition actif — Cliquez sur un élément pour le modifier</span></div>' : ''}
    <h1 ${sel} data-element-type="heading" data-element-name="Titre principal" style="${cur}">Dashboard</h1>
    <div class="desc ${editMode ? 'selectable' : ''}" data-element-type="description" data-element-name="Description" style="${cur}">Application générée par SOULBAH IA</div>
    <div class="stats">
      <div class="stat-card ${editMode ? 'selectable' : ''}" data-element-type="stat" data-element-name="Composants" style="${cur}"><div class="label">Composants</div><div class="value">${components.length}</div></div>
      <div class="stat-card ${editMode ? 'selectable' : ''}" data-element-type="stat" data-element-name="Endpoints API" style="${cur}"><div class="label">Endpoints API</div><div class="value">${endpoints.length}</div></div>
      <div class="stat-card ${editMode ? 'selectable' : ''}" data-element-type="stat" data-element-name="Tables DB" style="${cur}"><div class="label">Tables DB</div><div class="value">${tables.length}</div></div>
    </div>
    ${endpoints.length > 0 ? `<div class="section-title ${editMode ? 'selectable' : ''}" data-element-type="section" data-element-name="API Backend" style="${cur}">⚡ API Backend</div><table><thead><tr><th>Méthode</th><th>Route</th><th>Description</th></tr></thead><tbody>${endpointRows}</tbody></table>` : ""}
    ${tables.length > 0 ? `<div class="section-title ${editMode ? 'selectable' : ''}" data-element-type="section" data-element-name="Base de données" style="${cur}">📦 Base de données</div>${tableCards}` : ""}
    ${components.length > 0 ? `<div class="section-title ${editMode ? 'selectable' : ''}" data-element-type="section" data-element-name="Composants Frontend" style="${cur}">🖥️ Composants Frontend</div>${componentPanels}` : ""}
  </div>
</div>
${interactiveScript}
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

interface SelectedElement {
  type: string;
  name: string;
  text: string;
}

const AppPreview = ({ open, onOpenChange, title, description, appType, techStack, architecture, applicationId, sourceCode, onAppUpdated }: AppPreviewProps) => {
  const { session } = useAuth();
  const { toast } = useToast();
  const [tab, setTab] = useState("preview");
  const [editMode, setEditMode] = useState(false);
  const [selectedElement, setSelectedElement] = useState<SelectedElement | null>(null);
  const [editInput, setEditInput] = useState("");
  const [sending, setSending] = useState(false);

  const previewHtml = buildPreviewHtml(title, architecture, editMode);

  useEffect(() => {
    const handler = (e: MessageEvent) => {
      if (e.data?.type === "element-selected") {
        setSelectedElement({
          type: e.data.elementType,
          name: e.data.elementName,
          text: e.data.text,
        });
        setEditInput("");
      }
    };
    window.addEventListener("message", handler);
    return () => window.removeEventListener("message", handler);
  }, []);

  // Reset on close or tab change
  useEffect(() => {
    if (!open) {
      setEditMode(false);
      setSelectedElement(null);
      setEditInput("");
    }
  }, [open]);

  useEffect(() => {
    setSelectedElement(null);
    setEditInput("");
  }, [editMode]);

  const handleSendModification = useCallback(async () => {
    if (!editInput.trim() || !applicationId || !session || !onAppUpdated || sending) return;
    setSending(true);

    const instruction = selectedElement
      ? `Modifie l'élément "${selectedElement.name}" (type: ${selectedElement.type}). Voici ce que l'utilisateur veut : ${editInput}`
      : editInput;

    try {
      const response = await fetch(
        `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/generate-application`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${session.access_token}`,
            apikey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
          },
          body: JSON.stringify({
            appName: title,
            applicationId,
            conversationHistory: [{ role: "user", content: instruction }],
            existingArchitecture: sourceCode || {},
          }),
        }
      );

      const result = await response.json();
      if (!response.ok) throw new Error(result.error || "Échec de la modification");

      onAppUpdated(result.application);
      setSelectedElement(null);
      setEditInput("");
      toast({ title: "✅ Modification appliquée", description: `Votre modification a été appliquée avec succès.` });
    } catch (err: any) {
      toast({ title: "Erreur", description: err.message, variant: "destructive" });
    }

    setSending(false);
  }, [editInput, applicationId, session, onAppUpdated, sending, selectedElement, sourceCode, title, toast]);

  const canEdit = !!applicationId && !!onAppUpdated;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-[90vw] w-[1200px] h-[85vh] flex flex-col p-0 gap-0">
        <DialogHeader className="px-6 py-4 border-b border-border flex-shrink-0">
          <div className="flex items-center justify-between">
            <div>
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
            </div>
            {canEdit && (
              <Button
                size="sm"
                variant={editMode ? "default" : "outline"}
                className={`gap-1.5 ${editMode ? "bg-accent text-accent-foreground" : "border-accent/30 text-accent hover:bg-accent/10"}`}
                onClick={() => setEditMode(!editMode)}
              >
                {editMode ? (
                  <>
                    <MousePointer className="h-3.5 w-3.5" />
                    Mode Édition Actif
                  </>
                ) : (
                  <>
                    <Pencil className="h-3.5 w-3.5" />
                    Activer l'Édition
                  </>
                )}
              </Button>
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
          </TabsList>

          <TabsContent value="preview" className="flex-1 m-0 p-4 min-h-0 relative">
            <div className="w-full h-full rounded-lg overflow-hidden border border-border">
              <iframe
                srcDoc={previewHtml}
                className="w-full h-full bg-background"
                sandbox="allow-scripts"
                title={`Prévisualisation de ${title}`}
              />
            </div>

            {/* Floating edit bar */}
            {selectedElement && editMode && canEdit && (
              <div className="absolute bottom-6 left-6 right-6 z-50 animate-fade-in">
                <div className="rounded-xl border border-accent/40 bg-card shadow-2xl p-4">
                  <div className="flex items-center justify-between mb-2">
                    <div className="flex items-center gap-2">
                      <div className="h-2 w-2 rounded-full bg-accent animate-pulse" />
                      <span className="text-xs font-semibold text-accent">Sélectionné :</span>
                      <span className="text-xs font-mono text-foreground bg-secondary px-2 py-0.5 rounded">
                        {selectedElement.name}
                      </span>
                      <span className="text-[10px] text-muted-foreground">({selectedElement.type})</span>
                    </div>
                    <button onClick={() => setSelectedElement(null)} className="text-muted-foreground hover:text-foreground">
                      <X className="h-4 w-4" />
                    </button>
                  </div>
                  <form onSubmit={(e) => { e.preventDefault(); handleSendModification(); }} className="flex gap-2">
                    <Input
                      value={editInput}
                      onChange={(e) => setEditInput(e.target.value)}
                      placeholder="Ex: Supprime cet élément, Renomme en..., Ajoute une colonne email..."
                      className="bg-secondary border-border text-sm h-9 flex-1"
                      disabled={sending}
                      autoFocus
                    />
                    <Button type="submit" size="sm" className="h-9 px-4 bg-accent text-accent-foreground gap-1.5" disabled={sending || !editInput.trim()}>
                      {sending ? <Loader2 className="h-4 w-4 animate-spin" /> : <><Send className="h-3.5 w-3.5" /> Appliquer</>}
                    </Button>
                  </form>
                </div>
              </div>
            )}
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
        </Tabs>
      </DialogContent>
    </Dialog>
  );
};

export default AppPreview;
