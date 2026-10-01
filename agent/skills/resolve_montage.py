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

Garanties (T7, T25) :
  - aucun faux succes : le statut du job de rendu doit etre « Complete », le fichier
    rendu doit exister, etre non vide, recent, et lisible par une sonde video ;
  - idempotent : timeline et nom de rendu uniques par execution, rendu dans un
    fichier temporaire puis remplacement atomique de la sortie ; le projet est
    recharge s'il existe deja ; le job de rendu est supprime apres usage ;
  - narration : posee sur une piste audio dediee au debut de la timeline ; toute
    erreur fait ECHOUER l'etape (plus d'erreur avalee). Un fichier audio demande
    mais introuvable est une erreur.

NON VALIDE SUR MATERIEL REEL dans ce projet (Resolve n'etait pas installe a l'ecriture) :
a valider/ajuster sur le poste apres installation.
"""
from __future__ import annotations

import os
import sys
import time
import uuid

from skills.base import PathCheck, Skill, SkillResult, current_token
from skills.media_probe import probe_video

# Emplacements par defaut du scripting Resolve sous Windows.
_DEFAULT_API = r"C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting"
_DEFAULT_LIB = r"C:\Program Files\Blackmagic Design\DaVinci Resolve\fusionscript.dll"

_RENDER_TIMEOUT = 1800  # 30 min max pour un rendu
_MAX_CLIPS = 200  # manifeste resolve_montage : clips.max_items (= borne des tableaux côté serveur)
_POLL_SECONDS = 3.0


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


def _add_narration(timeline, media_pool, audio_item) -> str | None:
    """Pose la narration sur une piste audio dediee, au debut de la timeline.
    Retourne un message d'erreur ou None."""
    try:
        track = None
        add_track = getattr(timeline, "AddTrack", None)
        if callable(add_track) and add_track("audio", "stereo"):
            track = int(timeline.GetTrackCount("audio"))
        if not track:
            track = max(1, int(timeline.GetTrackCount("audio") or 1))
        clip_info = {
            "mediaPoolItem": audio_item,
            "mediaType": 2,  # audio seul
            "trackIndex": track,
            "recordFrame": timeline.GetStartFrame(),  # synchronisee avec le debut de la video
        }
        appended = media_pool.AppendToTimeline([clip_info])
    except Exception as e:  # noqa: BLE001
        return f"erreur de l'API Resolve : {e}"
    if not appended:
        return "AppendToTimeline a echoue (narration non posee)"
    return None


def _cleanup_job(project, job_id) -> None:
    try:
        project.DeleteRenderJob(job_id)
    except Exception:  # noqa: BLE001 - nettoyage best-effort
        pass


class ResolveMontageSkill(Skill):
    name = "resolve_montage"
    step_types = ("resolve_montage",)
    category = "video"  # chemins (clips/audio/output) verifies par le gate
    sensitive = True
    timeout_s = _RENDER_TIMEOUT + 120.0

    def describe(self, step: dict) -> str:
        n = len(step.get("clips") or [])
        return f"montage DaVinci Resolve de {n} clip(s) -> {step.get('output', '?')}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        clips = step.get("clips")
        if not isinstance(clips, list) or not clips or not all(isinstance(c, str) and c for c in clips):
            return "champ 'clips' (liste de medias) requis"
        if len(clips) > _MAX_CLIPS:
            return f"trop de medias (max {_MAX_CLIPS})"
        output = step.get("output")
        if not isinstance(output, str) or not output.lower().endswith(".mp4"):
            return "champ 'output' invalide (fichier .mp4 attendu)"
        project = step.get("project")
        if project is not None and (not isinstance(project, str) or len(project) > 100):
            return "champ 'project' invalide"
        audio = step.get("audio")
        if audio is not None and audio != "" and not isinstance(audio, str):
            return "champ 'audio' invalide"
        return None

    def run(self, step: dict) -> SkillResult:
        clips = step.get("clips") or []
        audio = step.get("audio") or None
        output = step.get("output")
        project_name = str(step.get("project") or "SoulBah Formation")[:100]

        if not isinstance(clips, list) or not clips:
            return SkillResult(ok=False, detail="champ 'clips' (liste de medias) requis")
        if not isinstance(output, str) or not output.lower().endswith(".mp4"):
            return SkillResult(ok=False, detail="champ 'output' (chemin .mp4) requis")
        if not all(isinstance(c, str) for c in clips):
            return SkillResult(ok=False, detail="champ 'clips' invalide (liste de chemins)")
        if audio is not None and not isinstance(audio, str):
            return SkillResult(ok=False, detail="champ 'audio' invalide")
        missing = [c for c in clips if not os.path.isfile(c)]
        if missing:
            return SkillResult(ok=False, detail=f"medias introuvables : {missing[:3]}")
        if audio and not os.path.isfile(audio):
            return SkillResult(ok=False, detail=f"fichier audio (narration) introuvable : {audio}")

        out_dir = os.path.dirname(os.path.abspath(output))
        if not os.path.isdir(out_dir):
            return SkillResult(ok=False, detail=f"dossier de sortie introuvable : {out_dir}")
        out_name = os.path.splitext(os.path.basename(output))[0]
        stamp = time.strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:8]  # unique par exécution
        temp_name = f"{out_name}.soulbah-render-{stamp}"
        produced = os.path.join(out_dir, temp_name + ".mp4")

        resolve, err = _connect_resolve()
        if err:
            return SkillResult(ok=False, detail=err)

        token = current_token()
        timeline_name = f"SoulBah_{stamp}"
        project = None
        job_id = None
        render_started = time.time()
        try:
            pm = resolve.GetProjectManager()
            # Idempotent : on recharge le projet s'il existe deja.
            project = pm.LoadProject(project_name) or pm.CreateProject(project_name)
            if project is None:
                project = pm.GetCurrentProject()
            if project is None:
                return SkillResult(ok=False, detail="impossible de creer/ouvrir un projet Resolve")

            media_pool = project.GetMediaPool()
            media_storage = resolve.GetMediaStorage()

            # Import des medias (clips + audio) dans le Media Pool
            to_import = list(clips) + ([audio] if audio else [])
            items = media_storage.AddItemListToMediaPool(to_import) or []
            if not items:
                items = media_pool.ImportMedia(to_import) or []
            if len(items) != len(to_import):
                return SkillResult(ok=False, detail=(
                    f"import incomplet dans Resolve ({len(items)}/{len(to_import)} medias)"))

            # Timeline unique par execution (un nom deja pris ferait echouer un 2e run).
            visual_items = items[: len(clips)]
            timeline = media_pool.CreateTimelineFromClips(timeline_name, visual_items)
            if timeline is None:
                return SkillResult(ok=False, detail="echec creation de la timeline")
            project.SetCurrentTimeline(timeline)

            if audio:
                narration_err = _add_narration(timeline, media_pool, items[len(clips)])
                if narration_err:
                    return SkillResult(ok=False, detail=f"narration non ajoutee : {narration_err}")

            # Reglages de rendu -> MP4 H.264, dans un fichier temporaire du dossier de sortie
            if not project.SetRenderSettings({
                "TargetDir": out_dir,
                "CustomName": temp_name,
                "FormatWidth": 1920,
                "FormatHeight": 1080,
            }):
                return SkillResult(ok=False, detail="reglages de rendu refuses par Resolve")
            if not project.SetCurrentRenderFormatAndCodec("mp4", "H264"):
                return SkillResult(ok=False, detail="format de rendu MP4/H.264 indisponible dans Resolve")

            job_id = project.AddRenderJob()
            if not job_id:
                return SkillResult(ok=False, detail="impossible d'ajouter le job de rendu")
            render_started = time.time()
            if project.StartRendering(job_id) is False:
                return SkillResult(ok=False, detail="Resolve a refuse de demarrer le rendu")

            start = time.monotonic()
            while project.IsRenderingInProgress():
                if time.monotonic() - start > _RENDER_TIMEOUT:
                    try:
                        project.StopRendering()
                    except Exception:  # noqa: BLE001
                        pass
                    return SkillResult(ok=False, detail="rendu trop long (timeout)")
                if token.wait(_POLL_SECONDS):
                    try:
                        project.StopRendering()
                    except Exception:  # noqa: BLE001
                        pass
                    return SkillResult(ok=False, detail="rendu interrompu (arrêt demandé)")

            status = {}
            try:
                status = project.GetRenderJobStatus(job_id) or {}
            except Exception:  # noqa: BLE001
                status = {}
            job_status = str(status.get("JobStatus", "")) if isinstance(status, dict) else ""
            if job_status and job_status.lower() not in ("complete", "completed"):
                return SkillResult(ok=False, detail=f"rendu non termine (statut Resolve : {job_status})")

        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"echec montage Resolve : {e}")
        finally:
            if project is not None and job_id:
                _cleanup_job(project, job_id)

        # Verification du fichier rendu : present, recent, non vide, decodable.
        if not os.path.isfile(produced):
            return SkillResult(ok=False, detail=f"fichier rendu introuvable : {produced}")
        if os.path.getmtime(produced) < render_started - 2:
            return SkillResult(ok=False, detail=f"fichier rendu perime (anterieur au rendu) : {produced}")
        ok, info = probe_video(produced)
        if not ok:
            return SkillResult(ok=False, detail=f"export Resolve invalide : {info}")
        try:
            os.replace(produced, output)  # remplacement atomique : re-execution sans doublon
        except OSError as e:
            return SkillResult(ok=False, detail=f"impossible de placer le rendu en {output} : {e}")
        return SkillResult(
            ok=True,
            detail=f"montage exporte et verifie via DaVinci Resolve : {output}",
            data={"path": output, "project": project_name, "timeline": timeline_name,
                  "narration": bool(audio), "probe": info},
        )
