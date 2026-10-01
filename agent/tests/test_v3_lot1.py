"""V3 LOT 1 — configuration centrale, profil matériel, capacités locales, gate selon le mode."""
from __future__ import annotations

import json
import os
import pathlib
import sys

import pytest

import capabilities
import doctor
import hardware
import permissions
import soulbah_settings as S
from permissions import PermissionGate
from skills import REGISTRY

ROOT = pathlib.Path(__file__).resolve().parents[2]
CASES = json.loads((ROOT / "shared" / "config" / "resolution_cases.json").read_text(encoding="utf-8"))["cases"]
IS_WIN = sys.platform == "win32"


def settings(**env: str) -> dict:
    r = S.resolve(env)
    assert r["errors"] == []
    return r["settings"]


# --- configuration centrale ---------------------------------------------------------
def test_shared_module_is_identical_to_source():
    src = (ROOT / "shared" / "config" / "soulbah_settings.py").read_bytes()
    assert (ROOT / "agent" / "soulbah_settings.py").read_bytes() == src, "copie modifiée : python scripts/sync_shared.py"


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_resolution_cases(case):
    r = S.resolve(case["env"], case["file"])
    if "errors" in case:
        joined = " | ".join(r["errors"])
        for fragment in case["errors"]:
            assert fragment in joined
        return
    assert r["errors"] == []
    for k, v in case.get("expect", {}).items():
        assert r["settings"][k] == v, k
    view = S.public_view(r["settings"])
    for k, v in case.get("derived", {}).items():
        assert view[k] == v, k
    for host, allowed in case.get("hosts", {}).items():
        assert S.host_allowed(r["settings"], host) is allowed, host


def test_config_file_and_env(tmp_path):
    f = tmp_path / "soulbah.config.json"
    f.write_text(json.dumps({"mode": "OFFLINE", "max_agents": 3}), encoding="utf-8")
    r = S.load(None, {"SOULBAH_CONFIG": str(f)})
    assert r["errors"] == [] and r["settings"]["mode"] == "OFFLINE" and r["source"]["file"] == str(f)
    assert S.load(str(tmp_path), {})["settings"]["mode"] == "OFFLINE"  # fichier par défaut à la racine
    assert "introuvable" in S.load(None, {"SOULBAH_CONFIG": str(tmp_path / "absent.json")})["errors"][0]
    f.write_text("{pas du json", encoding="utf-8")
    assert "illisible" in S.load(None, {"SOULBAH_CONFIG": str(f)})["errors"][0]


def test_agent_refuses_to_start_on_invalid_config(monkeypatch, tmp_path):
    import soulbah_agent
    from config import Config

    monkeypatch.setenv("SOULBAH_MODE", "OFLINE")
    cfg = Config(api_url="http://test", agent_key="k", allowed_dirs=[str(tmp_path)])
    executor, code = soulbah_agent.build_executor(cfg)
    assert executor is None and code == 2
    monkeypatch.setenv("SOULBAH_MODE", "offline")
    import network_guard

    try:
        executor, code = soulbah_agent.build_executor(cfg)
        assert code == 0 and executor.gate.settings["mode"] == "OFFLINE"
        assert network_guard.status()["active"], "build_executor installe NetworkGuard"
    finally:
        network_guard.install(S.resolve({})["settings"])  # le processus de test repasse en HYBRID


# --- profil matériel ---------------------------------------------------------------
def test_profile_shape_and_speed():
    p = hardware.profile()
    for key in ("os", "cpu", "memory", "gpus", "accelerators", "disks", "tools", "python_packages", "tts_voices",
                "recommendations"):
        assert key in p, key
    assert p["cpu"]["logical_threads"] and p["memory"]["total_gb"] and p["memory"]["total_gb"] > 0
    assert p["disks"] and p["disks"][0]["free_gb"] is not None
    assert p["recommendations"]["estimate"] is True
    assert p["collect_ms"] < 5000, "le profil doit rester rapide (aucun processus lancé)"
    if IS_WIN:
        assert p["cpu"]["physical_cores"] and p["cpu"]["physical_cores"] <= p["cpu"]["logical_threads"]
        assert p["cpu"]["name"]


def test_summary_has_no_tool_paths():
    p = hardware.profile()
    s = hardware.summary(p)
    dumped = json.dumps(s, ensure_ascii=False)
    for path in (v for v in p["tools"].values() if v):
        assert json.dumps(path, ensure_ascii=False)[1:-1] not in dumped, path
    assert all(isinstance(v, bool) for v in s["tools"].values())


@pytest.mark.skipif(pytest.importorskip("numpy") is None, reason="numpy absent")
def test_bench_measures_positive_values():
    b = hardware.bench(seconds_budget=1.0)
    assert b["matmul_gflops"] > 0 and b["mem_bandwidth_gbps"] > 0


def test_recommendations_follow_the_machine():
    small = {"memory": {"total_gb": 7.9}, "cpu": {"logical_threads": 4}, "gpus": [], "accelerators": {"cuda": False},
             "disks": [{"free_gb": 13.4}], "bench": {"mem_bandwidth_gbps": 13.0}}
    r = hardware.recommendations(small)
    assert r["accelerator"] == "cpu" and r["parallel_inferences"] == 1 and r["suggested_resource_profile"] == "ECO"
    assert 2.0 <= r["max_model_file_gb"] <= 3.0 and r["models_disk_budget_gb"] == 8.4
    assert r["est_tokens_per_s_cpu_by_model_size"]["2.0_go"] == pytest.approx(4.6, abs=0.1)
    big = {"memory": {"total_gb": 64}, "cpu": {"logical_threads": 16}, "accelerators": {"cuda": True},
           "gpus": [{"vendor": "nvidia", "vram_gb": 24, "integrated": False}], "disks": [{"free_gb": 500}]}
    rb = hardware.recommendations(big)
    assert rb["accelerator"] == "cuda" and rb["suggested_resource_profile"] == "MAX" and rb["max_model_file_gb"] >= 19
    assert rb["bandwidth_source"] == "hypothèse"


# --- capacités ---------------------------------------------------------------------
PROFILE = {"tools": {"git": "git", "ffmpeg": "ffmpeg", "vscode": "code"},
           "tts_voices": ["Microsoft Hortense Desktop - French", "Microsoft Julie - French (France)"],
           "sapi5_voices": ["Microsoft Hortense Desktop - French"],
           "python_packages": {"pyautogui": "1", "mss": "1", "cv2": "1", "moviepy": "1"}}


def test_capabilities_by_mode_and_switches():
    hy = capabilities.local_capabilities(settings(), PROFILE)
    assert hy["web.read"]["status"] == "available" and hy["git.remote"]["status"] == "available"
    assert hy["voice.stt"]["status"] == "unavailable"
    if IS_WIN:
        assert hy["voice.tts"]["status"] == "available" and "Hortense" in hy["voice.tts"]["via"]
        assert "Julie" not in hy["voice.tts"]["via"], "voix OneCore inutilisable par speak_text"
    else:
        assert hy["voice.tts"]["status"] == "unavailable"
    assert hy["llm.engine"]["status"] == "unavailable"
    off = capabilities.local_capabilities(settings(SOULBAH_MODE="OFFLINE"), PROFILE)
    assert off["web.read"]["status"] == "disabled" and off["git.remote"]["status"] == "disabled"
    assert off["git.local"]["status"] == "available" and off["video.edit"]["status"] == "available"
    sw = capabilities.local_capabilities(settings(SOULBAH_COMPUTER_CONTROL="false", SOULBAH_RECORDING="false"), PROFILE)
    assert sw["computer.input"]["status"] == "disabled" and sw["video.record"]["status"] == "disabled"
    assert sw["phone.android"]["status"] == "disabled"


def test_registration_payload_is_compact():
    payload = capabilities.registration_payload(settings(SOULBAH_MODE="LOCAL_INTERNET"), hardware.profile())
    assert payload["mode"] == "LOCAL_INTERNET" and "hardware" in payload and "local" in payload
    assert len(json.dumps(payload)) < 16_000


# --- gate selon le mode -------------------------------------------------------------
@pytest.fixture()
def no_console(monkeypatch):
    asked: list[str] = []
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t, should_stop=None: asked.append(p) or "o")
    return asked


def gate(tmp_path, dry=False, **env):
    return PermissionGate("auto", [str(tmp_path)], dry_run=dry, allow_input_control=True, settings=settings(**env))


@pytest.mark.parametrize("dry", [False, True])
def test_offline_refuses_network_steps_even_in_dry_run(tmp_path, no_console, dry):
    g = gate(tmp_path, dry=dry, SOULBAH_MODE="OFFLINE")
    ok, why = g.authorize(REGISTRY["browser_get"], {"type": "browser_get", "url": "https://example.com/"})
    assert not ok and "OFFLINE" in why
    ok, why = g.authorize(REGISTRY["git_push"], {"type": "git_push", "repo": str(tmp_path), "branch": "soulbah/s1/t1"})
    assert not ok and "dépôt distant" in why
    ok, why = g.authorize(REGISTRY["run_command"], {"type": "run_command", "program": "npm", "args": ["ci"], "cwd": str(tmp_path)})
    assert not ok and "npm" in why
    assert no_console == [], "un refus du mode ne demande jamais de confirmation"


def test_offline_allows_declared_local_host(tmp_path, no_console):
    g = gate(tmp_path, SOULBAH_MODE="OFFLINE", SOULBAH_NETWORK_ALLOW_HOSTS="192.168.1.20")
    ok, why = g.authorize(REGISTRY["browser_get"], {"type": "browser_get", "url": "http://192.168.1.20:8080/doc"})
    assert ok, why


def test_switches_refuse_input_and_recording_even_preauthorized(tmp_path, no_console):
    g = gate(tmp_path, SOULBAH_COMPUTER_CONTROL="false", SOULBAH_RECORDING="false")
    ok, why = g.authorize(REGISTRY["click"], {"type": "click", "x": 10, "y": 10})
    assert not ok and "computer_control=false" in why
    ok, why = g.authorize(REGISTRY["start_recording_bg"], {"type": "start_recording_bg", "path": str(tmp_path / "a.mp4")})
    assert not ok and "recording=false" in why
    ok, why = g.authorize(REGISTRY["start_recording"], {"type": "start_recording", "path": str(tmp_path / "a.mp4")})
    assert not ok and "recording=false" in why


def test_hybrid_default_keeps_v2_behaviour(tmp_path, no_console):
    g = PermissionGate("auto", [str(tmp_path)], dry_run=False, allow_input_control=True)
    assert g.settings["mode"] == "HYBRID"
    ok, _ = g.authorize(REGISTRY["browser_get"], {"type": "browser_get", "url": "https://example.com/"})
    assert ok
    ok, _ = g.authorize(REGISTRY["click"], {"type": "click", "x": 10, "y": 10})
    assert ok


# --- doctor --------------------------------------------------------------------------
def test_doctor_json_and_text(capsys, monkeypatch):
    assert doctor.main(["--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["settings"]["mode"] == "HYBRID" and "profile" in out and "voice.stt" in out["capabilities"]
    monkeypatch.setenv("SOULBAH_MODE", "offline")
    assert doctor.main([]) == 0
    text = capsys.readouterr().out
    assert "OFFLINE — 100% LOCAL" in text and "web.read" in text and "désactivé" in text
    monkeypatch.setenv("SOULBAH_MODE", "OFLINE")
    assert doctor.main([]) == 2


def test_doctor_save_writes_profile(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
    assert doctor.main(["--save"]) == 0
    saved = json.loads((tmp_path / "Soulbah" / "hardware.json").read_text(encoding="utf-8"))
    assert {"profile", "capabilities", "settings"} <= set(saved)
    assert os.path.isfile(doctor.profile_path())
