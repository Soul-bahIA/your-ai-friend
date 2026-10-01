"""Skill : contrôle d'un téléphone Android via ADB (sensible).

⚠️ ANDROID UNIQUEMENT (v1) — nécessite adb installé (Android Platform Tools,
dans le PATH) et un appareil connecté avec le débogage USB autorisé. Le contrôle
iOS nécessiterait un outillage distinct (Appium/XCUITest sur Mac), hors périmètre
de cette v1.

⚠️ NON VALIDÉ SUR MATÉRIEL RÉEL dans ce projet : aucun téléphone n'était connecté
à l'environnement de développement au moment de l'écriture. La structure suit le
même modèle de sécurité que run_command (aucun shell, sous-commandes ADB fixes) ;
seul le comportement "adb absent" a pu être vérifié. À valider avec un appareil
avant usage en production.
"""
from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys

from skills.base import PathCheck, Skill, SkillResult

_TIMEOUT = 20

# `adb shell a b c` concatène les arguments en UNE ligne exécutée par le shell du
# téléphone : chaque valeur issue de la tâche doit donc être validée/échappée.
_DEVICE_RE = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
_KEYCODE_RE = re.compile(r"^(KEYCODE_[A-Z0-9_]{1,40}|[0-9]{1,3})$")
_PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
_MAX_TEXT = 1000


def _find_adb() -> str | None:
    """adb dans le PATH (dossiers absolus uniquement, jamais le dossier courant)."""
    name = "adb.exe" if sys.platform == "win32" else "adb"
    for d in os.environ.get("PATH", "").split(os.pathsep):
        d = d.strip().strip('"')
        if d and os.path.isabs(d) and os.path.isfile(os.path.join(d, name)):
            return os.path.join(d, name)
    return None


def _check_device(device_id: object) -> str | None:
    if device_id is None or device_id == "":
        return None
    if not isinstance(device_id, str) or not _DEVICE_RE.match(device_id):
        return "champ 'device_id' invalide"
    return None


def _adb(args: list[str], device_id: str | None = None, capture_stdout: bool = False):
    adb = _find_adb()
    if not adb:
        raise FileNotFoundError("adb")
    cmd = [adb]
    if device_id:
        cmd += ["-s", device_id]
    cmd += args
    return subprocess.run(cmd, capture_output=True, timeout=_TIMEOUT, text=not capture_stdout)


class PhoneListDevicesSkill(Skill):
    """Lecture seule — à utiliser avant toute action tactile pour vérifier la connexion."""

    name = "phone_list_devices"
    step_types = ("phone_list_devices",)
    category = "phone"
    sensitive = False

    def describe(self, step: dict) -> str:
        return "lister les téléphones Android connectés (adb devices)"

    def run(self, step: dict) -> SkillResult:
        try:
            proc = _adb(["devices"])
        except FileNotFoundError:
            return SkillResult(
                ok=False,
                detail="adb introuvable — installez Android Platform Tools et ajoutez-le au PATH",
            )
        except subprocess.TimeoutExpired:
            return SkillResult(ok=False, detail="délai dépassé")

        lines = [l for l in proc.stdout.splitlines()[1:] if l.strip() and "device" in l]
        devices = [l.split()[0] for l in lines]
        return SkillResult(
            ok=True,
            detail=f"{len(devices)} appareil(s) : {', '.join(devices) or 'aucun'}",
            data={"devices": devices},
        )


class PhoneSkill(Skill):
    name = "phone"
    step_types = (
        "phone_tap", "phone_swipe", "phone_type", "phone_key",
        "phone_open_app", "phone_screenshot",
    )
    category = "phone"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"{step.get('type')} sur le téléphone"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        err = _check_device(step.get("device_id"))
        if err:
            return err
        t = step.get("type")
        if t == "phone_key" and not _KEYCODE_RE.match(str(step.get("keycode") or "")):
            return "champ 'keycode' invalide (ex. KEYCODE_BACK, KEYCODE_HOME, KEYCODE_ENTER)"
        if t == "phone_open_app" and not _PACKAGE_RE.match(str(step.get("package") or "")):
            return "champ 'package' invalide (ex. com.android.chrome)"
        if t == "phone_screenshot":
            path = step.get("path")
            if not isinstance(path, str) or not path.lower().endswith(".png"):
                return "champ 'path' invalide (fichier .png attendu)"
        if t == "phone_type" and len(str(step.get("text") or "")) > _MAX_TEXT:
            return f"texte trop long (max {_MAX_TEXT} caractères)"
        return None

    def run(self, step: dict) -> SkillResult:
        t = step.get("type")
        device_id = step.get("device_id") or None
        err = self.validate(step, lambda _p: True)
        if err:
            return SkillResult(ok=False, detail=err)

        try:
            if t == "phone_tap":
                x, y = step.get("x"), step.get("y")
                if x is None or y is None:
                    return SkillResult(ok=False, detail="champs 'x' et 'y' requis")
                proc = _adb(["shell", "input", "tap", str(int(x)), str(int(y))], device_id)

            elif t == "phone_swipe":
                x1, y1, x2, y2 = step.get("x1"), step.get("y1"), step.get("x2"), step.get("y2")
                if None in (x1, y1, x2, y2):
                    return SkillResult(ok=False, detail="champs 'x1','y1','x2','y2' requis")
                duration = int(step.get("duration_ms", 300))
                proc = _adb(
                    ["shell", "input", "swipe", str(int(x1)), str(int(y1)), str(int(x2)), str(int(y2)), str(duration)],
                    device_id,
                )

            elif t == "phone_type":
                text = step.get("text")
                if not text:
                    return SkillResult(ok=False, detail="champ 'text' manquant")
                # adb input text n'accepte pas les espaces bruts (%s), puis échappement
                # POSIX : le texte reste un littéral pour le shell du téléphone.
                safe = shlex.quote(str(text).replace(" ", "%s"))
                proc = _adb(["shell", "input", "text", safe], device_id)

            elif t == "phone_key":
                keycode = step.get("keycode")
                if not keycode:
                    return SkillResult(
                        ok=False,
                        detail="champ 'keycode' manquant (ex. KEYCODE_BACK, KEYCODE_HOME, KEYCODE_ENTER)",
                    )
                proc = _adb(["shell", "input", "keyevent", str(keycode)], device_id)

            elif t == "phone_open_app":
                package = step.get("package")
                if not package:
                    return SkillResult(ok=False, detail="champ 'package' manquant (ex. com.android.chrome)")
                proc = _adb(
                    ["shell", "monkey", "-p", str(package), "-c", "android.intent.category.LAUNCHER", "1"],
                    device_id,
                )

            elif t == "phone_screenshot":
                path = step.get("path")
                if not path:
                    return SkillResult(ok=False, detail="champ 'path' manquant")
                proc = _adb(["exec-out", "screencap", "-p"], device_id, capture_stdout=True)
                if proc.returncode == 0:
                    with open(path, "wb") as f:
                        f.write(proc.stdout)
                    return SkillResult(ok=True, detail=f"capture téléphone enregistrée : {path}", data={"path": path})
                return SkillResult(ok=False, detail=f"échec capture : code {proc.returncode}")

            else:
                return SkillResult(ok=False, detail=f"type inconnu : {t}")

        except FileNotFoundError:
            return SkillResult(
                ok=False,
                detail="adb introuvable — installez Android Platform Tools et ajoutez-le au PATH",
            )
        except subprocess.TimeoutExpired:
            return SkillResult(ok=False, detail="délai dépassé")
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec ADB : {e}")

        ok = proc.returncode == 0
        err = (proc.stderr or "").strip()[:300] if not ok else ""
        return SkillResult(ok=ok, detail=f"{t} exécuté" + (f" (erreur : {err})" if err else ""))
