"""Faux llama-server pour les tests (V3 LOT 2) : mêmes routes et mêmes champs que le vrai
(/health, /v1/models, /v1/chat/completions avec `timings`), réponses déterministes.

Usage : python fake_llama_server.py -m MODELE --host 127.0.0.1 --port P [...autres options ignorées]
Variable FAKE_LLAMA_FAIL=1 : sort aussitôt avec le code 3 (démarrage raté).
"""
from __future__ import annotations

import http.server
import json
import os
import sys


def answer(payload: dict) -> str:
    rf = payload.get("response_format") or {}
    if rf.get("schema"):
        return json.dumps({"steps": [{"tool": "write_file", "path": "C:\\w\\a.txt", "content": "bonjour"}]})
    text = " ".join(str(m.get("content")) for m in payload.get("messages") or [])
    if "pièces" in text:
        return "79"
    if "ligne contient l'erreur" in text:
        return "5"
    if "journaux d'audit" in text:
        return "Ils sont conservés 7 ans."
    if "hors ligne" in text:
        return "Un assistant hors ligne garde vos données sur votre machine."
    return "ok"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_a):
        pass

    def _json(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            self._json(200, {"status": "ok"})
        elif self.path == "/v1/models":
            self._json(200, {"data": [{"id": MODEL}]})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(n) or b"{}")
        if self.path != "/v1/chat/completions":
            self._json(404, {"error": "not found"})
            return
        text = answer(payload)
        self._json(200, {"choices": [{"message": {"role": "assistant", "content": text}}],
                         "usage": {"prompt_tokens": 20, "completion_tokens": 10},
                         "timings": {"predicted_n": 10, "predicted_ms": 500.0}})


if __name__ == "__main__":
    if os.environ.get("FAKE_LLAMA_FAIL") == "1":
        sys.exit(3)
    args = sys.argv[1:]
    port = int(args[args.index("--port") + 1])
    MODEL = args[args.index("-m") + 1] if "-m" in args else "fake"
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
