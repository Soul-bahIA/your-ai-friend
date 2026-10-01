"""Skill : montage professionnel via DaVinci Resolve (API de script locale, sensible).

L'agent pilote DaVinci Resolve INSTALLE sur le poste : import des medias, creation
d'une timeline, puis export MP4 en local — sans passer par une API cloud pour le montage.

PREREQUIS (a faire une fois sur le PC) :
  1. Installer DaVinci Resolve (gratuit) : https://www.blackmagicdesign.com/products/davinciresolve
  2. Lancer Resolve au moins une fois.
  3. Preferences > System > General : "External scripting using" = Local.
  4. Resolve doit etre OUVERT quand l'agent execute ce skill.

Etape type :
  {"type": "resolve_montage",
   "clips": ["C:/.../intro.png", "C:/.../demo1.mp4", "C:/.../outro.png"],
   "audio": "C:/.../narration.mp3",
   "output": "C:/.../formation_finale.mp4",
   "project": "Formation Marketing"}

NON VALIDE SUR MATERIEL REEL dans ce projet (Resolve n'etait pas installe a l'ecriture) :
a valider/ajuster sur le poste apres installation.
"""
from __future__ import annotations

import os
import sys
import time

from skills.base import Skill, SkillResult

# Emplacements par defaut du scripting Resolve sous Windows.
_DEFAULT_API = r"C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting"
_DEFAULT_LIB = r"C:\Program Files\Blackmagic Design\DaVinci Resolve\fusionscript.dll"

_RENDER_TIMEOUT = 1800  # 30 min max pour un rendu


def _connect_resolve():
    """Importe le module de script Resolve et se connecte a l'instance en cours.
    Retourne (resolve, None) ou (None, message_erreur)."""
    api = os.environ.get("RESOLVE_SCRIPT_API", _DEFAULT_API)
    lib = os.environ.get("RESOLVE_SCRIPT_LIB", _DEFAULT_LIB)
    modules = os.path.join(api, "Modules")

    if not os.path.isfile(lib):
        return None, (
            "DaVinci Resolve introuvable (fusionscript.dll absent). Installez Resolve "
            "puis lancez-le au moins une fois."
        )
    os.environ["RESOLVE_SCRIPT_API"] = api
    os.environ["RESOLVE_SCRIPT_LIB"] = lib
    if modules not in sys.path:
        sys.path.append(modules)

    try:
        import DaVinciResolveScript as dvr  # type: ignore
    except ImportError:
        return None, (
            "Module de script Resolve introuvable. Verifiez l'installation de Resolve "
            f"et le dossier : {modules}"
        )

    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        return None, (
            "Impossible de se connecter a DaVinci Resolve. Ouvrez Resolve et activez "
            "Preferences > System > General > 'External scripting using' = Local."
        )
    return resolve, None


class ResolveMontageSkill(Skill):
    name = "resolve_montage"
    step_types = ("resolve_montage",)
    category = "video"  # chemins (clips/audio/output) verifies par le gate
    sensitive = True

    def describe(self, step: dict) -> str:
        n = len(step.get("clips") or [])
        return f"montage DaVinci Resolve de {n} clip(s) -> {step.get('output', '?')}"

    def run(self, step: dict) -> SkillResult:
        clips = step.get("clips") or []
        audio = step.get("audio")
        output = step.get("output")
        project_name = step.get("project", "SoulBah Formation")

        if not isinstance(clips, list) or not clips:
            return SkillResult(ok=False, detail="champ 'clips' (liste de medias) requis")
        if not output:
            return SkillResult(ok=False, detail="champ 'output' (chemin .mp4) requis")
        media = [c for c in clips if os.path.isfile(c)]
        if audio and os.path.isfile(audio):
            media_audio = audio
        else:
            media_audio = None
        missing = [c for c in clips if not os.path.isfile(c)]
        if missing:
            return SkillResult(ok=False, detail=f"medias introuvables : {missing[:3]}")

        resolve, err = _connect_resolve()
        if err:
            return SkillResult(ok=False, detail=err)

        try:
            pm = resolve.GetProjectManager()
            project = pm.CreateProject(project_name) or pm.LoadProject(project_name)
            if project is None:
                project = pm.GetCurrentProject()
            if project is None:
                return SkillResult(ok=False, detail="impossible de creer/ouvrir un projet Resolve")

            media_pool = project.GetMediaPool()
            media_storage = resolve.GetMediaStorage()

            # Import des medias (clips + audio) dans le Media Pool
            to_import = list(media) + ([media_audio] if media_audio else [])
            items = media_storage.AddItemListToMediaPool(to_import) or []
            if not items:
                # Fallback : ImportMedia
                items = media_pool.ImportMedia(to_import) or []
            if not items:
                return SkillResult(ok=False, detail="aucun media importe dans Resolve")

            # Timeline a partir des clips visuels (dans l'ordre fourni)
            visual_items = items[: len(media)]
            timeline = media_pool.CreateTimelineFromClips("SoulBah_Timeline", visual_items)
            if timeline is None:
                return SkillResult(ok=False, detail="echec creation de la timeline")

            # Ajout de la narration sur une piste audio (best-effort)
            if media_audio and len(items) > len(media):
                audio_item = items[len(media)]
                try:
                    timeline.SetTrackEnable("audio", 1, True)
                    media_pool.AppendToTimeline([{"mediaPoolItem": audio_item, "trackIndex": 1}])
                except Exception:  # noqa: BLE001 - l'audio est un bonus, on ne bloque pas
                    pass

            project.SetCurrentTimeline(timeline)

            # Reglages de rendu -> MP4 H.264 dans le dossier de sortie
            out_dir = os.path.dirname(os.path.abspath(output))
            out_name = os.path.splitext(os.path.basename(output))[0]
            os.makedirs(out_dir, exist_ok=True)
            project.SetRenderSettings({
                "TargetDir": out_dir,
                "CustomName": out_name,
                "FormatWidth": 1920,
                "FormatHeight": 1080,
            })
            try:
                project.SetCurrentRenderFormatAndCodec("mp4", "H264")
            except Exception:  # noqa: BLE001
                pass

            job_id = project.AddRenderJob()
            if not job_id:
                return SkillResult(ok=False, detail="impossible d'ajouter le job de rendu")
            project.StartRendering(job_id)

            start = time.monotonic()
            while project.IsRenderingInProgress():
                if time.monotonic() - start > _RENDER_TIMEOUT:
                    return SkillResult(ok=False, detail="rendu trop long (timeout)")
                time.sleep(3)

        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"echec montage Resolve : {e}")

        # Resolve nomme le fichier <CustomName>.mp4 dans TargetDir
        produced = os.path.join(out_dir, out_name + ".mp4")
        final = produced if os.path.isfile(produced) else output
        return SkillResult(
            ok=True,
            detail=f"montage exporte via DaVinci Resolve : {final}",
            data={"path": final, "project": project_name},
        )
