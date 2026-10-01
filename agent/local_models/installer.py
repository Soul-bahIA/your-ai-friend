"""Installation de modèles et de moteurs locaux (V3 LOT 2, mission §62, §82).

Garde-fous, dans l'ordre :
  1. mode : refusé en OFFLINE (et NetworkGuard bloquerait de toute façon) ;
  2. consentement : `yes=True` ET `accept_license=True` explicites, après affichage de la taille,
     de la licence lue en ligne, de l'empreinte et de l'URL (jamais de téléchargement implicite) ;
  3. empreinte : sha256 publiée par la source OBLIGATOIRE (sinon refus) et vérifiée après
     téléchargement ; un fichier existant à la bonne empreinte n'est pas retéléchargé ;
  4. disque : refus si l'espace libre après installation descend sous la réserve (5 Go) ;
  5. reprise : fichier `.part` complété par requêtes Range ; déplacement atomique à la fin ;
  6. formats sûrs : GGUF (poids sans code exécutable) pour les modèles ; archive ZIP extraite
     sans chemin sortant du dossier pour les moteurs.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import zipfile
from typing import Any, Callable

from local_models import registry

DISK_RESERVE_BYTES = 5 * 1024 ** 3
CHUNK = 1024 * 1024


class InstallError(RuntimeError):
    pass


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def summary(resolved: dict[str, Any], target: str) -> list[str]:
    """Lignes présentées AVANT tout téléchargement."""
    size_gb = (resolved.get("size_bytes") or 0) / 1024 ** 3
    free = shutil.disk_usage(os.path.dirname(target) if os.path.isdir(os.path.dirname(target)) else os.path.splitdrive(target)[0] + os.sep).free
    return [
        f"{resolved.get('name')} — {resolved.get('id')}",
        f"Source : {resolved.get('source_page')} (révision {str(resolved.get('revision') or resolved.get('release'))[:12]})",
        f"Fichier : {resolved.get('file')} · {size_gb:.2f} Go · sha256 {resolved.get('sha256')}",
        f"Licence déclarée par la source : {resolved.get('license') or 'non déclarée'}"
        f" (attendue : {resolved.get('expected_license')})",
        f"Destination : {target} · espace libre {free / 1024 ** 3:.1f} Go",
    ]


def _check_preconditions(resolved: dict[str, Any], target: str, settings: dict[str, Any], yes: bool,
                         accept_license: bool) -> None:
    import soulbah_settings as S

    if not S.internet_allowed(settings):
        raise InstallError(f"téléchargement impossible en mode {settings.get('mode')} : passez en LOCAL_INTERNET "
                           "le temps de l'installation, ou copiez le fichier et utilisez `register`")
    if not yes:
        raise InstallError("téléchargement non confirmé : relancez avec --yes après avoir lu le résumé")
    if not accept_license:
        raise InstallError(f"licence non acceptée ({resolved.get('license') or 'non déclarée'}) : relancez avec "
                           "--accept-license après l'avoir lue")
    if resolved.get("gated"):
        raise InstallError("modèle à accès restreint (accord requis sur la page de la source) : non pris en charge")
    if not resolved.get("sha256"):
        raise InstallError("la source ne publie pas d'empreinte sha256 : installation refusée")
    size = int(resolved.get("size_bytes") or 0)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    free = shutil.disk_usage(os.path.dirname(target)).free
    part = target + ".part"
    already = os.path.getsize(part) if os.path.isfile(part) else 0
    if free - (size - already) < DISK_RESERVE_BYTES:
        raise InstallError(f"espace disque insuffisant : {free / 1024 ** 3:.1f} Go libres, {size / 1024 ** 3:.2f} Go "
                           f"requis + réserve de {DISK_RESERVE_BYTES // 1024 ** 3} Go")


def download(url: str, target: str, sha256: str, size: int | None, session: Any = None,
             progress: Callable[[int, int | None], None] | None = None) -> str:
    """Télécharge avec reprise et vérifie l'empreinte ; renvoie le chemin final."""
    if os.path.isfile(target) and sha256_file(target) == sha256:
        return target
    if session is None:
        import requests

        session = requests.Session()
    part = target + ".part"
    have = os.path.getsize(part) if os.path.isfile(part) else 0
    headers = {"User-Agent": "SoulBahAgent/2"}
    if have:
        headers["Range"] = f"bytes={have}-"
    with session.get(url, headers=headers, stream=True, timeout=60, allow_redirects=True) as r:
        if r.status_code == 200 and have:
            have = 0  # la source ignore Range : on repart de zéro
        elif r.status_code not in (200, 206):
            raise InstallError(f"téléchargement refusé : HTTP {r.status_code}")
        mode = "ab" if have else "wb"
        with open(part, mode) as f:
            done = have
            for chunk in r.iter_content(CHUNK):
                if chunk:
                    f.write(chunk)
                    done += len(chunk)
                    if size and done > size:
                        raise InstallError("fichier plus gros qu'annoncé : téléchargement interrompu")
                    if progress:
                        progress(done, size)
    got = sha256_file(part)
    if got != sha256:
        os.remove(part)
        raise InstallError(f"empreinte incorrecte : attendue {sha256}, obtenue {got} — fichier supprimé")
    os.replace(part, target)
    return target


def install_model(resolved: dict[str, Any], settings: dict[str, Any], yes: bool = False,
                  accept_license: bool = False, session: Any = None,
                  progress: Callable[[int, int | None], None] | None = None) -> dict[str, Any]:
    target = os.path.join(registry.base_dir(), resolved["id"], resolved["file"])
    _check_preconditions(resolved, target, settings, yes, accept_license)
    path = download(resolved["url"], target, resolved["sha256"], resolved.get("size_bytes"), session, progress)
    entry = {
        "id": resolved["id"], "name": resolved["name"], "family": resolved.get("family"),
        "version": resolved.get("version"), "roles": list(resolved.get("roles") or []), "path": path,
        "size_bytes": os.path.getsize(path), "sha256": resolved["sha256"], "quantization": resolved.get("quantization"),
        "context_max": resolved.get("context_max"), "runtime": "llama.cpp",
        "ram_estimate_gb": registry.ram_estimate_gb(os.path.getsize(path)), "vram_estimate_gb": 0.0,
        "capabilities": resolved.get("capabilities") or {},
        "license": {"id": resolved.get("license"), "accepted_at": registry.now_iso(), "source": resolved.get("source_page")},
        "source": {"kind": "huggingface", "repo": resolved.get("repo"), "file": resolved.get("file"),
                   "revision": resolved.get("revision"), "url": resolved.get("url")},
        "benchmark": None, "installed_at": registry.now_iso(), "status": "installed",
    }
    return registry.upsert("models", entry)


def _safe_extract(zip_path: str, dest: str) -> None:
    root = os.path.realpath(dest)
    with zipfile.ZipFile(zip_path) as z:
        for member in z.infolist():
            out = os.path.realpath(os.path.join(dest, member.filename))
            if not (out == root or out.startswith(root + os.sep)):
                raise InstallError(f"archive refusée : chemin sortant du dossier ({member.filename})")
        z.extractall(dest)


def install_engine(resolved: dict[str, Any], settings: dict[str, Any], yes: bool = False,
                   accept_license: bool = False, session: Any = None,
                   progress: Callable[[int, int | None], None] | None = None) -> dict[str, Any]:
    folder = os.path.join(registry.engines_dir(), resolved["id"])
    archive = os.path.join(registry.engines_dir(), resolved["file"])
    _check_preconditions(resolved, archive, settings, yes, accept_license)
    download(resolved["url"], archive, resolved["sha256"], resolved.get("size_bytes"), session, progress)
    tmp = folder + ".tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    _safe_extract(archive, tmp)
    binary = next((os.path.join(d, resolved["binary"]) for d, _s, files in os.walk(tmp) if resolved["binary"] in files), None)
    if binary is None:
        shutil.rmtree(tmp, ignore_errors=True)
        raise InstallError(f"{resolved['binary']} absent de l'archive")
    shutil.rmtree(folder, ignore_errors=True)
    os.replace(tmp, folder)
    binary = binary.replace(tmp, folder, 1)
    os.remove(archive)
    entry = {"id": resolved["id"], "name": resolved["name"], "path": binary, "release": resolved.get("release"),
             "sha256_archive": resolved["sha256"], "license": {"id": resolved.get("license"), "accepted_at": registry.now_iso()},
             "source": {"kind": "github", "repo": resolved.get("repo"), "url": resolved.get("url")},
             "installed_at": registry.now_iso(), "status": "installed"}
    return registry.upsert("engines", entry)


def register_existing(model_id: str, path: str, roles: list[str], name: str | None = None,
                      license_id: str | None = None) -> dict[str, Any]:
    """Enregistre un fichier GGUF déjà présent (copié hors ligne) : empreinte calculée localement."""
    if not registry.valid_id(model_id):
        raise InstallError(f"identifiant invalide : {model_id}")
    if not os.path.isfile(path) or not path.lower().endswith(".gguf"):
        raise InstallError("fichier .gguf existant attendu")
    bad = [r for r in roles if r not in registry.ROLES]
    if bad or not roles:
        raise InstallError(f"rôles invalides : {bad or roles} (attendus : {', '.join(registry.ROLES)})")
    size = os.path.getsize(path)
    entry = {"id": model_id, "name": name or os.path.basename(path), "roles": roles, "path": os.path.abspath(path),
             "size_bytes": size, "sha256": sha256_file(path), "runtime": "llama.cpp",
             "ram_estimate_gb": registry.ram_estimate_gb(size), "vram_estimate_gb": 0.0,
             "license": {"id": license_id or "non déclarée", "accepted_at": registry.now_iso()},
             "source": {"kind": "local"}, "benchmark": None, "installed_at": registry.now_iso(), "status": "installed"}
    return registry.upsert("models", entry)
