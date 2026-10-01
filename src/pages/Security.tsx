import { useCallback, useEffect, useState } from "react";
import DashboardLayout from "@/components/DashboardLayout";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Shield, Lock, Eye, KeyRound, Plus, Trash2, Copy, Check, Loader2 } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { Switch } from "@/components/ui/switch";
import { Label } from "@/components/ui/label";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { apiFetch, errorMessage } from "@/lib/api";
import ConfirmAction from "@/components/ConfirmAction";
import ErrorState from "@/components/ErrorState";
import { useToast } from "@/hooks/use-toast";

interface AgentKey {
  id: string;
  label: string | null;
  created_at: string;
  last_used_at: string | null;
}

const Security = () => {
  const { user } = useAuth();
  const userId = user?.id;
  const { toast } = useToast();
  const [keys, setKeys] = useState<AgentKey[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [newLabel, setNewLabel] = useState("");
  const [freshKey, setFreshKey] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  const loadKeys = useCallback(async () => {
    setLoadError(null);
    try {
      const data = await apiFetch<{ keys?: AgentKey[] }>("/api/agent-keys");
      setKeys(data?.keys ?? []);
    } catch (e) {
      console.warn("[Security] chargement des clés:", e);
      setLoadError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (userId) loadKeys();
  }, [userId, loadKeys]);

  const createKey = async () => {
    setCreating(true);
    try {
      const data = await apiFetch<{ key?: string }>("/api/agent-keys", {
        method: "POST",
        json: { label: newLabel.trim() || null },
      });
      setFreshKey(data?.key ?? null);
      setNewLabel("");
      setCopied(false);
      loadKeys();
    } catch (e) {
      toast({ title: "Erreur", description: errorMessage(e), variant: "destructive" });
    } finally {
      setCreating(false);
    }
  };

  const revokeKey = async (id: string) => {
    try {
      await apiFetch(`/api/agent-keys/${id}`, { method: "DELETE" });
      setKeys((prev) => prev.filter((k) => k.id !== id));
      toast({ title: "Clé révoquée" });
    } catch (e) {
      toast({ title: "Erreur", description: errorMessage(e), variant: "destructive" });
    }
  };

  const copyKey = async () => {
    if (!freshKey) return;
    try {
      await navigator.clipboard.writeText(freshKey);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast({ title: "Copie impossible", description: "Sélectionnez la clé et copiez-la manuellement.", variant: "destructive" });
    }
  };

  return (
    <DashboardLayout>
      <div className="space-y-6">
        <h1 className="text-3xl font-bold">Sécurité</h1>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Lock className="h-5 w-5" /> Authentification
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <p className="text-sm text-muted-foreground">
              Connecté en tant que <span className="font-medium text-foreground">{user?.email}</span>
            </p>
            <div className="flex items-center justify-between">
              <Label>Authentification à deux facteurs</Label>
              <Switch disabled />
            </div>
            <p className="text-xs text-muted-foreground">Bientôt disponible</p>
          </CardContent>
        </Card>

        {/* Clés de l'agent local */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <KeyRound className="h-5 w-5" /> Clés de l'agent local
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <p className="text-sm text-muted-foreground">
              Générez une clé pour autoriser le worker <span className="font-mono">SoulBah Agent</span> à
              récupérer vos tâches. La clé n'est affichée qu'une seule fois — copiez-la dans
              <span className="font-mono"> agent/.env</span> (<span className="font-mono">SOULBAH_AGENT_KEY</span>).
            </p>

            {/* Clé fraîchement créée (affichée une seule fois) */}
            {freshKey && (
              <div className="rounded-md border border-primary/40 bg-primary/5 p-3 space-y-2">
                <p className="text-xs font-medium text-primary">
                  Nouvelle clé — copiez-la maintenant, elle ne sera plus jamais affichée :
                </p>
                <div className="flex items-center gap-2">
                  <code className="flex-1 text-xs font-mono bg-background rounded px-2 py-1.5 overflow-x-auto whitespace-nowrap">
                    {freshKey}
                  </code>
                  <Button size="icon" variant="outline" onClick={copyKey} aria-label="Copier la clé">
                    {copied ? <Check className="h-4 w-4 text-success" /> : <Copy className="h-4 w-4" />}
                  </Button>
                </div>
                <button
                  onClick={() => setFreshKey(null)}
                  className="text-[11px] text-muted-foreground hover:text-foreground"
                >
                  J'ai copié la clé — masquer
                </button>
              </div>
            )}

            {/* Générateur */}
            <div className="flex gap-2">
              <Input
                placeholder="Nom (ex: PC bureau)"
                value={newLabel}
                onChange={(e) => setNewLabel(e.target.value)}
                className="flex-1"
              />
              <Button onClick={createKey} disabled={creating}>
                {creating ? <Loader2 className="h-4 w-4 animate-spin" /> : <><Plus className="h-4 w-4 mr-1" /> Générer</>}
              </Button>
            </div>

            {/* Liste des clés */}
            {loading ? (
              <p className="text-xs text-muted-foreground">Chargement...</p>
            ) : loadError ? (
              <ErrorState
                compact
                message="Impossible de charger les clés de l'agent."
                detail={loadError}
                onRetry={() => {
                  setLoading(true);
                  loadKeys();
                }}
              />
            ) : keys.length === 0 ? (
              <p className="text-xs text-muted-foreground">Aucune clé active.</p>
            ) : (
              <div className="space-y-2">
                {keys.map((k) => (
                  <div key={k.id} className="flex items-center justify-between rounded-md border border-border p-2.5">
                    <div>
                      <p className="text-sm font-medium">{k.label || "Sans nom"}</p>
                      <p className="text-[10px] text-muted-foreground">
                        Créée le {new Date(k.created_at).toLocaleDateString("fr-FR")}
                        {k.last_used_at
                          ? ` · dernière utilisation ${new Date(k.last_used_at).toLocaleString("fr-FR")}`
                          : " · jamais utilisée"}
                      </p>
                    </div>
                    <ConfirmAction
                      title="Révoquer cette clé ?"
                      description={`L'agent utilisant la clé « ${k.label || "Sans nom"} » ne pourra plus se connecter.`}
                      confirmLabel="Révoquer"
                      onConfirm={() => revokeKey(k.id)}
                      trigger={
                        <Button size="icon" variant="ghost" aria-label={`Révoquer la clé « ${k.label || "Sans nom"} »`}>
                          <Trash2 className="h-4 w-4 text-destructive" />
                        </Button>
                      }
                    />
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Eye className="h-5 w-5" /> Sessions actives
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-sm text-muted-foreground">Session actuelle active depuis votre navigateur.</p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Shield className="h-5 w-5" /> Isolation des données
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-sm text-muted-foreground">
              Vos données sont isolées grâce aux politiques de sécurité (RLS). Aucun autre utilisateur ne peut accéder à vos tables et données.
            </p>
          </CardContent>
        </Card>
      </div>
    </DashboardLayout>
  );
};

export default Security;
