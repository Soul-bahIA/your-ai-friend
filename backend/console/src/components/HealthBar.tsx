import { useEffect, useState } from "react";
import { deepHealth, type HealthResponse } from "../api/client";

export function HealthBar() {
  const [health, setHealth] = useState<HealthResponse | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let active = true;

    const check = async () => {
      try {
        const h = await deepHealth();
        if (active) {
          setHealth(h);
          setFailed(false);
        }
      } catch {
        if (active) setFailed(true);
      }
    };

    check();
    const id = setInterval(check, 10_000);
    return () => {
      active = false;
      clearInterval(id);
    };
  }, []);

  if (failed) {
    return (
      <div className="health health--down">
        <span className="dot dot--down" /> API injoignable — le backend est-il démarré ?
      </div>
    );
  }

  if (!health) {
    return (
      <div className="health">
        <span className="dot dot--warn" /> Vérification des services…
      </div>
    );
  }

  const entries = Object.entries(health.checks ?? {});

  return (
    <div className="health">
      <span className={`dot dot--${health.status === "ok" ? "ok" : "warn"}`} />
      <span>API {health.status}</span>
      {entries.map(([name, state]) => (
        <span key={name} className="chip">
          <span className={`dot dot--${state === "ok" ? "ok" : "down"}`} />
          {name}
        </span>
      ))}
    </div>
  );
}
