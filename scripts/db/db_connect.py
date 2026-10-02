"""Connexion PostgreSQL commune aux outils de base de Soulbah (DB LOT 0).

Aucune dépendance Python : les requêtes passent par `psql` (client PostgreSQL ≥ version du serveur).
Le mot de passe n'apparaît jamais sur une ligne de commande ni dans une sortie : il est transmis
au processus psql par l'environnement (PGPASSWORD) et masqué dans les messages d'erreur.

Cibles :
  supabase  DATABASE_URL de backend/.env (base Supabase restaurée)
  dev       DATABASE_URL de .dev_db/dev.env (PostgreSQL local jetable, port 54329)
  <url>     toute URL postgresql://… (ex. base de copie locale)
Variables : PSQL (chemin de psql), SOULBAH_DB_URL_<CIBLE> pour surcharger une cible.

`read_only=True` (défaut) enveloppe le SQL dans BEGIN READ ONLY … ROLLBACK : même une requête
d'écriture glissée par erreur est refusée par le serveur.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PSQL_WIN = r"C:\Program Files\PostgreSQL\18\bin\psql.exe"
LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}


class DbError(RuntimeError):
    pass


def _env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text("utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value.strip().strip('"').strip("'")
    return out


def resolve_url(target: str) -> str:
    override = os.environ.get(f"SOULBAH_DB_URL_{target.upper()}")
    if override:
        return override
    if target == "supabase":
        url = _env_file(ROOT / "backend" / ".env").get("DATABASE_URL")
    elif target == "dev":
        url = _env_file(ROOT / ".dev_db" / "dev.env").get("DATABASE_URL")
    elif "://" in target:
        url = target
    else:
        raise DbError(f"cible inconnue : {target!r} (supabase, dev ou URL postgresql://)")
    if not url:
        raise DbError(f"aucune URL pour la cible {target!r}")
    return url


@dataclass(frozen=True)
class Conn:
    host: str
    port: int
    user: str
    dbname: str
    password: str | None
    sslmode: str | None

    @property
    def is_local(self) -> bool:
        return self.host in LOCAL_HOSTS

    def label(self) -> str:
        """Description sans secret (journal, rapports)."""
        return f"{self.user}@{self.host}:{self.port}/{self.dbname}"


def parse(url: str) -> Conn:
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("postgres", "postgresql"):
        raise DbError("URL PostgreSQL attendue")
    q = urllib.parse.parse_qs(u.query)
    host = u.hostname or "127.0.0.1"
    sslmode = q.get("sslmode", [None])[0] or (None if host in LOCAL_HOSTS else "require")
    port = u.port or 5432
    if host.endswith(".pooler.supabase.com") and port == 6543:
        port = 5432  # mode session du pooler : seul compatible avec pg_dump et les sessions longues
    return Conn(host=host, port=port, user=urllib.parse.unquote(u.username or "postgres"),
                dbname=(u.path or "/postgres").lstrip("/") or "postgres",
                password=urllib.parse.unquote(u.password) if u.password else None, sslmode=sslmode)


def psql_path() -> str:
    exe = os.environ.get("PSQL") or shutil.which("psql") or DEFAULT_PSQL_WIN
    if not Path(exe).exists() and not shutil.which(exe):
        raise DbError("psql introuvable (définir PSQL)")
    return exe


def client_env(conn: Conn) -> dict[str, str]:
    env = dict(os.environ)
    env.update({"PGCLIENTENCODING": "UTF8", "PGCONNECT_TIMEOUT": "20", "PGHOST": conn.host,
                "PGPORT": str(conn.port), "PGUSER": conn.user, "PGDATABASE": conn.dbname,
                "PGAPPNAME": "soulbah-db-tools"})
    env.pop("PGPASSWORD", None)
    if conn.password:
        env["PGPASSWORD"] = conn.password
    if conn.sslmode:
        env["PGSSLMODE"] = conn.sslmode
    return env


def _mask(text: str, conn: Conn) -> str:
    return text.replace(conn.password, "***") if conn.password else text


def run_sql(conn: Conn, sql: str, *, read_only: bool = True, timeout_s: int = 300, tuples_only: bool = True,
            statement_timeout: str = "120s") -> str:
    """Exécute `sql` et renvoie la sortie texte de psql (non alignée)."""
    body = sql.strip().rstrip(";")
    if read_only:
        script = f"BEGIN READ ONLY;\nSET LOCAL statement_timeout = '{statement_timeout}';\n{body};\nROLLBACK;\n"
    else:
        script = body + ";\n"
    args = [psql_path(), "-w", "-X", "-q", "-A", "-P", "pager=off", "-v", "ON_ERROR_STOP=1"]
    if tuples_only:
        args.append("-t")
    p = subprocess.run(args, input=script, capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=client_env(conn), timeout=timeout_s)
    if p.returncode != 0:
        err = DbError(_mask(p.stderr.strip() or f"psql a échoué (code {p.returncode})", conn))
        err.stdout = _mask(p.stdout, conn)  # type: ignore[attr-defined] — repères \echo avant l'erreur
        raise err
    return p.stdout


def connect(target: str) -> Conn:
    return parse(resolve_url(target))
