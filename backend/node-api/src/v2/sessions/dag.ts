// Validation de forme d'un plan (DAG) soumis à une session (LOT 7). Le `validateDag` complet
// (rôles connus, niveaux, chemins dans le workspace, critères, budget) est le LOT 11 ; ici :
// clés uniques, arêtes vers des nœuds existants, pas de cycle, bornes, niveaux et ressources
// bien formés. La base refuse de toute façon un cycle (trigger LOT 4).
import { isPlainObject, unknownKeys } from "../../lib/sanitize.js";
import type { SecurityLevel } from "../../lib/toolCatalog.js";
import { isSecurityLevel } from "../security/policy.js";

export const MAX_NODES = 200;
export const MAX_EDGES = 2000;
const NODE_KEY_RE = /^[a-z][a-z0-9_.-]{0,63}$/;
const ROLE_RE = /^[a-z][a-z0-9_]{0,63}$/;
const RESOURCE_RE = /^[a-z][a-z0-9_.-]*(:[^\s]+)*$/;

export interface PlanResource {
  key: string;
  mode: "exclusive" | "shared";
}

export interface PlanNode {
  key: string;
  title: string;
  role: string;
  security_level: SecurityLevel;
  spec: Record<string, unknown>;
  acceptance_criteria: unknown[];
  resources: PlanResource[];
  priority: number;
  max_retries: number;
  idempotency_key?: string;
}

export interface PlanEdge {
  from: string; // dépend de…
  to: string; // …pour exécuter
  kind: "hard" | "soft";
}

export interface Plan {
  nodes: PlanNode[];
  edges: PlanEdge[];
}

export type DagResult = { ok: true; value: Plan } | { ok: false; error: string };

function err(error: string): DagResult {
  return { ok: false, error };
}

/** Normalise et valide un plan brut `{ nodes: [...], edges?: [...] }`. */
export function validatePlan(raw: unknown): DagResult {
  if (!isPlainObject(raw)) return err("plan : objet attendu");
  const extra = unknownKeys(raw, ["nodes", "edges"]);
  if (extra.length) return err(`plan : champ(s) inconnu(s) : ${extra.join(", ").slice(0, 200)}`);
  if (!Array.isArray(raw.nodes) || raw.nodes.length === 0) return err("plan.nodes : liste non vide attendue");
  if (raw.nodes.length > MAX_NODES) return err(`plan.nodes : ${MAX_NODES} nœuds max`);
  const edgesRaw = raw.edges ?? [];
  if (!Array.isArray(edgesRaw)) return err("plan.edges : liste attendue");
  if (edgesRaw.length > MAX_EDGES) return err(`plan.edges : ${MAX_EDGES} arêtes max`);

  const nodes: PlanNode[] = [];
  const keys = new Set<string>();
  for (const [i, n] of raw.nodes.entries()) {
    const where = `plan.nodes[${i}]`;
    if (!isPlainObject(n)) return err(`${where} : objet attendu`);
    const unknown = unknownKeys(n, ["key", "title", "role", "security_level", "spec", "acceptance_criteria", "resources", "priority", "max_retries", "idempotency_key"]);
    if (unknown.length) return err(`${where} : champ(s) inconnu(s) : ${unknown.join(", ").slice(0, 200)}`);
    if (typeof n.key !== "string" || !NODE_KEY_RE.test(n.key)) return err(`${where}.key : identifiant attendu (a-z, 0-9, _ . -, 64 car. max)`);
    if (keys.has(n.key)) return err(`${where}.key : « ${n.key} » en double`);
    keys.add(n.key);
    if (typeof n.title !== "string" || !n.title.trim() || n.title.length > 500) return err(`${where}.title : texte (1–500 car.) attendu`);
    if (typeof n.role !== "string" || !ROLE_RE.test(n.role)) return err(`${where}.role : identifiant de rôle attendu`);
    const level = n.security_level ?? "L1";
    if (!isSecurityLevel(level)) return err(`${where}.security_level : L0 | L1 | L2 | L3 attendu`);
    const spec = n.spec ?? {};
    if (!isPlainObject(spec)) return err(`${where}.spec : objet attendu`);
    const criteria = n.acceptance_criteria ?? [];
    if (!Array.isArray(criteria)) return err(`${where}.acceptance_criteria : liste attendue`);
    const resourcesRaw = n.resources ?? [];
    if (!Array.isArray(resourcesRaw)) return err(`${where}.resources : liste attendue`);
    const resources: PlanResource[] = [];
    for (const r of resourcesRaw) {
      if (typeof r === "string") {
        if (!RESOURCE_RE.test(r)) return err(`${where}.resources : clé « ${String(r).slice(0, 60)} » invalide`);
        resources.push({ key: r, mode: "exclusive" });
        continue;
      }
      if (!isPlainObject(r) || typeof r.key !== "string" || !RESOURCE_RE.test(r.key)) return err(`${where}.resources : {key, mode} attendu`);
      const mode = r.mode ?? "exclusive";
      if (mode !== "exclusive" && mode !== "shared") return err(`${where}.resources : mode exclusive | shared attendu`);
      resources.push({ key: r.key, mode });
    }
    let priority = 5;
    if (n.priority !== undefined) {
      if (typeof n.priority !== "number" || !Number.isInteger(n.priority) || n.priority < 1 || n.priority > 10) return err(`${where}.priority : entier 1–10 attendu`);
      priority = n.priority;
    }
    let maxRetries = 2;
    if (n.max_retries !== undefined) {
      if (typeof n.max_retries !== "number" || !Number.isInteger(n.max_retries) || n.max_retries < 0 || n.max_retries > 10) return err(`${where}.max_retries : entier 0–10 attendu`);
      maxRetries = n.max_retries;
    }
    if (n.idempotency_key !== undefined && (typeof n.idempotency_key !== "string" || !n.idempotency_key || n.idempotency_key.length > 200)) {
      return err(`${where}.idempotency_key : texte (≤ 200 car.) attendu`);
    }
    nodes.push({
      key: n.key,
      title: n.title.trim(),
      role: n.role,
      security_level: level,
      spec,
      acceptance_criteria: criteria,
      resources,
      priority,
      max_retries: maxRetries,
      ...(typeof n.idempotency_key === "string" ? { idempotency_key: n.idempotency_key } : {}),
    });
  }

  const edges: PlanEdge[] = [];
  const seen = new Set<string>();
  for (const [i, e] of edgesRaw.entries()) {
    const where = `plan.edges[${i}]`;
    if (!isPlainObject(e)) return err(`${where} : objet attendu`);
    const unknown = unknownKeys(e, ["from", "to", "kind"]);
    if (unknown.length) return err(`${where} : champ(s) inconnu(s) : ${unknown.join(", ")}`);
    if (typeof e.from !== "string" || !keys.has(e.from)) return err(`${where}.from : nœud inconnu`);
    if (typeof e.to !== "string" || !keys.has(e.to)) return err(`${where}.to : nœud inconnu`);
    if (e.from === e.to) return err(`${where} : un nœud ne peut pas dépendre de lui-même`);
    const kind = e.kind ?? "hard";
    if (kind !== "hard" && kind !== "soft") return err(`${where}.kind : hard | soft attendu`);
    const sig = `${e.from}>${e.to}`;
    if (seen.has(sig)) return err(`${where} : arête en double`);
    seen.add(sig);
    edges.push({ from: e.from, to: e.to, kind });
  }

  const cycle = findCycle(nodes.map((n) => n.key), edges);
  if (cycle) return err(`plan : cycle de dépendances (${cycle.join(" → ")})`);
  return { ok: true, value: { nodes, edges } };
}

/** Premier cycle trouvé (liste de clés), ou null. Arête from → to : `to` dépend de `from`. */
export function findCycle(keys: readonly string[], edges: readonly PlanEdge[]): string[] | null {
  const next = new Map<string, string[]>();
  for (const k of keys) next.set(k, []);
  for (const e of edges) next.get(e.from)!.push(e.to);
  const state = new Map<string, 0 | 1 | 2>();
  const stack: string[] = [];
  const visit = (k: string): string[] | null => {
    state.set(k, 1);
    stack.push(k);
    for (const n of next.get(k) ?? []) {
      const s = state.get(n) ?? 0;
      if (s === 1) return [...stack.slice(stack.indexOf(n)), n];
      if (s === 0) {
        const found = visit(n);
        if (found) return found;
      }
    }
    stack.pop();
    state.set(k, 2);
    return null;
  };
  for (const k of keys) {
    if ((state.get(k) ?? 0) === 0) {
      const found = visit(k);
      if (found) return found;
    }
  }
  return null;
}

/** Ordre topologique (les nœuds sans dépendance d'abord) ; suppose un DAG validé. */
export function topologicalOrder(plan: Plan): string[] {
  const indeg = new Map<string, number>();
  const next = new Map<string, string[]>();
  for (const n of plan.nodes) {
    indeg.set(n.key, 0);
    next.set(n.key, []);
  }
  for (const e of plan.edges) {
    indeg.set(e.to, (indeg.get(e.to) ?? 0) + 1);
    next.get(e.from)!.push(e.to);
  }
  const queue = plan.nodes.filter((n) => indeg.get(n.key) === 0).map((n) => n.key);
  const out: string[] = [];
  while (queue.length) {
    const k = queue.shift()!;
    out.push(k);
    for (const n of next.get(k) ?? []) {
      indeg.set(n, indeg.get(n)! - 1);
      if (indeg.get(n) === 0) queue.push(n);
    }
  }
  return out;
}
