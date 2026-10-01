import DashboardLayout from "@/components/DashboardLayout";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { useAuth } from "@/hooks/useAuth";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { useToast } from "@/hooks/use-toast";
import { User, Shield, Bell } from "lucide-react";
import { errorMessage } from "@/lib/api";

const Settings = () => {
  const { user, signOut } = useAuth();
  const { toast } = useToast();
  const [displayName, setDisplayName] = useState("");
  const [bio, setBio] = useState("");
  const [loading, setLoading] = useState(false);

  const userId = user?.id;

  useEffect(() => {
    if (!userId) return;
    let ignore = false;
    (async () => {
      const { data, error } = await supabase
        .from("profiles")
        .select("display_name, bio")
        .eq("user_id", userId)
        .maybeSingle();
      if (ignore) return;
      if (error) {
        console.error("[Settings] Chargement du profil échoué:", error.message);
        toast({ title: "Profil indisponible", description: error.message, variant: "destructive" });
        return;
      }
      if (data) {
        setDisplayName(data.display_name || "");
        setBio(data.bio || "");
      }
    })();
    return () => {
      ignore = true;
    };
  }, [userId, toast]);

  const handleSave = async () => {
    if (!userId) return;
    setLoading(true);
    try {
      const { error } = await supabase
        .from("profiles")
        .upsert({ user_id: userId, display_name: displayName, bio }, { onConflict: "user_id" });
      if (error) throw error;
      toast({ title: "Profil mis à jour" });
    } catch (e) {
      toast({ title: "Erreur", description: errorMessage(e), variant: "destructive" });
    } finally {
      setLoading(false);
    }
  };

  return (
    <DashboardLayout>
      <div className="space-y-6">
        <h1 className="text-3xl font-bold">Paramètres</h1>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <User className="h-5 w-5" /> Profil
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div>
              <Label>Email</Label>
              <Input value={user?.email || ""} disabled />
            </div>
            <div>
              <Label>Nom d'affichage</Label>
              <Input value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="Votre nom" />
            </div>
            <div>
              <Label>Bio</Label>
              <Textarea value={bio} onChange={(e) => setBio(e.target.value)} placeholder="Quelques mots sur vous..." />
            </div>
            <Button onClick={handleSave} disabled={loading}>
              {loading ? "Enregistrement..." : "Enregistrer"}
            </Button>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Shield className="h-5 w-5" /> Sécurité
            </CardTitle>
          </CardHeader>
          <CardContent>
            <Button variant="destructive" onClick={signOut}>
              Se déconnecter
            </Button>
          </CardContent>
        </Card>
      </div>
    </DashboardLayout>
  );
};

export default Settings;
