"""Banc d'essai des modèles locaux (V3 LOT 2, mission §44-46) sur tout serveur compatible OpenAI.

Tâches standard, notées par des règles (jamais par un autre modèle, jamais en exécutant le code
produit) :
  plan_json      plan d'outils conforme à un schéma (sortie contrainte) pour un objectif simple ;
  reasoning      petit problème à réponse numérique unique ;
  code_review    numéro de la ligne fautive d'une fonction Python ;
  doc_qa         réponse tirée d'un passage fourni (lecture de documentation locale) ;
  french_summary consigne en français respectée (une phrase, mot imposé).
Mesures : réussite par tâche, durée, jetons générés par seconde (champ `timings` de llama-server,
sinon usage / durée), mémoire de pointe du serveur (pid connu). Le résultat est rangé dans le
registre (`benchmark`) : le routeur local choisit sur ces mesures, pas sur la réputation.
"""
from __future__ import annotations

import json
import re
import time
from typing import Any, Callable

from local_models import registry

PLAN_SCHEMA = {
    "type": "object",
    "required": ["steps"],
    "properties": {
        "steps": {
            "type": "array", "minItems": 1, "maxItems": 5,
            "items": {"type": "object", "required": ["tool"],
                      "properties": {"tool": {"type": "string", "enum": ["write_file", "read_file", "wait"]},
                                     "path": {"type": "string"}, "content": {"type": "string"}}},
        },
    },
}

CODE = """1 def moyenne(valeurs):
2     total = 0
3     for v in valeurs:
4         total += v
5     return total / (len(valeurs) - 1)"""

DOC = ("Guide interne : le service d'archivage conserve les rapports 400 jours. Les journaux d'audit "
       "sont conservés 7 ans. Les captures d'écran temporaires sont effacées après 30 jours.")


def _tasks() -> list[dict[str, Any]]:
    return [
        {"id": "plan_json", "schema": PLAN_SCHEMA,
         "prompt": "Objectif : écrire le texte « bonjour » dans le fichier C:\\w\\a.txt. Donne le plan en JSON.",
         "check": lambda text, js: bool(js) and any(s.get("tool") == "write_file" and "a.txt" in str(s.get("path"))
                                                     for s in js.get("steps", []) if isinstance(s, dict))},
        {"id": "reasoning",
         "prompt": "Un atelier produit 12 pièces par heure pendant 7 heures, puis 5 pièces sont rejetées. "
                   "Combien de pièces sont acceptées ? Réponds uniquement par le nombre.",
         "check": lambda text, js: _first_int(text) == 79},
        {"id": "code_review",
         "prompt": f"Voici une fonction Python numérotée :\n{CODE}\nQuelle ligne contient l'erreur ? "
                   "Réponds uniquement par le numéro de ligne.",
         "check": lambda text, js: _first_int(text) == 5},
        {"id": "doc_qa",
         "prompt": f"Document :\n{DOC}\nQuestion : combien de temps les journaux d'audit sont-ils conservés ? "
                   "Réponds en quelques mots.",
         "check": lambda text, js: bool(re.search(r"\b7\b|sept", text.lower())) and "an" in text.lower()},
        {"id": "french_summary",
         "prompt": "En une seule phrase en français contenant le mot « hors ligne », explique l'intérêt d'un "
                   "assistant qui fonctionne sans Internet.",
         "check": lambda text, js: "hors ligne" in text.lower() and text.strip().count(".") <= 2},
    ]


def _first_int(text: str) -> int | None:
    m = re.search(r"-?\d+", text or "")
    return int(m.group()) if m else None


def _post(base_url: str, payload: dict[str, Any], timeout: float) -> tuple[dict[str, Any], float]:
    import requests

    t = time.perf_counter()
    r = requests.post(f"{base_url.rstrip('/')}/chat/completions", json=payload, timeout=timeout)
    elapsed = time.perf_counter() - t
    if r.status_code != 200:
        raise RuntimeError(f"HTTP {r.status_code} : {r.text[:200]}")
    return r.json(), elapsed


def run(base_url: str, model: str = "local", timeout: float = 600.0, server_pid: int | None = None,
        post: Callable[[str, dict[str, Any], float], tuple[dict[str, Any], float]] | None = None) -> dict[str, Any]:
    post = post or _post
    results: list[dict[str, Any]] = []
    total_tokens = 0
    total_gen_s = 0.0
    for task in _tasks():
        payload: dict[str, Any] = {"model": model, "temperature": 0, "max_tokens": 256,
                                   "messages": [{"role": "user", "content": task["prompt"]}]}
        if task.get("schema"):
            payload["response_format"] = {"type": "json_object", "schema": task["schema"]}
        entry: dict[str, Any] = {"id": task["id"]}
        try:
            data, elapsed = post(base_url, payload, timeout)
            text = str(((data.get("choices") or [{}])[0].get("message") or {}).get("content") or "")
            js = None
            if task.get("schema"):
                try:
                    js = json.loads(text)
                except ValueError:
                    js = None
            ok = bool(task["check"](text, js))
            timings = data.get("timings") or {}
            usage = data.get("usage") or {}
            gen = int(timings.get("predicted_n") or usage.get("completion_tokens") or 0)
            gen_s = float(timings.get("predicted_ms") or 0) / 1000 or elapsed
            total_tokens += gen
            total_gen_s += gen_s
            entry.update(passed=ok, seconds=round(elapsed, 2), output_tokens=gen,
                         tokens_per_s=round(gen / gen_s, 1) if gen and gen_s else None, answer=text[:300])
        except Exception as e:  # noqa: BLE001 - une tâche en erreur compte comme un échec mesuré
            entry.update(passed=False, error=str(e)[:300])
        results.append(entry)
    passed = sum(1 for r in results if r.get("passed"))
    report = {
        "at": registry.now_iso(), "model": model, "base_url": base_url, "tasks": results,
        "score": f"{passed}/{len(results)}", "passed": passed, "total": len(results),
        "tokens_per_s": round(total_tokens / total_gen_s, 1) if total_tokens and total_gen_s else None,
        "seconds": round(sum(r.get("seconds") or 0 for r in results), 1),
    }
    if server_pid:
        from local_models.server import peak_memory_mb

        report["server_peak_mb"] = peak_memory_mb(server_pid)
    return report


def run_and_record(model_id: str, base_url: str, server_pid: int | None = None, **kw: Any) -> dict[str, Any]:
    report = run(base_url, model=model_id, server_pid=server_pid, **kw)
    entry = registry.load()["models"].get(model_id)
    if entry is not None:
        status = "verified" if report["passed"] > 0 else "failed"
        registry.upsert("models", {"id": model_id, "benchmark": report, "status": status})
    return report
