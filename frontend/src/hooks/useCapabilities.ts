// V3 LOT 1 — lecture périodique du mode et des capacités ; arrêt définitif sur 404.
import { useEffect, useRef, useState } from "react";
import { errorMessage, isAbortError } from "@/lib/api";
import { fetchCapabilities, isCapabilitiesUnavailable, type CapabilitiesReport } from "@/lib/capabilities";

export interface UseCapabilitiesState {
  report: CapabilitiesReport | null;
  error: string | null;
  unavailable: boolean;
}

export function useCapabilities(enabled: boolean, intervalMs = 60_000): UseCapabilitiesState {
  const [report, setReport] = useState<CapabilitiesReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [unavailable, setUnavailable] = useState(false);
  const stopped = useRef(false);

  useEffect(() => {
    if (!enabled || stopped.current) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let controller: AbortController | null = null;
    const run = async () => {
      controller = new AbortController();
      try {
        const r = await fetchCapabilities(controller.signal);
        if (cancelled) return;
        setReport(r);
        setError(null);
      } catch (err) {
        if (cancelled || isAbortError(err)) return;
        if (isCapabilitiesUnavailable(err)) {
          stopped.current = true;
          setUnavailable(true);
          return;
        }
        setError(errorMessage(err));
      }
      if (!cancelled && intervalMs > 0) timer = setTimeout(run, intervalMs);
    };
    void run();
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
      controller?.abort();
    };
  }, [enabled, intervalMs]);

  return { report, error, unavailable };
}
