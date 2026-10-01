import { Component, ErrorInfo, ReactNode } from "react";

interface Props {
  children: ReactNode;
}

interface State {
  error: Error | null;
}

/**
 * Empêche l'écran blanc : si un composant lève une exception au rendu, on affiche
 * un message lisible (avec l'erreur) au lieu de démonter toute l'application.
 * L'utilisateur peut réessayer sans perdre sa session.
 */
class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Trace complète dans la console pour le diagnostic
    console.error("[ErrorBoundary] Crash intercepté :", error, info.componentStack);
  }

  handleReset = () => {
    this.setState({ error: null });
  };

  render() {
    if (this.state.error) {
      return (
        <div className="min-h-screen bg-background flex items-center justify-center p-6">
          <div className="max-w-lg w-full rounded-lg border border-destructive/40 bg-card p-6 space-y-4">
            <h2 className="text-lg font-semibold text-destructive">Une erreur s'est produite</h2>
            <p className="text-sm text-muted-foreground">
              L'affichage a rencontré un problème, mais votre session est intacte. Voici le détail
              technique (utile pour le diagnostic) :
            </p>
            <pre className="text-xs bg-secondary rounded p-3 overflow-x-auto whitespace-pre-wrap max-h-48">
              {this.state.error.message}
              {this.state.error.stack ? `\n\n${this.state.error.stack}` : ""}
            </pre>
            <div className="flex gap-2">
              <button
                onClick={this.handleReset}
                className="rounded-md bg-primary text-primary-foreground text-sm px-4 py-2 hover:bg-primary/90"
              >
                Réessayer
              </button>
              <button
                onClick={() => window.location.reload()}
                className="rounded-md border border-border text-sm px-4 py-2 hover:bg-secondary"
              >
                Recharger la page
              </button>
            </div>
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}

export default ErrorBoundary;
