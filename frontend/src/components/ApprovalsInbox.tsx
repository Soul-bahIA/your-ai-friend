// Boîte de réception des approbations (LOT 6 — Sécurité et audit, S7/S22).
// Liste des demandes L0–L3 en attente (polling 5 s tant que l'onglet est visible), payload complet
// affiché sans masquage, décision liée à l'empreinte sha256 affichée, historique en lecture seule
// et encart « Journal d'audit » (vérification de la chaîne + dernières entrées).
import { useCallback, useEffect, useState } from "react";
import {
  ShieldAlert, ShieldCheck, ShieldX, Loader2, RefreshCw, Clock, Fingerprint, ScrollText, Link2, Inbox,
} from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { useToast } from "@/hooks/use-toast";
import { useApprovals } from "@/hooks/useApprovals";
import { errorMessage, isAbortError } from "@/lib/api";
import {
  APPROVALS_UNAVAILABLE_MESSAGE,
  L3_CONFIRM_WORD,
  TONE_CLASSES,
  approveApproval,
  auditEntryText,
  auditVerifyText,
  denyApproval,
  formatPayload,
  formatRemaining,
  historyOf,
  isApprovalsUnavailable,
  isStaleApproval,
  kindLabel,
  levelLabel,
  levelTone,
  listApprovals,
  listAudit,
  payloadHasLongValues,
  pendingActionable,
  remainingSeconds,
  requiresTypedConfirmation,
  shortSha,
  statusLabel,
  statusTone,
  summarizeApproval,
  verifyAuditChain,
  type Approval,
  type AuditEntry,
  type AuditVerifyResult,
} from "@/lib/approvals";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import ErrorState from "@/components/ErrorState";

const AUDIT_ENTRIES = 20;

const fmtDate = (iso: string | null) => (iso ? new Date(iso).toLocaleString("fr-FR") : "—");

/** Badge de niveau L0–L3 (couleur selon la gravité). */
const LevelBadge = ({ level }: { level: string }) => (
  <Badge variant="outline" className={`text-[10px] font-mono ${TONE_CLASSES[levelTone(level)]}`}>
    {level} · {levelLabel(level)}
  </Badge>
);

/** Payload complet (clés triées) ; les valeurs > 2000 caractères sont tronquées, avec un bouton pour tout voir. */
const PayloadView = ({ payload, id }: { payload: Record<string, unknown> | null; id: string }) => {
  const [showAll, setShowAll] = useState(false);
  const truncatable = payloadHasLongValues(payload);
  return (
    <div className="space-y-1">
      <p className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
        Contenu exact qui sera exécuté
      </p>
      <pre
        aria-label={`Contenu de la demande ${id}`}
        className="max-h-72 overflow-auto whitespace-pre-wrap break-all rounded bg-background/70 p-2 font-mono text-[11px] text-foreground"
      >
        {formatPayload(payload, showAll ? Infinity : undefined)}
      </pre>
      {truncatable && (
        <button
          type="button"
          onClick={() => setShowAll((v) => !v)}
          className="text-[11px] text-primary hover:underline"
        >
          {showAll ? "Replier les valeurs longues" : "Afficher tout, sans troncature"}
        </button>
      )}
    </div>
  );
};

interface DecisionDialogProps {
  approval: Approval | null;
  mode: "approve" | "deny" | null;
  busy: boolean;
  onClose: () => void;
  onApprove: (a: Approval) => void;
  onDeny: (a: Approval, reason: string) => void;
}

/** Confirmation L3 (saisie du mot AUTORISER) ou refus avec motif optionnel. */
const DecisionDialog = ({ approval, mode, busy, onClose, onApprove, onDeny }: DecisionDialogProps) => {
  const [word, setWord] = useState("");
  const [reason, setReason] = useState("");
  const open = !!approval && !!mode;

  useEffect(() => {
    if (!open) {
      setWord("");
      setReason("");
    }
  }, [open]);

  if (!approval || !mode) return null;
  const summary = summarizeApproval(approval);
  const canApprove = word.trim() === L3_CONFIRM_WORD;

  return (
    <Dialog open={open} onOpenChange={(o) => !o && !busy && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            {mode === "approve" ? (
              <><ShieldAlert className="h-5 w-5 text-destructive" /> Autoriser une action irréversible ?</>
            ) : (
              <><ShieldX className="h-5 w-5 text-muted-foreground" /> Refuser cette demande ?</>
            )}
          </DialogTitle>
          <DialogDescription className="break-words">{summary}</DialogDescription>
        </DialogHeader>

        {mode === "approve" ? (
          <div className="space-y-2">
            <p className="text-xs text-muted-foreground">
              Niveau <span className="font-mono font-semibold text-destructive">L3</span> : cette action ne
              pourra pas être annulée. Relisez le contenu affiché, puis tapez{" "}
              <span className="font-mono font-semibold text-foreground">{L3_CONFIRM_WORD}</span> pour confirmer.
            </p>
            <Label htmlFor={`confirm-${approval.id}`} className="text-xs">
              Mot de confirmation
            </Label>
            <Input
              id={`confirm-${approval.id}`}
              value={word}
              onChange={(e) => setWord(e.target.value)}
              placeholder={L3_CONFIRM_WORD}
              autoComplete="off"
              className="font-mono"
            />
          </div>
        ) : (
          <div className="space-y-2">
            <Label htmlFor={`reason-${approval.id}`} className="text-xs">
              Motif (optionnel, consigné dans le journal)
            </Label>
            <Textarea
              id={`reason-${approval.id}`}
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="Ex. : mauvais fichier ciblé"
              rows={3}
            />
          </div>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>
            Annuler
          </Button>
          {mode === "approve" ? (
            <Button variant="destructive" disabled={!canApprove || busy} onClick={() => onApprove(approval)}>
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : "Autoriser"}
            </Button>
          ) : (
            <Button variant="secondary" disabled={busy} onClick={() => onDeny(approval, reason)}>
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : "Refuser"}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

interface ApprovalCardProps {
  approval: Approval;
  now: number;
  busy: boolean;
  onApprove: (a: Approval) => void;
  onDeny: (a: Approval) => void;
}

/** Carte d'une demande en attente : niveau, outil, résumé, compte à rebours, payload, empreinte, décision. */
const ApprovalCard = ({ approval, now, busy, onApprove, onDeny }: ApprovalCardProps) => {
  const remaining = remainingSeconds(approval, now);
  const urgent = remaining !== null && remaining <= 60;
  const tone = levelTone(approval.security_level);
  const border = tone === "destructive" ? "border-destructive/40" : tone === "warning" ? "border-warning/40" : "border-border";

  return (
    <article className={`rounded-lg border ${border} bg-card p-4 space-y-3`} aria-label={`Demande ${approval.id}`}>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0 space-y-1">
          <div className="flex flex-wrap items-center gap-1.5">
            <LevelBadge level={approval.security_level} />
            <Badge variant="outline" className="text-[10px]">{kindLabel(approval.kind)}</Badge>
            {approval.tool && (
              <span className="font-mono text-xs font-semibold text-foreground">{approval.tool}</span>
            )}
          </div>
          <p className="text-sm text-foreground break-words">{approval.summary || summarizeApproval(approval)}</p>
          <p className="text-[10px] text-muted-foreground font-mono">
            {approval.task_id ? `tâche ${approval.task_id.slice(0, 8)}` : "hors tâche"}
            {approval.step_index !== null ? ` · étape ${approval.step_index + 1}` : ""}
            {approval.attempt !== null ? ` · tentative ${approval.attempt}` : ""}
            {` · demandée ${fmtDate(approval.created_at)}`}
          </p>
        </div>
        <div
          className={`flex items-center gap-1 text-xs font-mono ${urgent ? "text-destructive" : "text-muted-foreground"}`}
          role="timer"
          aria-live="off"
          title={approval.expires_at ? `Expire le ${fmtDate(approval.expires_at)}` : "Sans échéance"}
        >
          <Clock className="h-3.5 w-3.5" aria-hidden="true" />
          {formatRemaining(remaining)}
        </div>
      </div>

      <PayloadView payload={approval.payload_presented} id={approval.id} />

      <div className="flex flex-wrap items-center justify-between gap-2">
        <span
          className="flex items-center gap-1 text-[10px] font-mono text-muted-foreground"
          title={approval.payload_sha256 ?? "Empreinte absente"}
        >
          <Fingerprint className="h-3 w-3" aria-hidden="true" />
          sha256 {shortSha(approval.payload_sha256)}
        </span>
        <div className="flex gap-2">
          <Button size="sm" variant="outline" disabled={busy} onClick={() => onDeny(approval)}>
            <ShieldX className="h-4 w-4 mr-1" /> Refuser
          </Button>
          <Button
            size="sm"
            variant={tone === "destructive" ? "destructive" : "default"}
            disabled={busy || !approval.payload_sha256}
            title={approval.payload_sha256 ? undefined : "Empreinte absente : approbation impossible"}
            onClick={() => onApprove(approval)}
          >
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <><ShieldCheck className="h-4 w-4 mr-1" /> Approuver</>}
          </Button>
        </div>
      </div>
    </article>
  );
};

/** Historique en lecture seule (approuvées / refusées / expirées / révoquées). */
const HistoryList = ({ reloadKey, enabled }: { reloadKey: number; enabled: boolean }) => {
  const [rows, setRows] = useState<Approval[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!enabled) return;
    const controller = new AbortController();
    setLoading(true);
    listApprovals("all", controller.signal, 50)
      .then((all) => {
        setRows(historyOf(all));
        setError(null);
      })
      .catch((e) => {
        if (isAbortError(e)) return;
        setError(isApprovalsUnavailable(e) ? APPROVALS_UNAVAILABLE_MESSAGE : errorMessage(e));
      })
      .finally(() => setLoading(false));
    return () => controller.abort();
  }, [reloadKey, enabled]);

  if (loading) return <p className="text-xs text-muted-foreground">Chargement de l'historique...</p>;
  if (error) return <ErrorState compact message="Historique indisponible." detail={error} />;
  if (rows.length === 0) return <p className="text-xs text-muted-foreground">Aucune décision enregistrée.</p>;

  return (
    <ul className="space-y-2">
      {rows.map((a) => (
        <li key={a.id} className="rounded-md border border-border p-2.5 space-y-1">
          <div className="flex flex-wrap items-center gap-1.5">
            <Badge variant="outline" className={`text-[10px] ${TONE_CLASSES[statusTone(a.status)]}`}>
              {statusLabel(a.status)}
            </Badge>
            <LevelBadge level={a.security_level} />
            <span className="text-xs text-foreground break-words">{summarizeApproval(a)}</span>
          </div>
          <p className="text-[10px] text-muted-foreground font-mono">
            demandée {fmtDate(a.created_at)}
            {a.decided_at ? ` · décidée ${fmtDate(a.decided_at)}` : ""}
            {a.reason ? ` · motif : ${a.reason}` : ""}
            {` · sha256 ${shortSha(a.payload_sha256)}`}
          </p>
        </li>
      ))}
    </ul>
  );
};

/** Encart « Journal d'audit » : vérification de la chaîne et dernières entrées. */
const AuditPanel = () => {
  const [verifying, setVerifying] = useState(false);
  const [result, setResult] = useState<AuditVerifyResult | null>(null);
  const [entries, setEntries] = useState<AuditEntry[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const verify = async () => {
    setVerifying(true);
    setError(null);
    try {
      const [res, rows] = await Promise.all([verifyAuditChain(), listAudit(AUDIT_ENTRIES)]);
      setResult(res);
      setEntries(rows.slice(0, AUDIT_ENTRIES));
    } catch (e) {
      setError(isApprovalsUnavailable(e) ? "Journal d'audit indisponible sur ce serveur (API V2 absente)." : errorMessage(e));
    } finally {
      setVerifying(false);
    }
  };

  return (
    <section className="rounded-lg border border-border bg-card/60 p-4 space-y-3" aria-labelledby="audit-title">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 id="audit-title" className="flex items-center gap-2 text-sm font-semibold">
          <ScrollText className="h-4 w-4 text-primary" /> Journal d'audit
        </h3>
        <Button size="sm" variant="outline" onClick={verify} disabled={verifying}>
          {verifying ? <Loader2 className="h-4 w-4 animate-spin" /> : <><Link2 className="h-4 w-4 mr-1" /> Vérifier la chaîne</>}
        </Button>
      </div>
      <p className="text-xs text-muted-foreground">
        Chaque entrée est chaînée par empreinte à la précédente : une altération rompt la chaîne.
      </p>
      {error && <ErrorState compact message="Vérification impossible." detail={error} />}
      {result && (
        <p
          role="status"
          className={`text-xs font-medium ${result.ok ? "text-success" : "text-destructive"}`}
        >
          {auditVerifyText(result)}
        </p>
      )}
      {entries && (
        entries.length === 0 ? (
          <p className="text-xs text-muted-foreground">Journal vide.</p>
        ) : (
          <ol className="max-h-64 overflow-auto divide-y divide-border rounded-md border border-border text-[11px]">
            {entries.map((e) => (
              <li key={e.seq} className="flex flex-wrap items-baseline gap-x-2 px-2 py-1.5">
                <span className="font-mono text-muted-foreground w-10 shrink-0">#{e.seq}</span>
                <span className="font-medium text-foreground">{auditEntryText(e)}</span>
                <span className="text-muted-foreground">par {e.actor}</span>
                <span className="ml-auto font-mono text-muted-foreground">{fmtDate(e.created_at)}</span>
              </li>
            ))}
          </ol>
        )
      )}
    </section>
  );
};

interface ApprovalsInboxProps {
  /** Intervalle de polling des demandes en attente (ms). */
  pollMs?: number;
}

const ApprovalsInbox = ({ pollMs = 5000 }: ApprovalsInboxProps) => {
  const { user } = useAuth();
  const enabled = !!user;
  const { toast } = useToast();
  const { approvals, loading, error, unavailable, refresh } = useApprovals("pending", {
    intervalMs: pollMs,
    enabled,
  });
  const [now, setNow] = useState(() => Date.now());
  const [busyId, setBusyId] = useState<string | null>(null);
  const [dialog, setDialog] = useState<{ approval: Approval; mode: "approve" | "deny" } | null>(null);
  const [historyKey, setHistoryKey] = useState(0);
  const [tab, setTab] = useState("pending");

  const pending = pendingActionable(approvals, now);

  // Compte à rebours : une seconde, uniquement s'il y a une échéance à suivre.
  const hasDeadline = pending.some((a) => a.expires_at);
  useEffect(() => {
    if (!hasDeadline) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [hasDeadline]);

  const afterDecision = useCallback(() => {
    setBusyId(null);
    setDialog(null);
    refresh();
    setHistoryKey((k) => k + 1);
  }, [refresh]);

  const doApprove = async (a: Approval) => {
    setBusyId(a.id);
    try {
      // L'empreinte renvoyée est celle du contenu AFFICHÉ : le serveur refuse (409) si elle diffère.
      await approveApproval(a.id, a.payload_sha256 ?? "");
      toast({ title: "Action approuvée", description: summarizeApproval(a) });
    } catch (e) {
      toast({
        title: isStaleApproval(e) ? "Demande modifiée ou plus en attente" : "Approbation impossible",
        description: errorMessage(e),
        variant: "destructive",
      });
    } finally {
      afterDecision();
    }
  };

  const doDeny = async (a: Approval, reason: string) => {
    setBusyId(a.id);
    try {
      await denyApproval(a.id, reason);
      toast({ title: "Action refusée", description: summarizeApproval(a) });
    } catch (e) {
      toast({
        title: isStaleApproval(e) ? "Demande modifiée ou plus en attente" : "Refus impossible",
        description: errorMessage(e),
        variant: "destructive",
      });
    } finally {
      afterDecision();
    }
  };

  const onApproveClick = (a: Approval) => {
    if (requiresTypedConfirmation(a.security_level)) setDialog({ approval: a, mode: "approve" });
    else void doApprove(a);
  };

  if (unavailable) {
    return (
      <div className="rounded-md border border-border bg-secondary/40 p-3 text-xs text-muted-foreground" role="status">
        {APPROVALS_UNAVAILABLE_MESSAGE}
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <Tabs value={tab} onValueChange={setTab}>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <TabsList>
            <TabsTrigger value="pending">
              En attente
              {pending.length > 0 && (
                <span className="ml-1.5 rounded-full bg-warning/20 px-1.5 text-[10px] font-semibold text-warning">
                  {pending.length}
                </span>
              )}
            </TabsTrigger>
            <TabsTrigger value="history">Historique</TabsTrigger>
          </TabsList>
          <Button
            size="sm"
            variant="ghost"
            onClick={() => {
              refresh();
              setHistoryKey((k) => k + 1);
            }}
            aria-label="Actualiser les approbations"
          >
            <RefreshCw className="h-4 w-4" />
          </Button>
        </div>

        <TabsContent value="pending" className="space-y-3">
          {loading ? (
            <p className="text-xs text-muted-foreground">Chargement des demandes...</p>
          ) : error && approvals.length === 0 ? (
            <ErrorState compact message="Impossible de lire les approbations." detail={error} onRetry={refresh} />
          ) : pending.length === 0 ? (
            <div className="flex items-center gap-2 rounded-md border border-dashed border-border p-3 text-xs text-muted-foreground">
              <Inbox className="h-4 w-4" aria-hidden="true" />
              Aucune demande en attente. Les actions L2/L3 de l'agent apparaîtront ici avant exécution.
            </div>
          ) : (
            <>
              {error && (
                <p className="text-[11px] text-warning" role="status">
                  Dernière actualisation en échec : {error}
                </p>
              )}
              {pending.map((a) => (
                <ApprovalCard
                  key={a.id}
                  approval={a}
                  now={now}
                  busy={busyId === a.id}
                  onApprove={onApproveClick}
                  onDeny={(x) => setDialog({ approval: x, mode: "deny" })}
                />
              ))}
            </>
          )}
        </TabsContent>

        <TabsContent value="history">
          <HistoryList reloadKey={historyKey} enabled={enabled} />
        </TabsContent>
      </Tabs>

      <AuditPanel />

      <DecisionDialog
        approval={dialog?.approval ?? null}
        mode={dialog?.mode ?? null}
        busy={!!dialog && busyId === dialog.approval.id}
        onClose={() => setDialog(null)}
        onApprove={(a) => void doApprove(a)}
        onDeny={(a, reason) => void doDeny(a, reason)}
      />
    </div>
  );
};

export default ApprovalsInbox;
