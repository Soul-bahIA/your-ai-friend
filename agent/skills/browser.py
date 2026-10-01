"""Lecture d'une page web (LOT 12, rôle researcher ; audit §9.7).

`browser_get` récupère une page en lecture seule et en rend une preuve vérifiable : statut HTTP,
URL finale, titre, empreinte sha256 du contenu et un extrait de texte (rédigé, borné).

Moteur : Playwright (Chromium sans interface) s'il est installé ET demandé (`engine: "browser"`,
pages qui exigent JavaScript), sinon une requête HTTP GET simple. Garde-fous, quel que soit le
moteur :
  - http/https seulement, sans identifiants dans l'URL ;
  - adresses privées, locales, de bouclage ou réservées REFUSÉES (anti-SSRF : la box, l'API
    locale, les métadonnées cloud…) sauf SOULBAH_BROWSER_ALLOW_PRIVATE=1 (tests, intranet) ;
  - redirections suivies une à une et revérifiées (5 au plus) ;
  - corps limité à 5 Mo, délai borné ; jamais de cookie ni d'en-tête d'authentification envoyés.
"""
from __future__ import annotations

import hashlib
import html
import ipaddress
import os
import re
import socket
import time
from typing import Any
from urllib.parse import urljoin, urlsplit

from skills.base import PathCheck, Skill, SkillResult, current_token
from skills.manifests import declared_param_error

MAX_BYTES = 5 * 1024 * 1024
MAX_REDIRECTS = 5
EXCERPT_CHARS = 2000
DEFAULT_TIMEOUT = 20.0
USER_AGENT = "SoulBahAgent/2 (+lecture seule)"
_TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.I | re.S)
_SCRIPT_RE = re.compile(r"<(script|style|noscript)[^>]*>.*?</\1>", re.I | re.S)
_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")


def allow_private() -> bool:
    return os.environ.get("SOULBAH_BROWSER_ALLOW_PRIVATE", "").strip().lower() in ("1", "true", "yes", "oui")


def url_problem(url: object) -> str | None:
    """Refus structurel d'une URL (schéma, identifiants, hôte), sans résolution DNS."""
    if not isinstance(url, str) or not url.strip() or len(url) > 2000:
        return "champ 'url' requis (2000 caractères au plus)"
    parts = urlsplit(url.strip())
    if parts.scheme not in ("http", "https"):
        return f"schéma refusé : {parts.scheme or '(aucun)'} (http ou https seulement)"
    if parts.username or parts.password:
        return "identifiants dans l'URL refusés"
    if not parts.hostname:
        return "hôte manquant"
    return None


def _ip_refusal(ip: str) -> str | None:
    try:
        addr = ipaddress.ip_address(ip.split("%", 1)[0])
    except ValueError:
        return f"adresse illisible : {ip}"
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
        addr = addr.ipv4_mapped
    if (addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_reserved
            or addr.is_multicast or addr.is_unspecified):
        return f"adresse non publique refusée : {addr} (SOULBAH_BROWSER_ALLOW_PRIVATE=1 pour un réseau local)"
    return None


def host_refusal(url: str) -> str | None:
    """Refus si l'hôte résout vers une adresse non publique (toutes les adresses sont vérifiées)."""
    if allow_private():
        return None
    host = urlsplit(url).hostname or ""
    port = urlsplit(url).port or (443 if url.lower().startswith("https") else 80)
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except (socket.gaierror, UnicodeError) as e:
        return f"hôte introuvable : {host} ({e})"
    for info in infos:
        err = _ip_refusal(str(info[4][0]))
        if err:
            return err
    return None


def page_title(body: str) -> str:
    m = _TITLE_RE.search(body)
    return _WS_RE.sub(" ", html.unescape(m.group(1))).strip()[:300] if m else ""


def visible_text(body: str) -> str:
    text = _TAG_RE.sub(" ", _SCRIPT_RE.sub(" ", body))
    return _WS_RE.sub(" ", html.unescape(text)).strip()


def _http_get(url: str, timeout: float) -> dict[str, Any]:
    import requests  # dépendance de l'agent (requirements.txt)

    session = requests.Session()
    session.trust_env = False  # ni proxy ni .netrc implicites
    current = url
    token = current_token()
    for hop in range(MAX_REDIRECTS + 1):
        err = url_problem(current) or host_refusal(current)
        if err:
            raise PermissionError(err if hop == 0 else f"redirection refusée vers {current} : {err}")
        if token.is_cancelled():
            raise InterruptedError("lecture interrompue (arrêt demandé)")
        with session.get(current, timeout=timeout, allow_redirects=False, stream=True,
                         headers={"User-Agent": USER_AGENT, "Accept": "text/html,*/*;q=0.5"}) as r:
            if r.is_redirect and r.headers.get("location"):
                current = urljoin(current, r.headers["location"])
                continue
            chunks: list[bytes] = []
            size = 0
            for chunk in r.iter_content(64 * 1024):
                size += len(chunk)
                if size > MAX_BYTES:
                    raise ValueError(f"page trop volumineuse (> {MAX_BYTES // (1024 * 1024)} Mo)")
                chunks.append(chunk)
                if token.is_cancelled():
                    raise InterruptedError("lecture interrompue (arrêt demandé)")
            content = b"".join(chunks)
            ctype = r.headers.get("content-type", "")
            encoding = r.encoding if "charset" in ctype.lower() and r.encoding else "utf-8"
            return {"status": r.status_code, "final_url": current, "content": content,
                    "content_type": ctype, "encoding": encoding}
    raise ValueError(f"trop de redirections (> {MAX_REDIRECTS})")


def _browser_get(url: str, timeout: float) -> dict[str, Any]:
    """Chromium sans interface (Playwright). Les requêtes de la page sont filtrées par le même
    contrôle d'hôte que le moteur HTTP."""
    from playwright.sync_api import sync_playwright  # type: ignore[import-not-found]

    err = url_problem(url) or host_refusal(url)
    if err:
        raise PermissionError(err)
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            ctx = browser.new_context(user_agent=USER_AGENT, accept_downloads=False)
            page = ctx.new_page()

            def _route(route: Any) -> None:
                req_url = route.request.url
                if req_url.startswith(("data:", "blob:")) or not (url_problem(req_url) or host_refusal(req_url)):
                    route.continue_()
                else:
                    route.abort()

            page.route("**/*", _route)
            resp = page.goto(url, timeout=timeout * 1000, wait_until="load")
            body = page.content()
            content = body.encode("utf-8")
            if len(content) > MAX_BYTES:
                raise ValueError(f"page trop volumineuse (> {MAX_BYTES // (1024 * 1024)} Mo)")
            final = page.url
            err = url_problem(final) or host_refusal(final)
            if err:
                raise PermissionError(f"redirection refusée vers {final} : {err}")
            return {"status": resp.status if resp else 0, "final_url": final, "content": content,
                    "content_type": "text/html", "encoding": "utf-8"}
        finally:
            browser.close()


def playwright_available() -> bool:
    try:
        import playwright.sync_api  # type: ignore[import-not-found]  # noqa: F401
        return True
    except Exception:  # noqa: BLE001
        return False


class BrowserGetSkill(Skill):
    name = "browser_get"
    step_types = ("browser_get",)
    category = "web"
    sensitive = False
    timeout_s = 90.0

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        declared = declared_param_error(step)
        if declared:
            return declared
        err = url_problem(step.get("url"))
        if err:
            return err
        engine = step.get("engine", "auto")
        if engine not in ("auto", "http", "browser"):
            return "champ 'engine' : auto | http | browser"
        t = step.get("timeout", DEFAULT_TIMEOUT)
        if isinstance(t, bool) or not isinstance(t, (int, float)) or not 1 <= t <= 60:
            return "champ 'timeout' : 1 à 60 secondes"
        return None

    def describe(self, step: dict) -> str:
        return f"browser_get: {str(step.get('url'))[:200]}"

    def run(self, step: dict) -> SkillResult:
        url = str(step["url"]).strip()
        timeout = float(step.get("timeout", DEFAULT_TIMEOUT))
        engine = step.get("engine", "auto")
        use_browser = engine == "browser"
        if use_browser and not playwright_available():
            return SkillResult(ok=False, detail="moteur navigateur demandé mais Playwright n'est pas installé "
                                                "(pip install playwright && playwright install chromium)")
        started = time.monotonic()
        try:
            got = _browser_get(url, timeout) if use_browser else _http_get(url, timeout)
        except PermissionError as e:
            return SkillResult(ok=False, detail=str(e))
        except InterruptedError as e:
            return SkillResult(ok=False, detail=str(e))
        except Exception as e:  # noqa: BLE001 - réseau, TLS, délai…
            return SkillResult(ok=False, detail=f"lecture impossible : {e.__class__.__name__}: {str(e)[:300]}")
        content: bytes = got["content"]
        digest = hashlib.sha256(content).hexdigest()
        text_types = ("text/", "html", "xml", "json")
        is_text = any(t in str(got["content_type"]).lower() for t in text_types) or not got["content_type"]
        body = content.decode(got["encoding"] or "utf-8", errors="replace") if is_text else ""
        title = page_title(body) if body else ""
        excerpt = visible_text(body)[:EXCERPT_CHARS] if body else ""
        status = int(got["status"])
        data = {
            "http": {"status": status, "url": url, "final_url": got["final_url"]},
            "status": status,
            "final_url": got["final_url"],
            "title": title,
            "sha256": digest,
            "bytes": len(content),
            "content_type": str(got["content_type"])[:100],
            "excerpt": excerpt,
            "engine": "browser" if use_browser else "http",
            "elapsed_ms": int((time.monotonic() - started) * 1000),
        }
        ok = 200 <= status < 400
        detail = f"HTTP {status} · {got['final_url'][:200]}" + (f" · « {title[:80]} »" if title else "")
        return SkillResult(ok=ok, detail=detail, data=data)
