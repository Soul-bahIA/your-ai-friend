import { useEffect, useState } from "react";
import { deepHealth, type HealthProbe } from "../api/client";
import { onSessionChange } from "../api/auth";
import { healthView } from "../api/health";

export function HealthBar() {
  const [probe, setProbe] = useState<HealthProbe | null>(null);

  useEffect(() => {
    let active = true;

    const check = async () => {
      const result = await deepHealth();
      if (active) setProbe(result);
    };

    check();
    const id = setInterval(check, 10_000);
    // Hors dev, /health/deep exige un JWT : on revérifie dès la connexion / déconnexion.
    const unsubscribe = onSessionChange(() => {
      check();
    });
    return () => {
      active = false;
      clearInterval(id);
      unsubscribe();
    };
  }, []);

  const view = healthView(probe, window.location.origin);

  return (
    <div className={`health${view.tone === "down" ? " health--down" : ""}`} role="status" aria-live="polite">
      <span className={`dot dot--${view.tone}`} />
      <span>{view.message}</span>
      {view.checks.map(([name, tone]) => (
        <span key={name} className="chip">
          <span className={`dot dot--${tone}`} />
          {name}
        </span>
      ))}
    </div>
  );
}
