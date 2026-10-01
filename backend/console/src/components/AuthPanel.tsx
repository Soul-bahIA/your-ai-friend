import { useEffect, useState, type FormEvent } from "react";
import {
  getSession,
  onSessionChange,
  passwordLoginAvailable,
  setManualToken,
  signInWithPassword,
  signOut,
  type StoredSession,
} from "../api/auth";
import { API_URL } from "../api/client";

/** Connexion de la console : e-mail / mot de passe Supabase, ou jeton collé. */
export function AuthPanel() {
  const [session, setSession] = useState<StoredSession | null>(() => getSession());
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [token, setToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => onSessionChange(setSession), []);

  const run = async (fn: () => Promise<unknown> | unknown) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      setPassword("");
      setToken("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Erreur inconnue");
    } finally {
      setBusy(false);
    }
  };

  const onLogin = (e: FormEvent) => {
    e.preventDefault();
    if (!email.trim() || !password) return;
    void run(() => signInWithPassword(email.trim(), password));
  };

  const onToken = (e: FormEvent) => {
    e.preventDefault();
    if (!token.trim()) return;
    void run(() => setManualToken(token));
  };

  if (session) {
    const expires = session.exp ? new Date(session.exp * 1000).toLocaleTimeString("fr-FR") : null;
    return (
      <div className="card auth auth--ok">
        <span>
          <span className="dot dot--ok" /> Connecté{session.email ? ` : ${session.email}` : " (jeton)"}
          {expires && <span className="muted"> · expire à {expires}</span>}
        </span>
        <button className="link" type="button" onClick={() => void signOut(API_URL)}>
          Se déconnecter
        </button>
      </div>
    );
  }

  return (
    <div className="card auth">
      <p className="label">L'analyse exige d'être connecté (jeton Supabase).</p>
      {passwordLoginAvailable && (
        <form onSubmit={onLogin} className="auth__form">
          <input
            className="input"
            type="email"
            placeholder="E-mail"
            autoComplete="username"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            disabled={busy}
            aria-label="E-mail"
          />
          <input
            className="input"
            type="password"
            placeholder="Mot de passe"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            disabled={busy}
            aria-label="Mot de passe"
          />
          <button className="button" type="submit" disabled={busy || !email.trim() || !password}>
            {busy ? "Connexion…" : "Se connecter"}
          </button>
        </form>
      )}
      <form onSubmit={onToken} className="auth__form">
        <label className="label" htmlFor="jwt">
          {passwordLoginAvailable ? "… ou collez un jeton d'accès (JWT)" : "Collez un jeton d'accès Supabase (JWT)"}
        </label>
        <input
          id="jwt"
          className="input"
          type="password"
          placeholder="eyJhbGciOi…"
          value={token}
          onChange={(e) => setToken(e.target.value)}
          disabled={busy}
          autoComplete="off"
        />
        <button className="button button--secondary" type="submit" disabled={busy || !token.trim()}>
          Utiliser ce jeton
        </button>
      </form>
      {!passwordLoginAvailable && (
        <p className="muted small">
          Astuce : définissez VITE_SUPABASE_URL et VITE_SUPABASE_KEY pour activer la connexion par e-mail.
        </p>
      )}
      {error && <p className="error">⚠ {error}</p>}
    </div>
  );
}
