// Rôles versionnés des agents (LOT 11, audit §9.2–9.3, §11 `shared/roles`). Source unique côté
// plan de contrôle ; shared/roles/roles.json en est la copie publiée (test de non-dérive).
//
//  - executor « runtime » : la tâche est confiée à un runtime (PC) par bail ;
//  - executor « p1 »      : la tâche est exécutée par le plan de contrôle lui-même (relecture QA,
//                           rédaction de contenu via python-ia) — jamais attribuée à un runtime.
//  - tools : outils du catalogue (shared/tools/catalog.json) que le rôle peut planifier ;
//  - max_security_level : plafond du rôle (un nœud au-dessus est refusé par validateDag).
import type { SecurityLevel } from "../../lib/toolCatalog.js";

export interface RoleDef {
  name: string;
  version: string;
  description: string;
  executor: "runtime" | "p1";
  max_security_level: SecurityLevel;
  tools: readonly string[];
}

const DESKTOP = ["screenshot", "click", "double_click", "right_click", "move_mouse", "drag", "scroll", "type_text", "hotkey", "window", "open_app", "wait"];
const FILES_READ = ["read_file", "list_dir"];
const FILES_WRITE = ["write_file", "make_dir", "move_file"];
const VIDEO = ["record_screen", "start_recording_bg", "stop_recording_bg", "edit_video", "resolve_montage"];
const PHONE = ["phone_list_devices", "phone_screenshot", "phone_tap", "phone_swipe", "phone_type", "phone_key", "phone_open_app"];

export const ROLES: readonly RoleDef[] = [
  {
    name: "desktop_operator",
    version: "1.0.0",
    description: "Pilote le bureau Windows (souris, clavier, fenêtres, applications) ; observe avant d'agir.",
    executor: "runtime",
    max_security_level: "L2",
    tools: [...DESKTOP, ...FILES_READ, "record_screen", "start_recording_bg", "stop_recording_bg"],
  },
  {
    name: "coder",
    version: "1.0.0",
    description: "Lit, écrit et exécute du code dans le workspace (commandes en allowlist, sans shell).",
    executor: "runtime",
    max_security_level: "L2",
    tools: ["run_command", ...FILES_READ, ...FILES_WRITE, "wait"],
  },
  {
    name: "researcher",
    version: "1.0.0",
    description: "Lit le workspace pour collecter des faits ; aucun effet.",
    executor: "runtime",
    max_security_level: "L1",
    tools: [...FILES_READ, "wait", "screenshot"],
  },
  {
    name: "video_editor",
    version: "1.0.0",
    description: "Enregistre l'écran et monte les vidéos de démonstration.",
    executor: "runtime",
    max_security_level: "L2",
    tools: [...VIDEO, ...FILES_READ, ...FILES_WRITE, "wait"],
  },
  {
    name: "phone_operator",
    version: "1.0.0",
    description: "Pilote un téléphone Android connecté (adb).",
    executor: "runtime",
    max_security_level: "L2",
    tools: [...PHONE, "wait"],
  },
  {
    name: "qa_reviewer",
    version: "1.0.0",
    description: "Relit le travail d'une autre tâche à partir de ses preuves et de son évaluation (exécuté par P1).",
    executor: "p1",
    max_security_level: "L0",
    tools: [],
  },
  {
    name: "content_writer",
    version: "1.0.0",
    description: "Rédige du contenu (modules de formation, synthèses) via le routeur de modèles (exécuté par P1).",
    executor: "p1",
    max_security_level: "L0",
    tools: [],
  },
];

export const ROLE_BY_NAME: ReadonlyMap<string, RoleDef> = new Map(ROLES.map((r) => [r.name, r]));
/** Rôles exécutés par P1 lui-même (jamais attribués à un runtime). */
export const P1_ROLE_NAMES: readonly string[] = ROLES.filter((r) => r.executor === "p1").map((r) => r.name);

/** Forme publiée (shared/roles/roles.json). */
export function rolesDocument() {
  return { version: "1.0.0", generated_from: "backend/node-api/src/v2/planner/roles.ts", roles: ROLES };
}
