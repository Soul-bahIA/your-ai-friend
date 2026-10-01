// NON UTILISÉ depuis le LOT 1 : POST /api/formations/:id/demos répond 501 (ces tâches
// n'avaient pas d'étapes). Conservé comme extraction des plans de démo pour le LOT 11
// (démos via gabarit + planner). Ne pas mettre en file son résultat tel quel.
//
// Génère, à partir des plans de démonstration d'un curriculum, des tâches exécutables
// par l'agent local sécurisé. Chaque démo devient un objectif (goal) que l'agent
// planifie et exécute — avec ses garde-fous (confirmation des actions d'entrée, etc.).
//
// NB : l'enregistrement d'écran SYNCHRONE pendant la démo (filmer en même temps qu'on
// agit) nécessitera un skill d'enregistrement en arrière-plan côté agent — c'est la
// prochaine évolution. Ici, on produit les objectifs et la narration associée.

export interface DemoTask {
  task_type: "goal";
  priority: number;
  payload: {
    title: string;
    goal: string;
    goal_meta: { goal: string; module: string; software: string; narration: string };
  };
}

interface DemoPlanItem {
  software?: string;
  goal?: string;
  narration?: string;
}

export function buildDemoTasks(curriculum: {
  title?: string;
  modules?: Record<string, unknown>[];
}): DemoTask[] {
  const tasks: DemoTask[] = [];
  const modules = Array.isArray(curriculum.modules) ? curriculum.modules : [];

  for (const m of modules) {
    const moduleTitle = String(m.title ?? "");
    const demos = Array.isArray(m.demo_plan) ? (m.demo_plan as DemoPlanItem[]) : [];
    for (const demo of demos) {
      const goal = (demo.goal ?? "").trim();
      if (!goal) continue;
      // On préfixe l'objectif par le logiciel à utiliser : le planificateur ouvrira
      // la bonne application avant d'agir.
      const software = (demo.software ?? "").trim();
      const objective = software ? `Dans ${software} : ${goal}` : goal;
      tasks.push({
        task_type: "goal",
        priority: 3,
        payload: {
          title: `Démo — ${moduleTitle}`,
          goal: objective,
          goal_meta: {
            goal: objective,
            module: moduleTitle,
            software,
            narration: (demo.narration ?? "").trim(),
          },
        },
      });
    }
  }
  return tasks;
}
