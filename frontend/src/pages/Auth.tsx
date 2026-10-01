import { useState } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import { useAuth } from "@/hooks/useAuth";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Brain, LogIn, UserPlus, Mail, Lock, User } from "lucide-react";
import { useToast } from "@/hooks/use-toast";

const Auth = () => {
  const [isLogin, setIsLogin] = useState(true);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [loading, setLoading] = useState(false);
  const navigate = useNavigate();
  const { toast } = useToast();
  const { user, loading: authLoading } = useAuth();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);

    try {
      if (isLogin) {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
        navigate("/");
      } else {
        const { data, error } = await supabase.auth.signUp({
          email,
          password,
          options: {
            data: { display_name: displayName },
            emailRedirectTo: window.location.origin,
          },
        });
        if (error) throw error;

        // Supabase renvoie un user sans identités quand l'email existe déjà
        if (data.user && data.user.identities && data.user.identities.length === 0) {
          throw new Error("User already registered");
        }

        if (data.session) {
          // Confirmation email désactivée : l'utilisateur est connecté immédiatement
          toast({
            title: "Compte créé !",
            description: "Bienvenue sur SOULBAH IA.",
          });
          navigate("/");
        } else {
          // Confirmation email activée : tenter une connexion directe au cas où,
          // sinon inviter à confirmer l'email
          const { error: signInError } = await supabase.auth.signInWithPassword({
            email,
            password,
          });
          if (!signInError) {
            navigate("/");
          } else {
            toast({
              title: "Compte créé !",
              description:
                "Vérifiez votre email pour confirmer votre inscription, puis connectez-vous.",
            });
            setIsLogin(true);
          }
        }
      }
    } catch (error) {
      const raw = error instanceof Error ? error.message : String(error);
      let message = raw || "Une erreur est survenue.";
      if (raw.includes("User already registered")) {
        message = "Ce compte existe déjà. Passez à la connexion.";
      } else if (raw.includes("Email not confirmed")) {
        message =
          "Email non confirmé. Cliquez sur le lien reçu par email avant de vous connecter.";
      } else if (raw.includes("Invalid login credentials")) {
        message = "Email ou mot de passe incorrect.";
      }
      toast({
        title: "Erreur",
        description: message,
        variant: "destructive",
      });
    } finally {
      setLoading(false);
    }
  };

  // Déjà connecté : pas besoin de la page de connexion.
  if (!authLoading && user) {
    return <Navigate to="/" replace />;
  }

  return (
    <div className="min-h-screen bg-background bg-mesh flex items-center justify-center p-4">
      <div className="bg-grid fixed inset-0 pointer-events-none" />
      <div className="w-full max-w-md relative z-10">
        {/* Logo */}
        <div className="flex items-center justify-center gap-3 mb-8">
          <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-primary/10 glow-primary">
            <Brain className="h-7 w-7 text-primary" />
          </div>
          <div>
            <h1 className="text-xl font-bold text-foreground tracking-tight">SOULBAH IA</h1>
            <p className="text-[10px] text-muted-foreground font-mono">Plateforme IA Autonome</p>
          </div>
        </div>

        {/* Card */}
        <div className="rounded-lg border border-border bg-card p-6">
          <h2 className="text-lg font-semibold text-foreground mb-1">
            {isLogin ? "Connexion" : "Inscription"}
          </h2>
          <p className="text-xs text-muted-foreground mb-6">
            {isLogin ? "Accédez à votre centre de commande" : "Créez votre compte SOULBAH"}
          </p>

          <form onSubmit={handleSubmit} className="space-y-4">
            {!isLogin && (
              <div>
                <label className="text-xs text-muted-foreground mb-1 block">Nom d'affichage</label>
                <div className="relative">
                  <User className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
                  <Input
                    placeholder="Votre nom"
                    value={displayName}
                    onChange={(e) => setDisplayName(e.target.value)}
                    className="bg-secondary border-border pl-10"
                    required
                  />
                </div>
              </div>
            )}
            <div>
              <label className="text-xs text-muted-foreground mb-1 block">Email</label>
              <div className="relative">
                <Mail className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
                <Input
                  type="email"
                  placeholder="vous@exemple.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="bg-secondary border-border pl-10"
                  required
                />
              </div>
            </div>
            <div>
              <label className="text-xs text-muted-foreground mb-1 block">Mot de passe</label>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
                <Input
                  type="password"
                  placeholder="••••••••"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="bg-secondary border-border pl-10"
                  required
                  minLength={6}
                />
              </div>
            </div>
            <Button type="submit" className="w-full glow-primary" disabled={loading}>
              {loading ? (
                "Chargement..."
              ) : isLogin ? (
                <><LogIn className="h-4 w-4 mr-2" /> Se connecter</>
              ) : (
                <><UserPlus className="h-4 w-4 mr-2" /> S'inscrire</>
              )}
            </Button>
          </form>

          <div className="mt-4 text-center">
            <button
              onClick={() => setIsLogin(!isLogin)}
              className="text-xs text-muted-foreground hover:text-primary transition-colors"
            >
              {isLogin ? "Pas de compte ? S'inscrire" : "Déjà un compte ? Se connecter"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Auth;
