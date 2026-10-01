// V3 LOT 1 — indicateur permanent du mode (mission V3 §59) et des capacités indisponibles.
import { useAuth } from "@/hooks/useAuth";
import { useCapabilities } from "@/hooks/useCapabilities";
import { limitations, modeView } from "@/lib/capabilities";

const ModeBadge = ({ compact = false }: { compact?: boolean }) => {
  const { user } = useAuth();
  const { report, error, unavailable } = useCapabilities(!!user);
  if (unavailable || !user) return null;
  if (!report) {
    return error ? (
      <span className="text-[10px] font-mono text-muted-foreground" role="status">
        Mode : indisponible
      </span>
    ) : null;
  }
  const view = modeView(report.settings.mode);
  const limits = limitations(report);
  const title = [view.description, `Agents : ${report.settings.effective_max_agents} (profil ${report.settings.resource_profile})`, ...(limits.length ? ["Indisponible :", ...limits] : [])].join("\n");
  return (
    <span
      role="status"
      aria-label={`Mode ${view.label}`}
      title={title}
      data-testid="mode-badge"
      className={`inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-[10px] font-mono font-semibold ${view.tone}`}
    >
      <span aria-hidden="true">{view.icon}</span>
      {compact ? report.settings.mode : view.label}
      {limits.length > 0 && !compact ? <span className="text-muted-foreground font-normal">· {limits.length} limite(s)</span> : null}
    </span>
  );
};

export default ModeBadge;
