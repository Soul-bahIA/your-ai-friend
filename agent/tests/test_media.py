"""LOT 1 — médias : cadence réelle de l'enregistrement (T24), démarrage vérifié (C18),
audio conservé (T25), Resolve sans faux succès et idempotent (T7), sonde vidéo."""
from __future__ import annotations

import os
import sys
import threading
import types

import pytest

from skills import edit_video as ev
from skills import record_bg
from skills import resolve_montage as rm
from skills.media_probe import probe_video
from skills.recording import capture_loop, open_writer, recording_key


class _Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


# --- T24 : cadence calée sur le temps réel -------------------------------------------------------
@pytest.mark.parametrize("grab_cost,fps", [(0.08, 30), (0.25, 10), (0.001, 10), (0.034, 30)])
def test_video_duration_matches_real_time(grab_cost, fps):
    clock = _Clock()
    frames = []

    def grab():
        clock.t += grab_cost  # capture lente (grand écran, machine chargée)
        return "img"

    def wait(d):
        clock.t += d

    stats = capture_loop(grab, frames.append, fps, lambda: False, 10.0, clock=clock, wait=wait)
    assert abs(stats["video_duration_s"] - stats["duration_s"]) <= 0.05 * stats["duration_s"]
    assert stats["frames"] == len(frames)
    assert stats["capture_fps"] <= fps + 0.5
    if grab_cost * fps > 1:  # capture plus lente que demandé : images dupliquées, pas de vidéo accélérée
        assert stats["unique_frames"] < stats["frames"]


def test_capture_loop_stops_on_request():
    clock = _Clock()
    n = {"grabs": 0}

    def grab():
        n["grabs"] += 1
        clock.t += 0.01
        return n["grabs"]

    stats = capture_loop(grab, lambda f: None, 10, lambda: n["grabs"] >= 5, 60.0, clock=clock,
                         wait=lambda d: setattr(clock, "t", clock.t + d))
    assert n["grabs"] == 5 and stats["duration_s"] < 1


@pytest.mark.skipif(sys.platform != "win32", reason="normalisation de casse propre à Windows")
def test_recording_key_normalized(tmp_path):
    a = recording_key(str(tmp_path / "Demo.MP4"))
    b = recording_key(str(tmp_path).replace("\\", "/").upper() + "/demo.mp4")
    assert a == b


class _FakeWriter:
    def __init__(self, ok):
        self.ok = ok

    def isOpened(self):
        return self.ok

    def release(self):
        pass


def test_open_writer_prefers_h264_then_falls_back(tmp_path):
    tried = []

    def make(available):
        def writer(path, fourcc, fps, size):
            tried.append(fourcc)
            return _FakeWriter(fourcc in available)
        return types.SimpleNamespace(VideoWriter=writer, VideoWriter_fourcc=lambda *c: "".join(c))

    w, codec, warning = open_writer(make({"avc1", "mp4v"}), str(tmp_path / "a.mp4"), 10, (4, 4))
    assert codec == "avc1" and warning is None
    tried.clear()
    w, codec, warning = open_writer(make({"mp4v"}), str(tmp_path / "a.mp4"), 10, (4, 4))
    assert codec == "mp4v" and "H.264" in warning and tried[0] == "avc1"
    assert open_writer(make(set()), str(tmp_path / "a.mp4"), 10, (4, 4)) == (None, None, None)


# --- C18 : start_recording_bg n'annonce pas un faux démarrage ----------------------------------------
@pytest.fixture()
def clean_active():
    record_bg.stop_all("test")
    yield
    record_bg.stop_all("test")


def test_start_bg_invalid_dir_fails(tmp_path, clean_active):
    res = record_bg.StartRecordingBgSkill().run({"path": str(tmp_path / "absent" / "x.mp4")})
    assert not res.ok and "introuvable" in res.detail and not record_bg._ACTIVE


def test_start_bg_writer_failure_reported(tmp_path, monkeypatch, clean_active):
    def failing(path, fps, should_stop, max_seconds, monitor=1, wait=None, on_ready=None):
        on_ready("impossible de créer le fichier vidéo")
        raise RuntimeError("impossible de créer le fichier vidéo")

    monkeypatch.setattr(record_bg, "record_to_file", failing)
    res = record_bg.StartRecordingBgSkill().run({"path": str(tmp_path / "x.mp4")})
    assert not res.ok and "impossible de créer" in res.detail and not record_bg._ACTIVE


def _fake_recorder(path, fps, should_stop, max_seconds, monitor=1, wait=None, on_ready=None):
    with open(path, "wb") as f:
        f.write(b"video")
    on_ready(None)
    while not should_stop():
        wait(0.02)
    return {"frames": 20, "unique_frames": 20, "duration_s": 2.0, "video_duration_s": 2.0,
            "capture_fps": 10.0, "fps": fps, "codec": "mp4v", "warning": "repli mp4v"}


def test_start_stop_bg_with_normalized_path(tmp_path, monkeypatch, clean_active):
    monkeypatch.setattr(record_bg, "record_to_file", _fake_recorder)
    path = tmp_path / "Demo.mp4"
    res = record_bg.StartRecordingBgSkill().run({"path": str(path), "fps": 10})
    assert res.ok, res.detail
    again = record_bg.StartRecordingBgSkill().run({"path": str(path).upper() if sys.platform == "win32" else str(path)})
    assert not again.ok and "déjà en cours" in again.detail
    other = str(path).replace("\\", "/") if sys.platform == "win32" else str(path)
    stop = record_bg.StopRecordingBgSkill().run({"path": other})
    assert stop.ok and stop.data["frames"] == 20 and "repli mp4v" in stop.detail
    assert not record_bg.StopRecordingBgSkill().run({"path": str(path)}).ok  # déjà arrêté


def test_stop_bg_missing_output_fails(tmp_path, monkeypatch, clean_active):
    def no_file(path, fps, should_stop, max_seconds, monitor=1, wait=None, on_ready=None):
        on_ready(None)
        while not should_stop():
            wait(0.02)
        return {"frames": 0}

    monkeypatch.setattr(record_bg, "record_to_file", no_file)
    p = str(tmp_path / "x.mp4")
    assert record_bg.StartRecordingBgSkill().run({"path": p}).ok
    res = record_bg.StopRecordingBgSkill().run({"path": p})
    assert not res.ok and "absent ou vide" in res.detail


def test_monitor_validation():
    v = record_bg.StartRecordingBgSkill().validate
    assert v({"path": "x.mp4", "monitor": "1"}, None)
    assert v({"path": "x.mp4", "monitor": True}, None)
    assert v({"path": "x.mp4", "monitor": 0}, None) is None


def test_real_screen_recording_duration(tmp_path):
    """Enregistrement réel de 2 s : durée vidéo ≈ temps réel (±5 %)."""
    pytest.importorskip("cv2")
    mss = pytest.importorskip("mss")
    try:
        with mss.mss() as sct:
            sct.grab(sct.monitors[1])
    except Exception as e:  # noqa: BLE001 - pas d'écran (session sans bureau)
        pytest.skip(f"capture d'écran indisponible : {e}")
    from skills.recording import record_to_file

    stop = threading.Event()
    path = str(tmp_path / "real.mp4")
    stats = record_to_file(path, 10, stop.is_set, 2.0, wait=stop.wait)
    assert abs(stats["video_duration_s"] - stats["duration_s"]) <= 0.05 * stats["duration_s"] + 0.1
    ok, info = probe_video(path)
    assert ok, info
    assert abs(info["frames"] - stats["frames"]) <= 1


# --- Sonde vidéo -------------------------------------------------------------------------------------------
def test_probe_video(tmp_path):
    cv2 = pytest.importorskip("cv2")
    np = pytest.importorskip("numpy")
    path = str(tmp_path / "t.mp4")
    w = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"mp4v"), 10, (32, 24))
    assert w.isOpened()
    for i in range(10):
        w.write(np.full((24, 32, 3), i * 20, dtype=np.uint8))
    w.release()
    ok, info = probe_video(path)
    assert ok and info["frames"] == 10 and abs(info["duration_s"] - 1.0) < 0.05
    (tmp_path / "bad.mp4").write_bytes(b"ceci n'est pas une video" * 10)
    assert not probe_video(str(tmp_path / "bad.mp4"))[0]
    (tmp_path / "empty.mp4").write_bytes(b"")
    assert "vide" in probe_video(str(tmp_path / "empty.mp4"))[1]
    assert not probe_video(str(tmp_path / "missing.mp4"))[0]


# --- T25 : edit_video conserve l'audio -----------------------------------------------------------------------
@pytest.fixture()
def fake_moviepy(monkeypatch):
    rec = {}

    class Clip:
        def __init__(self, path):
            self.audio = object() if "son" in os.path.basename(path) else None
            self.size = (64, 48)

        def close(self):
            pass

    class Final:
        def write_videofile(self, output, **kw):
            rec.update(kw)
            with open(output, "wb") as f:
                f.write(b"mp4")

        def close(self):
            pass

    editor = types.SimpleNamespace(VideoFileClip=Clip, concatenate_videoclips=lambda seq, method=None: Final())
    monkeypatch.setitem(sys.modules, "moviepy", types.SimpleNamespace(editor=editor))
    monkeypatch.setitem(sys.modules, "moviepy.editor", editor)
    monkeypatch.setattr(ev, "probe_video", lambda p: (True, {"frames": 1}))
    return rec


def test_edit_video_keeps_audio(tmp_path, fake_moviepy):
    a, b = tmp_path / "a_son.mp4", tmp_path / "b.mp4"
    a.write_bytes(b"x")
    b.write_bytes(b"x")
    res = ev.EditVideoSkill().run({"clips": [str(a), str(b)], "output": str(tmp_path / "out.mp4")})
    assert res.ok and res.data["audio"] is True
    assert fake_moviepy["audio"] is True and fake_moviepy["audio_codec"] == "aac"
    assert os.path.dirname(fake_moviepy["temp_audiofile"]) == str(tmp_path)


def test_edit_video_without_audio(tmp_path, fake_moviepy):
    b = tmp_path / "b.mp4"
    b.write_bytes(b"x")
    res = ev.EditVideoSkill().run({"clips": [str(b)], "output": str(tmp_path / "out.mp4")})
    assert res.ok and fake_moviepy["audio"] is False and "audio_codec" not in fake_moviepy


def test_edit_video_invalid_export_fails(tmp_path, fake_moviepy, monkeypatch):
    b = tmp_path / "b.mp4"
    b.write_bytes(b"x")
    monkeypatch.setattr(ev, "probe_video", lambda p: (False, "fichier vidéo illisible"))
    res = ev.EditVideoSkill().run({"clips": [str(b)], "output": str(tmp_path / "out.mp4")})
    assert not res.ok and "illisible" in res.detail


# --- T7 / T25 : Resolve ----------------------------------------------------------------------------------------
class _Server:
    def __init__(self):
        self.produce = "ok"
        self.job_status = "Complete"
        self.append_fails = False
        self.projects = {}
        self.timelines = set()
        self.appended = []
        self.deleted = []


class _Timeline:
    def __init__(self):
        self.tracks = 1

    def AddTrack(self, kind, sub):
        self.tracks += 1
        return True

    def GetTrackCount(self, kind):
        return self.tracks

    def GetStartFrame(self):
        return 86400


class _Pool:
    def __init__(self, srv):
        self.srv = srv

    def ImportMedia(self, paths):
        return [f"item:{p}" for p in paths]

    def CreateTimelineFromClips(self, name, items):
        if name in self.srv.timelines:  # Resolve refuse un nom de timeline déjà pris
            return None
        self.srv.timelines.add(name)
        return _Timeline()

    def AppendToTimeline(self, infos):
        self.srv.appended.append(infos)
        return [] if self.srv.append_fails else ["ok"]


class _Project:
    def __init__(self, srv):
        self.srv = srv
        self.pool = _Pool(srv)
        self.settings = {}

    def GetMediaPool(self):
        return self.pool

    def SetCurrentTimeline(self, tl):
        return True

    def SetRenderSettings(self, s):
        self.settings = s
        return True

    def SetCurrentRenderFormatAndCodec(self, fmt, codec):
        return True

    def AddRenderJob(self):
        return "job-1"

    def StartRendering(self, job):
        target = os.path.join(self.settings["TargetDir"], self.settings["CustomName"] + ".mp4")
        if self.srv.produce in ("ok", "garbage"):
            with open(target, "wb") as f:
                f.write(b"rendu" if self.srv.produce == "ok" else b"pas une video")
        elif self.srv.produce == "empty":
            open(target, "wb").close()
        return True

    def IsRenderingInProgress(self):
        return False

    def GetRenderJobStatus(self, job):
        return {"JobStatus": self.srv.job_status, "CompletionPercentage": 100}

    def DeleteRenderJob(self, job):
        self.srv.deleted.append(job)
        return True

    def StopRendering(self):
        pass


class _PM:
    def __init__(self, srv):
        self.srv = srv

    def LoadProject(self, name):
        return self.srv.projects.get(name)

    def CreateProject(self, name):
        if name in self.srv.projects:
            return None
        self.srv.projects[name] = _Project(self.srv)
        return self.srv.projects[name]

    def GetCurrentProject(self):
        return None


class _Resolve:
    def __init__(self, srv):
        self.pm = _PM(srv)

    def GetProjectManager(self):
        return self.pm

    def GetMediaStorage(self):
        return types.SimpleNamespace(AddItemListToMediaPool=lambda paths: [f"item:{p}" for p in paths])


@pytest.fixture()
def resolve_env(tmp_path, monkeypatch):
    srv = _Server()
    monkeypatch.setattr(rm, "_connect_resolve", lambda: (_Resolve(srv), None))
    monkeypatch.setattr(rm, "probe_video", lambda p: (True, {"frames": 25}) if os.path.getsize(p) else (False, "vide"))
    clip = tmp_path / "intro.png"
    clip.write_bytes(b"png")
    audio = tmp_path / "narration.mp3"
    audio.write_bytes(b"mp3")
    out = tmp_path / "out" / "final.mp4"
    out.parent.mkdir()
    step = {"type": "resolve_montage", "clips": [str(clip)], "audio": str(audio), "output": str(out)}
    return srv, step, out


def test_resolve_success_verified_and_idempotent(resolve_env):
    srv, step, out = resolve_env
    for _ in range(2):  # 2e exécution : ni timeline en double, ni faux succès
        res = rm.ResolveMontageSkill().run(step)
        assert res.ok, res.detail
        assert out.is_file() and out.read_bytes() == b"rendu"
    assert len(srv.timelines) == 2 and srv.deleted == ["job-1", "job-1"]
    assert [f.name for f in out.parent.iterdir()] == ["final.mp4"]  # aucun fichier temporaire laissé
    info = srv.appended[0][0]
    assert info["mediaType"] == 2 and info["recordFrame"] == 86400 and info["trackIndex"] == 2


@pytest.mark.parametrize("produce,expected", [("none", "introuvable"), ("empty", "invalide")])
def test_resolve_no_fake_success(resolve_env, produce, expected):
    srv, step, out = resolve_env
    srv.produce = produce
    res = rm.ResolveMontageSkill().run(step)
    assert not res.ok and expected in res.detail and not out.exists()


def test_resolve_unreadable_render_fails(resolve_env, monkeypatch):
    pytest.importorskip("cv2")
    srv, step, out = resolve_env
    srv.produce = "garbage"
    monkeypatch.setattr(rm, "probe_video", probe_video)  # vraie sonde
    res = rm.ResolveMontageSkill().run(step)
    assert not res.ok and "invalide" in res.detail and not out.exists()


def test_resolve_failed_job_status(resolve_env):
    srv, step, out = resolve_env
    srv.job_status = "Failed"
    res = rm.ResolveMontageSkill().run(step)
    assert not res.ok and "Failed" in res.detail


def test_resolve_narration_error_not_swallowed(resolve_env):
    srv, step, out = resolve_env
    srv.append_fails = True
    res = rm.ResolveMontageSkill().run(step)
    assert not res.ok and "narration" in res.detail


def test_resolve_missing_audio_is_error(resolve_env, tmp_path):
    srv, step, out = resolve_env
    res = rm.ResolveMontageSkill().run(dict(step, audio=str(tmp_path / "absent.mp3")))
    assert not res.ok and "audio" in res.detail and not srv.timelines


def test_edit_video_real_moviepy_keeps_audio(tmp_path):
    """Montage réel (moviepy + ffmpeg) : un clip avec une piste son → la sortie a du son."""
    np = pytest.importorskip("numpy")
    ev._pillow_compat()
    editor = pytest.importorskip("moviepy.editor")
    src = str(tmp_path / "source_son.mp4")
    tone = editor.AudioClip(lambda t: np.array([np.sin(440 * 2 * np.pi * t)] * 2).T, duration=1.0, fps=22050)
    clip = editor.ColorClip((64, 48), color=(200, 0, 0), duration=1.0).set_audio(tone)
    clip.write_videofile(src, fps=10, codec="libx264", audio_codec="aac", logger=None,
                         temp_audiofile=str(tmp_path / "tmp-audio.m4a"))
    clip.close()
    out = str(tmp_path / "monte.mp4")
    res = ev.EditVideoSkill().run({"clips": [src, src], "output": out, "title": "Démo"})
    assert res.ok and res.data["audio"] is True, res.detail
    result = editor.VideoFileClip(out)
    try:
        assert result.audio is not None and result.duration >= 3.5  # titre 2 s + 2 × 1 s
    finally:
        result.close()
