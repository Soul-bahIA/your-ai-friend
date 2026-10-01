// Juge par défaut des critères llm_rubric (LOT 10) : python-ia /v2/models/complete, rôle
// évaluateur. Le contexte transmis est borné et déjà rédigé (preuves stockées sans secret ni
// base64) ; la confiance d'un tel jugement est « low » (criteria.ts).
import { judgeRubric } from "../../clients/iaClient.js";
import type { RubricInput } from "./engine.js";

export const MAX_CONTEXT_CHARS = 30_000;

/** Résumé textuel des preuves d'une tentative pour le juge. */
export function rubricContext(input: RubricInput): string {
  const lines: string[] = [`Tâche « ${input.task.title} » (rôle ${input.task.role}, niveau ${input.task.security_level})`];
  for (const a of input.actions) {
    lines.push(`- étape ${a.step_index} · ${a.tool} · ${a.status}`);
    for (const e of a.evidence) {
      const value = e.value === undefined ? "" : ` = ${typeof e.value === "string" ? e.value : JSON.stringify(e.value)}`;
      lines.push(`    · ${e.kind} (${e.confidence})${e.description ? ` ${e.description}` : ""}${value.slice(0, 600)}${e.sha256 ? ` sha256=${e.sha256.slice(0, 16)}…` : ""}`);
    }
  }
  if (input.result) lines.push(`Résultat déclaré : ${JSON.stringify(input.result).slice(0, 2000)}`);
  const text = lines.join("\n");
  return text.length > MAX_CONTEXT_CHARS ? `${text.slice(0, MAX_CONTEXT_CHARS)}\n… [tronqué]` : text;
}

export async function defaultRubricJudge(input: RubricInput): Promise<{ passed: boolean; reason: string }> {
  return judgeRubric({ rubric: input.rubric, context: rubricContext(input) });
}
