// Recherche web — couche d'abstraction multi-fournisseurs (Tavily / Serper / Brave).
// Activée par WEB_SEARCH_PROVIDER + clé correspondante. Sans clé : `available=false`
// et le moteur de recherche se rabat sur la KB + la synthèse du modèle.

import { logger } from "../../lib/logger.js";

const WEB_SEARCH_TIMEOUT_MS = 15_000;

/**
 * Exécute la recherche d'un fournisseur en isolant ses pannes : erreur réseau,
 * délai dépassé (15 s) ou JSON invalide → [] (journalisé), jamais d'exception.
 */
async function safeSearch(id: string, run: (signal: AbortSignal) => Promise<WebResult[]>): Promise<WebResult[]> {
  try {
    return await run(AbortSignal.timeout(WEB_SEARCH_TIMEOUT_MS));
  } catch (e) {
    logger.warn({ provider: id, err: (e as Error).message }, "recherche web échouée");
    return [];
  }
}

export interface WebResult {
  title: string;
  url: string;
  snippet: string;
}

export interface WebSearchProvider {
  id: string;
  available: boolean;
  search(query: string, limit: number): Promise<WebResult[]>;
}

class NullProvider implements WebSearchProvider {
  id = "none";
  available = false;
  async search(): Promise<WebResult[]> {
    return [];
  }
}

class TavilyProvider implements WebSearchProvider {
  id = "tavily";
  available = true;
  constructor(private apiKey: string) {}
  async search(query: string, limit: number): Promise<WebResult[]> {
    return safeSearch(this.id, async (signal) => {
    const res = await fetch("https://api.tavily.com/search", {
      signal,
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        api_key: this.apiKey,
        query,
        max_results: limit,
        search_depth: "advanced",
      }),
    });
    if (!res.ok) {
      logger.warn({ provider: this.id, status: res.status }, "recherche web : réponse en erreur");
      return [];
    }
    const data = (await res.json()) as { results?: { title?: string; url?: string; content?: string }[] };
    return (data.results ?? []).map((r) => ({
      title: r.title ?? "",
      url: r.url ?? "",
      snippet: r.content ?? "",
    }));
    });
  }
}

class SerperProvider implements WebSearchProvider {
  id = "serper";
  available = true;
  constructor(private apiKey: string) {}
  async search(query: string, limit: number): Promise<WebResult[]> {
    return safeSearch(this.id, async (signal) => {
    const res = await fetch("https://google.serper.dev/search", {
      signal,
      method: "POST",
      headers: { "X-API-KEY": this.apiKey, "Content-Type": "application/json" },
      body: JSON.stringify({ q: query, num: limit }),
    });
    if (!res.ok) {
      logger.warn({ provider: this.id, status: res.status }, "recherche web : réponse en erreur");
      return [];
    }
    const data = (await res.json()) as { organic?: { title?: string; link?: string; snippet?: string }[] };
    return (data.organic ?? []).slice(0, limit).map((r) => ({
      title: r.title ?? "",
      url: r.link ?? "",
      snippet: r.snippet ?? "",
    }));
    });
  }
}

class BraveProvider implements WebSearchProvider {
  id = "brave";
  available = true;
  constructor(private apiKey: string) {}
  async search(query: string, limit: number): Promise<WebResult[]> {
    return safeSearch(this.id, async (signal) => {
    const url = `https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=${limit}`;
    const res = await fetch(url, {
      signal,
      headers: { "X-Subscription-Token": this.apiKey, Accept: "application/json" },
    });
    if (!res.ok) {
      logger.warn({ provider: this.id, status: res.status }, "recherche web : réponse en erreur");
      return [];
    }
    const data = (await res.json()) as {
      web?: { results?: { title?: string; url?: string; description?: string }[] };
    };
    return (data.web?.results ?? []).slice(0, limit).map((r) => ({
      title: r.title ?? "",
      url: r.url ?? "",
      snippet: r.description ?? "",
    }));
    });
  }
}

let _provider: WebSearchProvider | null = null;

/** Fournisseur de recherche web configuré (ou NullProvider si aucune clé). */
export function getWebSearchProvider(): WebSearchProvider {
  if (_provider) return _provider;
  const wanted = (process.env.WEB_SEARCH_PROVIDER ?? "").toLowerCase();
  const tavily = process.env.TAVILY_API_KEY;
  const serper = process.env.SERPER_API_KEY;
  const brave = process.env.BRAVE_API_KEY;

  // Choix explicite prioritaire, sinon 1re clé disponible.
  if ((wanted === "tavily" || !wanted) && tavily) _provider = new TavilyProvider(tavily);
  else if ((wanted === "serper" || !wanted) && serper) _provider = new SerperProvider(serper);
  else if ((wanted === "brave" || !wanted) && brave) _provider = new BraveProvider(brave);
  else if (wanted === "serper" && serper) _provider = new SerperProvider(serper);
  else if (wanted === "brave" && brave) _provider = new BraveProvider(brave);
  else _provider = new NullProvider();

  return _provider;
}
