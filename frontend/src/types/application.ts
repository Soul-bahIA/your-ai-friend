/** Architecture (résumé) d'une application générée. */
export interface ArchitectureSummary {
  frontend?: { components?: unknown[]; [key: string]: unknown };
  backend?: { endpoints?: unknown[]; [key: string]: unknown };
  database?: { tables?: unknown[]; [key: string]: unknown };
  [key: string]: unknown;
}

/** Application renvoyée par POST /api/generate/application. */
export interface GeneratedApplication {
  title?: string;
  description?: string | null;
  app_type?: string | null;
  tech_stack?: string | null;
  architecture?: ArchitectureSummary;
}

export interface GenerateApplicationResponse {
  success?: boolean;
  error?: string;
  application?: GeneratedApplication;
}
