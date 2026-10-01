import { useState, useEffect, useCallback, useRef } from "react";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Eye, Code2, Database, Globe, MousePointer, Send, Loader2, X, Pencil } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { useToast } from "@/hooks/use-toast";
import { apiFetch, errorMessage } from "@/lib/api";
import type { GenerateApplicationResponse, GeneratedApplication } from "@/types/application";
import type { Json } from "@/integrations/supabase/types";
import {
  buildPreviewHtml,
  parsePreviewMessage,
  type AppArchitecture,
  type SelectedElement,
} from "@/lib/appPreview";

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
  onAppUpdated?: (result: GeneratedApplication) => void;
}

const AppPreview = ({ open, onOpenChange, title, description, appType, techStack, architecture, applicationId, sourceCode, onAppUpdated }: AppPreviewProps) => {
  const { user } = useAuth();
  const { toast } = useToast();
  const [tab, setTab] = useState("preview");
  const [editMode, setEditMode] = useState(false);
  const [selectedElement, setSelectedElement] = useState<SelectedElement | null>(null);
  const [editInput, setEditInput] = useState("");
  const [sending, setSending] = useState(false);
  const [previewKey, setPreviewKey] = useState(0);
  const frameRef = useRef<HTMLIFrameElement>(null);

  const previewHtml = buildPreviewHtml(title, architecture, editMode, window.location.origin);

  useEffect(() => {
    // Seuls les messages de NOTRE iframe (origine opaque du srcdoc sandboxé) sont acceptés.
    const handler = (e: MessageEvent) => {
      const element = parsePreviewMessage(e, frameRef.current?.contentWindow ?? null);
      if (!element) return;
      setSelectedElement(element);
      setEditInput("");
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

  const buildInstruction = (userInput: string, element: SelectedElement | null): string => {
    if (!element) return userInput;
    
    // Map element types to specific architecture paths for clarity
    const typeMap: Record<string, string> = {
      table: "dans la section database.tables",
      endpoint: "dans la section backend.endpoints",
      component: "dans la section frontend.components",
      nav: "dans la navigation (frontend.components)",
      title: "le titre de l'application",
      heading: "le titre principal",
      description: "la description de l'application",
      stat: "les statistiques affichées",
      section: "la section",
    };
    
    const context = typeMap[element.type] || "";
    return `ACTION DEMANDÉE sur "${element.name}" ${context}: ${userInput}. Applique cette modification EXACTEMENT et retourne l'architecture COMPLÈTE modifiée.`;
  };

  const handleSendModification = useCallback(async () => {
    if (!editInput.trim() || !applicationId || !user || !onAppUpdated || sending) return;
    setSending(true);

    const instruction = buildInstruction(editInput, selectedElement);

    try {
      const result = await apiFetch<GenerateApplicationResponse>("/api/generate/application", {
        method: "POST",
        json: {
          appName: title,
          applicationId,
          conversationHistory: [{ role: "user", content: instruction }],
          existingArchitecture: sourceCode || {},
        },
      });
      if (!result?.application) throw new Error(result?.error || "Échec de la modification");

      onAppUpdated(result.application);
      setSelectedElement(null);
      setEditInput("");
      setPreviewKey((k) => k + 1);
      toast({ title: "✅ Modification appliquée", description: `Votre modification a été appliquée avec succès.` });
    } catch (err) {
      toast({ title: "Erreur", description: errorMessage(err), variant: "destructive" });
    }

    setSending(false);
  }, [editInput, applicationId, user, onAppUpdated, sending, selectedElement, sourceCode, title, toast]);

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
                ref={frameRef}
                key={previewKey}
                srcDoc={previewHtml}
                className="w-full h-full bg-background"
                // Scripts uniquement en mode édition (sélection d'éléments), jamais allow-same-origin.
                sandbox={editMode ? "allow-scripts" : ""}
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
                    <button onClick={() => setSelectedElement(null)} className="text-muted-foreground hover:text-foreground" aria-label="Désélectionner l'élément">
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
