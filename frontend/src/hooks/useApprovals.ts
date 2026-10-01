// Polling des approbations V2 : tant que l'onglet est visible, à intervalle régulier ;
// arrêt définitif sur 404 (serveur V1 sans routes V2) ; annulation propre au démontage.
import { useCallback, useEffect, useRef, useState } from "react";
import { errorMessage, isAbortError } from "@/lib/api";
import {
  isApprovalsUnavailable,
  listApprovals,
  type Approval,
  type ApprovalFilter,
} from "@/lib/approvals";

export interface UseApprovalsOptions {
  /** Intervalle de rafraîchissement en ms (0 = une seule lecture). */
  intervalMs?: number;
  /** Faux tant que l'utilisateur n'est pas connecté : aucun appel. */
  enabled?: boolean;
  /** Nombre maximal de lignes demandées. */
  limit?: number;
}

export interface UseApprovalsState {
  approvals: Approval[];
  /** Première lecture en cours. */
  loading: boolean;
  /** Dernière erreur (hors 404), ou null. */
  error: string | null;
  /** Routes V2 absentes (404) : le polling est arrêté. */
  unavailable: boolean;
  /** Date (ms) de la dernière lecture réussie, ou null. */
  updatedAt: number | null;
  /** Relecture immédiate. */
  refresh: () => void;
}

const isVisible = () => typeof document === "undefined" || document.visibilityState !== "hidden";

export function useApprovals(status: ApprovalFilter, options: UseApprovalsOptions = {}): UseApprovalsState {
  const { intervalMs = 5000, enabled = true, limit = 50 } = options;
  const [approvals, setApprovals] = useState<Approval[]>([]);
  const [loading, setLoading] = useState(enabled);
  const [error, setError] = useState<string | null>(null);
  const [unavailable, setUnavailable] = useState(false);
  const [updatedAt, setUpdatedAt] = useState<number | null>(null);
  const [tick, setTick] = useState(0);
  const unavailableRef = useRef(false);

  const refresh = useCallback(() => {
    if (unavailableRef.current) return;
    setTick((t) => t + 1);
  }, []);

  useEffect(() => {
    if (!enabled) {
      setLoading(false);
      return;
    }
    if (unavailableRef.current) return;

    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let controller: AbortController | null = null;

    const schedule = () => {
      if (cancelled || intervalMs <= 0 || unavailableRef.current) return;
      timer = setTimeout(run, intervalMs);
    };

    const run = async () => {
      timer = null;
      if (cancelled) return;
      if (!isVisible()) {
        // Onglet masqué : on ne sollicite pas le serveur, on reprendra au retour.
        schedule();
        return;
      }
      controller = new AbortController();
      try {
        const rows = await listApprovals(status, controller.signal, limit);
        if (cancelled) return;
        setApprovals(rows);
        setError(null);
        setUpdatedAt(Date.now());
      } catch (err) {
        if (cancelled || isAbortError(err)) return;
        if (isApprovalsUnavailable(err)) {
          unavailableRef.current = true;
          setUnavailable(true);
          setApprovals([]);
          setError(null);
          setLoading(false);
          return; // arrêt définitif : pas de nouvelle planification
        }
        setError(errorMessage(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
      schedule();
    };

    const onVisible = () => {
      if (isVisible() && !cancelled && timer) {
        // Retour sur l'onglet : relecture immédiate plutôt qu'à la prochaine échéance.
        clearTimeout(timer);
        timer = null;
        void run();
      }
    };
    document.addEventListener("visibilitychange", onVisible);
    void run();

    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
      controller?.abort();
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [status, intervalMs, enabled, limit, tick]);

  return { approvals, loading, error, unavailable, updatedAt, refresh };
}
