"""Skill : exécuter une commande de développement (Git, compile, tests) — TRÈS sensible.

Sécurité :
  - Allowlist stricte de programmes (aucun shell, pas d'opérateurs `&& | ; $()`).
  - Arguments passés en liste (jamais concaténés dans une ligne de shell).
  - `cwd` optionnel, validé par le gate contre la liste blanche de dossiers.
  - Timeout borné, sortie tronquée.

Exemple : {"type": "run_command", "program": "git", "args": ["status"], "cwd": "C:/projets/app"}
"""
from __future__ import annotations

import subprocess

from skills.base import Skill, SkillResult

# Seuls ces programmes peuvent être lancés. Étendre au besoin, en connaissance de cause.
ALLOWED_PROGRAMS = {
    "git", "node", "npm", "npx", "pnpm", "yarn",
    "python", "python3", "pip", "pytest",
    "cargo", "rustc", "go", "dotnet", "java", "javac",
    "mvn", "gradle", "tsc", "jest", "vitest", "eslint", "make", "cmake",
}

_MAX_OUTPUT = 4000
_DEFAULT_TIMEOUT = 120
_MAX_TIMEOUT = 600

# Drapeaux qui font évaluer du code arbitraire passé en argument : avec eux,
# l'allowlist ne protège plus de rien (ex. `python -c "..."`). Refusés.
_EVAL_FLAGS_BY_PROGRAM = {
    "python": {"-c"},
    "python3": {"-c"},
    "node": {"-e", "--eval", "-p", "--print"},
    "npx": {"-c", "--call"},
}


class RunCommandSkill(Skill):
    name = "run_command"
    step_types = ("run_command", "run_script", "shell")
    category = "shell"
    sensitive = True

    def describe(self, step: dict) -> str:
        prog = step.get("program", "?")
        args = step.get("args") or []
        cwd = step.get("cwd")
        line = f"{prog} {' '.join(map(str, args))}".strip()
        return f"exécuter « {line} »" + (f" dans {cwd}" if cwd else "")

    def run(self, step: dict) -> SkillResult:
        prog = str(step.get("program", "")).strip()
        if not prog:
            return SkillResult(ok=False, detail="champ 'program' manquant")
        if prog not in ALLOWED_PROGRAMS:
            return SkillResult(
                ok=False,
                detail=f"programme non autorisé : '{prog}' (allowlist : {', '.join(sorted(ALLOWED_PROGRAMS))})",
            )

        args = step.get("args") or []
        if not isinstance(args, list):
            return SkillResult(ok=False, detail="'args' doit être une liste")
        args = [str(a) for a in args]

        # Refus des tentatives d'injection via un argument qui masquerait un opérateur
        # shell — y compris les retours à la ligne (contournent le filtre du `;`).
        for a in args:
            if any(tok in a for tok in ("&&", "||", "|", ";", "`", "$(", ">", "<", "\n", "\r")):
                return SkillResult(ok=False, detail=f"argument suspect refusé : {a}")

        blocked_flags = _EVAL_FLAGS_BY_PROGRAM.get(prog, set())
        for a in args:
            if a in blocked_flags:
                return SkillResult(
                    ok=False,
                    detail=f"drapeau refusé pour {prog} : '{a}' (évaluation de code arbitraire)",
                )

        cwd = step.get("cwd") or None
        timeout = min(float(step.get("timeout", _DEFAULT_TIMEOUT)), _MAX_TIMEOUT)

        try:
            proc = subprocess.run(
                [prog, *args],
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=timeout,
                shell=False,
            )
        except FileNotFoundError:
            return SkillResult(ok=False, detail=f"programme introuvable sur le système : {prog}")
        except subprocess.TimeoutExpired:
            return SkillResult(ok=False, detail=f"délai dépassé ({timeout}s)")
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec exécution : {e}")

        out = (proc.stdout or "")[:_MAX_OUTPUT]
        err = (proc.stderr or "")[:_MAX_OUTPUT]
        ok = proc.returncode == 0
        detail = f"code={proc.returncode}"
        if out:
            detail += f" | stdout: {out.strip()[:500]}"
        if not ok and err:
            detail += f" | stderr: {err.strip()[:500]}"
        return SkillResult(ok=ok, detail=detail, data={"returncode": proc.returncode, "stdout": out, "stderr": err})
