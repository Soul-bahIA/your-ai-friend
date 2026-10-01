"""Synthèse vocale locale (V3 LOT 11, mission §33-35) : `speak_text` parle sur le haut-parleur ou
écrit un fichier WAV avec les voix installées sur Windows (SAPI 5, System.Speech) — aucune API
cloud, aucun téléchargement, fonctionne en mode OFFLINE.

Le texte et les paramètres passent par un fichier JSON temporaire lu par un script PowerShell
statique (skills/sapi_speak.ps1) : jamais par la ligne de commande. Le texte est masqué dans les
journaux (is_secret_text). Voix par défaut : la première voix française installée.
"""
from __future__ import annotations

import json
import os
import shutil
import struct
import sys
import tempfile

from skills.base import PathCheck, Skill, SkillResult, current_token
from skills.manifests import declared_param_error
from skills.proctree import run_tree

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sapi_speak.ps1")
MAX_CHARS = 5000


def powershell() -> str | None:
    root = os.environ.get("SystemRoot", r"C:\Windows")
    exe = os.path.join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    return exe if os.path.isfile(exe) else shutil.which("powershell")


def wav_duration_s(path: str) -> float | None:
    """Durée d'un WAV PCM (en-tête RIFF) ; None si illisible."""
    try:
        with open(path, "rb") as f:
            head = f.read(4096)
        if head[:4] != b"RIFF" or head[8:12] != b"WAVE":
            return None
        i = 12
        byte_rate = None
        while i + 8 <= len(head):
            cid, size = head[i:i + 4], struct.unpack("<I", head[i + 4:i + 8])[0]
            if cid == b"fmt ":
                byte_rate = struct.unpack("<I", head[i + 16:i + 20])[0]
            if cid == b"data" and byte_rate:
                return round(size / byte_rate, 2)
            i += 8 + size + (size & 1)
    except OSError:
        return None
    return None


class SpeakTextSkill(Skill):
    name = "speak_text"
    step_types = ("speak_text",)
    category = "voice"
    timeout_s = 180.0

    def describe(self, step: dict) -> str:
        where = f" → {step.get('output')}" if step.get("output") else " (haut-parleur)"
        return f"speak_text : {len(str(step.get('text') or ''))} caractère(s){where}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        declared = declared_param_error(step)
        if declared:
            return declared
        text = step.get("text")
        if not isinstance(text, str) or not text.strip():
            return "champ 'text' requis"
        out = step.get("output")
        if out:
            if not os.path.isabs(out) or not out.lower().endswith(".wav"):
                return "champ 'output' : chemin absolu .wav attendu"
            if not path_allowed(out):
                return f"champ 'output' hors des dossiers autorisés : {out}"
        return None

    def run(self, step: dict) -> SkillResult:
        if sys.platform != "win32":
            return SkillResult(ok=False, detail="speak_text : voix Windows uniquement (moteur local Piper : à venir)")
        ps = powershell()
        if not ps:
            return SkillResult(ok=False, detail="PowerShell introuvable : synthèse vocale indisponible")
        params = {"text": str(step["text"])[:MAX_CHARS], "voice": str(step.get("voice") or ""),
                  "rate": int(step.get("rate") or 0), "output": str(step.get("output") or "")}
        fd, tmp = tempfile.mkstemp(prefix="soulbah-tts-", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(params, f, ensure_ascii=False)
            res = run_tree([ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", SCRIPT, tmp],
                           cwd=os.path.dirname(SCRIPT), timeout=float(self.timeout_s), cancel=current_token())
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
        if res.cancelled or res.timed_out:
            return SkillResult(ok=False, detail="synthèse vocale interrompue" if res.cancelled else "synthèse vocale : délai dépassé")
        if res.returncode != 0:
            err = (res.stderr or "").strip().splitlines()
            return SkillResult(ok=False, detail=f"synthèse vocale impossible : {err[-1][:200] if err else 'code ' + str(res.returncode)}")
        voice = (res.stdout or "").strip().splitlines()[-1:] or [""]
        data = {"voice": voice[0], "chars": len(params["text"]), "engine": "sapi"}
        if params["output"]:
            dur = wav_duration_s(params["output"])
            if not dur:
                return SkillResult(ok=False, detail="fichier audio absent ou vide après synthèse")
            data.update(path=params["output"], duration_s=dur)
            return SkillResult(ok=True, detail=f"voix « {voice[0]} » → {params['output']} ({dur} s)", data=data)
        return SkillResult(ok=True, detail=f"énoncé par la voix « {voice[0]} »", data=data)
