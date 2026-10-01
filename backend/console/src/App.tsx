import { useState, type FormEvent } from "react";
import { analyze, type AnalyzeResponse } from "./api/client";
import { ResultCard } from "./components/ResultCard";
import { HealthBar } from "./components/HealthBar";
import { AuthPanel } from "./components/AuthPanel";

export default function App() {
  const [text, setText] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<AnalyzeResponse | null>(null);

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!text.trim() || loading) return;
    setLoading(true);
    setError(null);
    try {
      const res = await analyze(text.trim());
      setResult(res);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Erreur inconnue");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="app">
      <header className="header">
        <h1>
          SOULBAH <span className="accent">IA</span>
        </h1>
        <p className="subtitle">
          Console de test — backend polyglotte · Node · Python · Rust · Postgres
        </p>
        <HealthBar />
      </header>

      <main className="main">
        <AuthPanel />

        <form className="card" onSubmit={onSubmit}>
          <label htmlFor="text" className="label">
            Texte à analyser
          </label>
          <textarea
            id="text"
            className="textarea"
            placeholder="Ex : Cette application est vraiment géniale"
            value={text}
            onChange={(e) => setText(e.target.value)}
            rows={4}
            disabled={loading}
          />
          <button className="button" type="submit" disabled={loading || !text.trim()}>
            {loading ? "Analyse en cours…" : "Analyser"}
          </button>
          {error && <p className="error">⚠ {error}</p>}
        </form>

        {result && <ResultCard result={result} />}
      </main>

      <footer className="footer">
        Flutter et cette console appellent la même API Node — <code>/api/analyze</code>
      </footer>
    </div>
  );
}
