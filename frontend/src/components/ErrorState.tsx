import { AlertTriangle, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";

interface ErrorStateProps {
  message?: string;
  detail?: string | null;
  onRetry?: () => void;
  compact?: boolean;
}

/** État d'erreur explicite (au lieu d'un état vide trompeur) avec bouton « Réessayer ». */
const ErrorState = ({
  message = "Impossible de charger les données.",
  detail,
  onRetry,
  compact = false,
}: ErrorStateProps) => (
  <div
    role="alert"
    className={`rounded-md border border-destructive/30 bg-destructive/5 text-center ${compact ? "p-3" : "p-6"}`}
  >
    <AlertTriangle className={`mx-auto text-destructive ${compact ? "h-4 w-4 mb-1" : "h-6 w-6 mb-2"}`} aria-hidden="true" />
    <p className="text-xs font-medium text-foreground">{message}</p>
    {detail && <p className="text-[10px] text-muted-foreground mt-1 break-words">{detail}</p>}
    {onRetry && (
      <Button variant="outline" size="sm" className="mt-3 h-7 text-xs gap-1" onClick={onRetry}>
        <RefreshCw className="h-3 w-3" aria-hidden="true" /> Réessayer
      </Button>
    )}
  </div>
);

export default ErrorState;
