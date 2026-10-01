"""V3 LOT 11 (première brique) — synthèse vocale locale `speak_text` avec les voix Windows : fichier WAV
réel produit hors ligne, texte jamais interprété comme commande, voix introuvable signalée."""
from __future__ import annotations

import sys

import pytest

import soulbah_settings as S
from permissions import PermissionGate
from skills import REGISTRY
from skills.speak import wav_duration_s

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="voix Windows (SAPI)")


def test_speak_to_wav_with_a_french_voice(tmp_path):
    out = tmp_path / "narration.wav"
    res = REGISTRY["speak_text"].run({"type": "speak_text", "text": "Bonjour, Soulbah fonctionne hors ligne.",
                                      "output": str(out)})
    assert res.ok, res.detail
    assert out.read_bytes()[:4] == b"RIFF" and res.data["duration_s"] > 0.5
    assert res.data["engine"] == "sapi" and res.data["voice"]
    assert wav_duration_s(str(out)) == res.data["duration_s"]


def test_text_is_never_executed(tmp_path):
    sentinel = tmp_path / "temoin.txt"
    sentinel.write_text("intact", encoding="utf-8")
    evil = f'"; Remove-Item -LiteralPath "{sentinel}"; $(Remove-Item "{sentinel}") `whoami` \' & del {sentinel}'
    res = REGISTRY["speak_text"].run({"type": "speak_text", "text": evil, "output": str(tmp_path / "a.wav")})
    assert res.ok, res.detail
    assert sentinel.read_text(encoding="utf-8") == "intact"


def test_unknown_voice_is_reported(tmp_path):
    res = REGISTRY["speak_text"].run({"type": "speak_text", "text": "x", "voice": "voix-qui-n-existe-pas",
                                      "output": str(tmp_path / "a.wav")})
    assert not res.ok and "voix introuvable" in res.detail


def test_gate_paths_and_offline(tmp_path):
    gate = PermissionGate("auto", [str(tmp_path)], dry_run=False, settings=S.resolve({"SOULBAH_MODE": "OFFLINE"})["settings"])
    ok, why = gate.authorize(REGISTRY["speak_text"], {"type": "speak_text", "text": "x", "output": str(tmp_path / "a.wav")})
    assert ok, why  # voix locale : permise hors ligne
    ok, why = gate.authorize(REGISTRY["speak_text"], {"type": "speak_text", "text": "x", "output": "C:\\Windows\\a.wav"})
    assert not ok
    ok, why = gate.authorize(REGISTRY["speak_text"], {"type": "speak_text", "text": "x", "output": str(tmp_path / "a.mp3")})
    assert not ok
