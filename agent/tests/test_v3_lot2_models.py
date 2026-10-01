"""V3 LOT 2 — couche de modèles locaux, sans aucun téléchargement réel : registre, résolution
(session simulée), installeur (accord, licence, empreinte, reprise, disque, OFFLINE), moteur
(archive ZIP sûre), serveur partagé (faux llama-server), banc d'essai, commande."""
from __future__ import annotations

import hashlib
import http.server
import io
import json
import os
import socket
import sys
import threading
import zipfile

import pytest

import soulbah_settings as S
import soulbah_models
from local_models import bench, catalog, installer, registry, server

HERE = os.path.dirname(os.path.abspath(__file__))
HYBRID = S.resolve({})["settings"]
OFFLINE = S.resolve({"SOULBAH_MODE": "OFFLINE"})["settings"]


@pytest.fixture(autouse=True)
def model_dirs(tmp_path, monkeypatch):
    monkeypatch.setenv("SOULBAH_MODELS_DIR", str(tmp_path / "models"))
    monkeypatch.setenv("SOULBAH_ENGINES_DIR", str(tmp_path / "engines"))
    yield
    server.stop()


# --- serveur HTTP de fichiers avec Range (source simulée) ----------------------------
class FileSource:
    def __init__(self, blobs: dict[str, bytes]):
        self.blobs = blobs
        self.requests: list[dict] = []
        source = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_a):
                pass

            def do_GET(self):  # noqa: N802
                body = source.blobs.get(self.path)
                source.requests.append({"path": self.path, "range": self.headers.get("Range")})
                if body is None:
                    self.send_response(404)
                    self.end_headers()
                    return
                rng = self.headers.get("Range")
                start = int(rng.split("=")[1].split("-")[0]) if rng else 0
                self.send_response(206 if rng else 200)
                self.send_header("Content-Length", str(len(body) - start))
                self.end_headers()
                self.wfile.write(body[start:])

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


@pytest.fixture()
def source():
    blob = b"GGUF" + os.urandom(200_000)
    s = FileSource({"/m.gguf": blob})
    s.blob = blob
    yield s
    s.close()


def resolved(src, **over):
    r = {"kind": "model", "id": "petit-modele", "name": "Petit modèle", "family": "test", "version": "1",
         "quantization": "Q4", "roles": ["chat", "planning"], "context_max": 4096, "file": "m.gguf",
         "url": f"{src.base}/m.gguf", "size_bytes": len(src.blob), "sha256": hashlib.sha256(src.blob).hexdigest(),
         "license": "apache-2.0", "expected_license": "apache-2.0", "revision": "a" * 40, "source_page": "https://exemple",
         "repo": "test/petit", "gated": False, "capabilities": {"json_schema": True}}
    r.update(over)
    return r


# --- registre ------------------------------------------------------------------------
def test_registry_upsert_load_remove_and_role_order(tmp_path):
    assert registry.load() == {"version": 1, "models": {}, "engines": {}}
    big = tmp_path / "big.gguf"
    big.write_bytes(b"x" * 300)
    small = tmp_path / "small.gguf"
    small.write_bytes(b"x" * 100)
    registry.upsert("models", {"id": "grand", "roles": ["chat"], "path": str(big), "size_bytes": 300, "status": "installed"})
    registry.upsert("models", {"id": "petit", "roles": ["chat"], "path": str(small), "size_bytes": 100, "status": "verified"})
    registry.upsert("models", {"id": "casse", "roles": ["chat"], "path": str(small), "size_bytes": 50, "status": "failed"})
    registry.upsert("models", {"id": "absent", "roles": ["chat"], "path": str(tmp_path / "x.gguf"), "size_bytes": 900, "status": "installed"})
    assert [m["id"] for m in registry.models_for_role("chat")] == ["grand", "petit"]  # repli Large → Small
    assert registry.remove("models", "casse") and not registry.remove("models", "casse")
    with pytest.raises(ValueError):
        registry.upsert("models", {"id": "../évasion"})
    assert json.load(open(registry.registry_path(), encoding="utf-8"))["version"] == 1
    assert 1.3 < registry.ram_estimate_gb(1024 ** 3, 4096, 1) < 1.7


# --- résolution (session simulée, aucun réseau) ---------------------------------------
class FakeSession:
    def __init__(self, routes: dict[str, object]):
        self.routes = routes

    def get(self, url, **_kw):
        body = self.routes.get(url)

        class R:
            status_code = 200 if body is not None else 404

            def json(self_inner):
                return body
        return R()


def test_resolve_model_pins_revision_and_reads_license():
    spec = catalog.MODELS["qwen2.5-1.5b-instruct-q4_k_m"]
    rev = "f" * 40
    sha = "b" * 64
    sess = FakeSession({
        f"{catalog.HF_API}/{spec['repo']}": {"sha": rev, "cardData": {"license": "apache-2.0"}},
        f"{catalog.HF_API}/{spec['repo']}/tree/{rev}": [{"path": spec["file"], "size": 10, "lfs": {"oid": sha, "size": 1_100_000_000}}],
    })
    r = catalog.resolve_model("qwen2.5-1.5b-instruct-q4_k_m", sess)
    assert r["revision"] == rev and r["sha256"] == sha and r["size_bytes"] == 1_100_000_000
    assert r["license"] == "apache-2.0" and f"/resolve/{rev}/" in r["url"]
    sess.routes[f"{catalog.HF_API}/{spec['repo']}/tree/{rev}"] = [{"path": spec["file"], "size": 10}]
    with pytest.raises(catalog.ResolveError, match="empreinte"):
        catalog.resolve_model("qwen2.5-1.5b-instruct-q4_k_m", sess)
    with pytest.raises(catalog.ResolveError):
        catalog.resolve_model("inconnu")


def test_resolve_engine_uses_newest_release_with_the_asset():
    spec = catalog.ENGINES["llama.cpp-win-cpu-x64"]
    sess = FakeSession({
        f"{catalog.GITHUB_API}/{spec['repo']}/releases?per_page=15": [
            {"tag_name": "v0.5.0", "assets": [{"name": "source.tar.gz"}]},
            {"tag_name": "b11325", "html_url": "https://github.com/x", "assets": [
                {"name": "llama-b11325-bin-win-cpu-x64.zip", "size": 19_000_000, "digest": "sha256:" + "c" * 64,
                 "browser_download_url": "https://github.com/x.zip"}]},
        ],
        f"{catalog.GITHUB_API}/{spec['repo']}": {"license": {"spdx_id": "MIT"}},
    })
    r = catalog.resolve_engine("llama.cpp-win-cpu-x64", sess)
    assert r["release"] == "b11325" and r["sha256"] == "c" * 64 and r["license"] == "MIT"


# --- installeur ----------------------------------------------------------------------
def test_install_requires_explicit_consent_and_license(source):
    with pytest.raises(installer.InstallError, match="--yes"):
        installer.install_model(resolved(source), HYBRID)
    with pytest.raises(installer.InstallError, match="licence non acceptée"):
        installer.install_model(resolved(source), HYBRID, yes=True)
    assert source.requests == [], "aucun octet téléchargé sans accord"


def test_install_refused_offline_and_without_published_hash(source):
    with pytest.raises(installer.InstallError, match="OFFLINE"):
        installer.install_model(resolved(source), OFFLINE, yes=True, accept_license=True)
    with pytest.raises(installer.InstallError, match="empreinte"):
        installer.install_model(resolved(source, sha256=None), HYBRID, yes=True, accept_license=True)
    with pytest.raises(installer.InstallError, match="accès restreint"):
        installer.install_model(resolved(source, gated=True), HYBRID, yes=True, accept_license=True)
    assert source.requests == []


def test_install_verifies_hash_registers_and_does_not_redownload(source):
    entry = installer.install_model(resolved(source), HYBRID, yes=True, accept_license=True)
    assert os.path.isfile(entry["path"]) and entry["sha256"] == hashlib.sha256(source.blob).hexdigest()
    assert entry["license"]["id"] == "apache-2.0" and entry["license"]["accepted_at"]
    assert entry["status"] == "installed" and entry["source"]["revision"] == "a" * 40
    n = len(source.requests)
    installer.install_model(resolved(source), HYBRID, yes=True, accept_license=True)
    assert len(source.requests) == n, "fichier déjà présent à la bonne empreinte : pas de nouveau téléchargement"


def test_install_rejects_wrong_hash_and_removes_partial(source):
    with pytest.raises(installer.InstallError, match="empreinte incorrecte"):
        installer.install_model(resolved(source, sha256="0" * 64), HYBRID, yes=True, accept_license=True)
    target = os.path.join(registry.base_dir(), "petit-modele", "m.gguf")
    assert not os.path.exists(target) and not os.path.exists(target + ".part")
    assert registry.load()["models"] == {}


def test_install_resumes_from_partial_file(source):
    target = os.path.join(registry.base_dir(), "petit-modele", "m.gguf")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target + ".part", "wb") as f:
        f.write(source.blob[:50_000])
    installer.install_model(resolved(source), HYBRID, yes=True, accept_license=True)
    assert source.requests[-1]["range"] == "bytes=50000-"
    assert hashlib.sha256(open(target, "rb").read()).hexdigest() == hashlib.sha256(source.blob).hexdigest()


def test_install_refused_when_disk_reserve_would_be_breached(source, monkeypatch):
    monkeypatch.setattr(installer, "DISK_RESERVE_BYTES", 10 ** 15)
    with pytest.raises(installer.InstallError, match="espace disque insuffisant"):
        installer.install_model(resolved(source), HYBRID, yes=True, accept_license=True)


def _zip(entries: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, data in entries.items():
            z.writestr(name, data)
    return buf.getvalue()


def test_install_engine_extracts_safely():
    good = _zip({"llama-server.exe": b"MZ", "ggml.dll": b"x"})
    evil = _zip({"../../evade.exe": b"MZ", "llama-server.exe": b"MZ"})
    src = FileSource({"/good.zip": good, "/evil.zip": evil})
    try:
        base = {"kind": "engine", "id": "llama.cpp-test", "name": "llama test", "binary": "llama-server.exe",
                "release": "b1", "license": "MIT", "expected_license": "MIT", "repo": "ggml-org/llama.cpp",
                "source_page": "https://exemple"}
        e = installer.install_engine({**base, "file": "good.zip", "url": f"{src.base}/good.zip", "size_bytes": len(good),
                                      "sha256": hashlib.sha256(good).hexdigest()}, HYBRID, yes=True, accept_license=True)
        assert os.path.isfile(e["path"]) and e["path"].endswith("llama-server.exe")
        assert server.find_binary() == e["path"]
        with pytest.raises(installer.InstallError, match="chemin sortant"):
            installer.install_engine({**base, "id": "llama.cpp-evil", "file": "evil.zip", "url": f"{src.base}/evil.zip",
                                      "size_bytes": len(evil), "sha256": hashlib.sha256(evil).hexdigest()},
                                     HYBRID, yes=True, accept_license=True)
    finally:
        src.close()


def test_register_existing_file(tmp_path):
    f = tmp_path / "copie.gguf"
    f.write_bytes(b"GGUF" * 100)
    e = installer.register_existing("copie-locale", str(f), ["chat"], license_id="mit")
    assert e["sha256"] == hashlib.sha256(f.read_bytes()).hexdigest() and e["source"] == {"kind": "local"}
    with pytest.raises(installer.InstallError):
        installer.register_existing("x", str(f), ["inconnu"])


# --- serveur partagé + banc d'essai ---------------------------------------------------
def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _fake_model(tmp_path) -> str:
    f = tmp_path / "fake.gguf"
    f.write_bytes(b"GGUF")
    installer.register_existing("faux-modele", str(f), ["chat", "planning"])
    return "faux-modele"


FAKE = [sys.executable, os.path.join(HERE, "fake_llama_server.py")]


def test_server_start_status_reuse_and_stop(tmp_path):
    mid = _fake_model(tmp_path)
    port = _free_port()
    st = server.start(mid, port=port, threads=2, parallel=2, ctx_per_slot=2048, binary_argv=FAKE, wait_s=30)
    assert st["url"] == f"http://127.0.0.1:{port}/v1" and server.health(port) == "ok"
    assert "-np" in st["argv"] and st["argv"][st["argv"].index("-c") + 1] == "4096"  # 2 contextes partagés
    assert st["argv"][st["argv"].index("--host") + 1] == "127.0.0.1", "jamais exposé au réseau"
    assert server.start(mid, port=port, binary_argv=FAKE)["pid"] == st["pid"], "réutilisé, pas de seconde copie"
    other = tmp_path / "autre.gguf"
    other.write_bytes(b"GGUF")
    installer.register_existing("autre-modele", str(other), ["chat"])
    with pytest.raises(server.ServerError, match="déjà"):
        server.start("autre-modele", port=_free_port(), binary_argv=FAKE)
    assert server.status()["running"] is True
    assert server.stop() and server.health(port) == "down" and server.status() == {"running": False}


def test_server_start_failure_is_reported(tmp_path, monkeypatch):
    mid = _fake_model(tmp_path)
    monkeypatch.setenv("FAKE_LLAMA_FAIL", "1")
    with pytest.raises(server.ServerError, match="arrêté au démarrage"):
        server.start(mid, port=_free_port(), threads=1, parallel=1, binary_argv=FAKE, wait_s=20)
    assert server.read_state() is None


def test_bench_scores_and_records(tmp_path):
    mid = _fake_model(tmp_path)
    port = _free_port()
    st = server.start(mid, port=port, threads=1, parallel=1, binary_argv=FAKE, wait_s=30)
    report = bench.run_and_record(mid, st["url"], server_pid=st["pid"])
    assert report["score"] == "5/5" and report["tokens_per_s"] == 20.0
    assert report["server_peak_mb"] is None or report["server_peak_mb"] > 0
    entry = registry.load()["models"][mid]
    assert entry["status"] == "verified" and entry["benchmark"]["score"] == "5/5"


def test_bench_counts_wrong_answers_as_failures():
    def post(_url, payload, _t):
        return {"choices": [{"message": {"content": "je ne sais pas"}}]}, 0.1

    report = bench.run("http://127.0.0.1:1/v1", post=post)
    assert report["passed"] == 0 and report["score"] == "0/5"


def test_cli_catalog_list_and_guarded_remove(capsys, tmp_path):
    assert soulbah_models.main(["catalog"]) == 0
    assert "qwen2.5-1.5b-instruct-q4_k_m" in capsys.readouterr().out
    assert soulbah_models.main(["list"]) == 0
    mid = _fake_model(tmp_path)
    assert soulbah_models.main(["remove", mid]) == 1, "suppression sans --yes refusée"
    assert mid in registry.load()["models"]
    assert soulbah_models.main(["remove", mid, "--yes"]) == 0 and mid not in registry.load()["models"]
