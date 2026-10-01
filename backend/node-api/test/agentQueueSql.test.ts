// Ciblage d'un PC (contrat §7 / T16), poll, annulation (§2), approbation (§6), reaper (T19).
import { describe, expect, it } from "vitest";
import {
  NOT_AWAITING_APPROVAL,
  buildAgentTaskUpdate,
  buildApprove,
  buildCancel,
  buildGoalCancel,
  buildPollQuery,
  buildReaperQueries,
  buildTaskTouch,
} from "../src/lib/agentTaskSql";

const T = "11111111-1111-4111-8111-111111111111";
const U = "22222222-2222-4222-8222-222222222222";
const K = "33333333-3333-4333-8333-333333333333";

describe("claim / transitions avec clé agent", () => {
  it("claim : écrit claimed_by_key_id, respecte la cible et exclut les corrections non approuvées", () => {
    const q = buildAgentTaskUpdate({ taskId: T, userId: U, status: "in_progress", attempt: 1, keyId: K });
    expect(q.kind).toBe("claim");
    expect(q.sql).toContain("claimed_by_key_id = $2::uuid");
    expect(q.sql).toContain("status = 'pending'");
    expect(q.sql).toContain("requeue_count = $5");
    expect(q.sql).toContain("(target_agent_key_id IS NULL OR target_agent_key_id = $2::uuid)");
    expect(q.sql).toContain(NOT_AWAITING_APPROVAL);
    expect(q.values).toEqual(["in_progress", K, T, U, 1]);
  });

  it("final 'cancelled' : terminal, garde attempt + réclamée par cette clé", () => {
    const q = buildAgentTaskUpdate({ taskId: T, userId: U, status: "cancelled", attempt: 0, keyId: K });
    expect(q.kind).toBe("transition");
    expect(q.sql).toContain("completed_at = now()");
    expect(q.sql).toContain("status = 'in_progress' AND requeue_count = $5");
    expect(q.sql).toContain("(claimed_by_key_id IS NULL OR claimed_by_key_id = $2::uuid)");
    expect(q.sql).not.toContain("claimed_by_key_id = $2::uuid,");
  });

  it("heartbeat/évènement : garde attempt puis clé", () => {
    const q = buildTaskTouch(T, U, 2, K);
    expect(q.sql).toContain("requeue_count = $3");
    expect(q.sql).toContain("claimed_by_key_id = $4::uuid");
    expect(q.values).toEqual([T, U, 2, K]);
  });
});

describe("poll", () => {
  it("ne sert que les tâches pending ciblant la clé appelante (ou aucune), hors awaiting_approval", () => {
    const q = buildPollQuery(U, K);
    expect(q.sql).toMatch(/status = 'pending'/);
    expect(q.sql).toContain("(target_agent_key_id IS NULL OR target_agent_key_id = $2::uuid)");
    expect(q.sql).toContain(`(payload #> '{goal_meta,awaiting_approval}') IS DISTINCT FROM 'true'::jsonb`);
    expect(q.sql).toMatch(/ORDER BY priority ASC, created_at ASC LIMIT 5/);
    expect(q.values).toEqual([U, K]);
  });
});

describe("annulation et approbation", () => {
  it("cancel : pending → cancelled, in_progress → control stop, en une requête atomique", () => {
    const q = buildCancel(T, U);
    expect(q.sql).toContain("WHEN status = 'pending' THEN 'cancelled'");
    expect(q.sql).toContain("WHEN status = 'in_progress' THEN 'stop'");
    expect(q.sql).toContain("status IN ('pending', 'in_progress')");
    expect(q.values).toEqual([T, U]);
  });

  it("approve : uniquement une tâche pending en attente d'approbation", () => {
    const q = buildApprove(T, U);
    expect(q.sql).toContain("'{goal_meta,awaiting_approval}', 'false'::jsonb");
    expect(q.sql).toContain("status = 'pending'");
    expect(q.sql).toContain("= 'true'::jsonb");
  });
});

describe("reaper global (T19)", () => {
  it("stop demandé + agent muet → cancelled (jamais ré-exécutée) ; sinon requeue puis abandon", () => {
    const q = buildReaperQueries(180, 3);
    expect(q.cancelStopped.sql).toContain("SET status = 'cancelled'");
    expect(q.cancelStopped.sql).toContain("control = 'stop'");
    expect(q.cancelStopped.sql).not.toContain("user_id = $");
    expect(q.requeue.sql).toContain("claimed_by_key_id = NULL");
    expect(q.requeue.sql).toContain("requeue_count < $2");
    expect(q.abandon.sql).toContain("requeue_count >= $2");
    expect(q.requeue.values).toEqual([180, 3, []]);
  });

  it("requeue : control remis à none, pause conservée ou imposée si une étape à effet réel a déjà été lancée ; jamais un stop", () => {
    const q = buildReaperQueries(180, 3, ["run_command", "write_file"]);
    expect(q.requeue.values).toEqual([180, 3, ["run_command", "write_file"]]);
    expect(q.requeue.sql).toMatch(/control = CASE WHEN t\.control = 'pause' OR EXISTS \(/);
    expect(q.requeue.sql).toContain("THEN 'pause' ELSE 'none' END");
    expect(q.requeue.sql).toContain("e.type IN ('step_started', 'step_done', 'step_failed')");
    expect(q.requeue.sql).toContain("= ANY($3::text[])");
    // index non entier : jamais de cast en erreur (CASE garde l'ordre d'évaluation)
    expect(q.requeue.sql).toContain("CASE WHEN (e.data ->> 'index') ~ '^[0-9]{1,4}$'");
    expect(q.requeue.sql).toContain("control IS DISTINCT FROM 'stop'");
    expect(q.requeue.sql).toMatch(/RETURNING t\.id, t\.user_id, t\.requeue_count, t\.control,\s+EXISTS/);
    expect(q.abandon.sql).toContain("control IS DISTINCT FROM 'stop'");
  });
});

describe("annulation d'un objectif entier (T18)", () => {
  it("toutes les tâches actives de même root_task_id (et la racine), pour l'utilisateur seulement", () => {
    const q = buildGoalCancel(T, U);
    expect(q.sql).toContain("WHEN status = 'pending' THEN 'cancelled'");
    expect(q.sql).toContain("WHEN status = 'in_progress' THEN 'stop'");
    expect(q.sql).toContain("user_id = $2 AND status IN ('pending', 'in_progress')");
    expect(q.sql).toContain("(id = $1::uuid OR (payload #>> '{goal_meta,root_task_id}') = $3::text)");
    expect(q.values).toEqual([T, U, T]);
  });
});
