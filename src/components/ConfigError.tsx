import { AlertTriangle } from "lucide-react";

/** Écran affiché à la place de l'application quand la configuration est incomplète. */
const ConfigError = ({ message }: { message: string }) => (
  <div className="min-h-screen bg-background flex items-center justify-center p-6">
    <div role="alert" className="max-w-lg w-full rounded-lg border border-destructive/40 bg-card p-6 space-y-3">
      <div className="flex items-center gap-2 text-destructive">
        <AlertTriangle className="h-5 w-5" aria-hidden="true" />
        <h1 className="text-base font-semibold">Configuration incomplète</h1>
      </div>
      <p className="text-sm text-foreground">{message}</p>
      <p className="text-xs text-muted-foreground">
        Exemple de fichier <code className="bg-secondary px-1 rounded">.env</code> :
      </p>
      <pre className="text-xs bg-secondary rounded p-3 overflow-x-auto">
{`VITE_SUPABASE_URL=https://xxxx.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=eyJ...
VITE_API_URL=http://localhost:3000`}
      </pre>
    </div>
  </div>
);

export default ConfigError;
