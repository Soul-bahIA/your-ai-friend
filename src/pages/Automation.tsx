import DashboardLayout from "@/components/DashboardLayout";
import AgentTasksPanel from "@/components/AgentTasksPanel";
import AgentCockpit from "@/components/AgentCockpit";
import { Monitor, Terminal, Lightbulb } from "lucide-react";

const Automation = () => {
  return (
    <DashboardLayout>
      <div className="px-4 py-6 md:px-8 md:py-8 max-w-4xl space-y-6">
        <div>
          <h1 className="text-3xl font-bold tracking-tight flex items-center gap-2">
            <Monitor className="h-7 w-7 text-primary" /> Agent Local
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Décrivez un objectif — l'IA planifie les étapes, l'agent installé sur votre poste les
            exécute, puis vérifie le résultat.
          </p>
        </div>

        {/* Encart : à quoi sert cet outil + prérequis */}
        <div className="rounded-lg border border-primary/30 bg-primary/5 p-4 space-y-3">
          <div className="flex items-start gap-2">
            <Lightbulb className="h-4 w-4 text-primary mt-0.5 shrink-0" />
            <div className="text-xs text-muted-foreground space-y-2">
              <p>
                <span className="font-semibold text-foreground">Cet outil pilote votre ordinateur</span> :
                ouvrir des logiciels, taper, cliquer, gérer des fichiers, exécuter des commandes (Git,
                tests…), enregistrer une vidéo de démo.
              </p>
              <p>
                Exemples : «&nbsp;<span className="text-foreground">Ouvre VS Code et crée un fichier main.py</span>&nbsp;»,
                «&nbsp;<span className="text-foreground">Range les images du bureau dans un dossier Photos</span>&nbsp;».
              </p>
              <p className="text-warning">
                ⚠️ Pour <span className="font-semibold">créer une formation ou une application</span>,
                utilisez plutôt les pages <span className="font-semibold">Formations</span> et{" "}
                <span className="font-semibold">Applications</span> — pas cet outil.
              </p>
            </div>
          </div>
          <div className="flex items-start gap-2 border-t border-primary/20 pt-3">
            <Terminal className="h-4 w-4 text-primary mt-0.5 shrink-0" />
            <div className="text-xs text-muted-foreground space-y-1">
              <p className="font-semibold text-foreground">Prérequis : lancez l'agent sur votre poste</p>
              <p>
                Après avoir cliqué «&nbsp;Planifier&nbsp;», la tâche reste en attente tant que l'agent
                n'est pas démarré. Dans un terminal :
              </p>
              <pre className="bg-secondary rounded p-2 mt-1 overflow-x-auto text-[11px]">cd "chemin\vers\Soulbah IA\agent"
python soulbah_agent.py</pre>
              <p>
                L'agent va chercher la tâche, vous demande confirmation avant chaque action sensible,
                puis l'exécute réellement.
              </p>
            </div>
          </div>
        </div>

        {/* Poste de pilotage temps réel : écran live + timeline + contrôles */}
        <AgentCockpit />

        <AgentTasksPanel />
      </div>
    </DashboardLayout>
  );
};

export default Automation;
