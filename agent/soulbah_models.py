"""`python soulbah_models.py` — modèles et moteurs locaux de Soulbah (V3 LOT 2).

  catalog                              candidats proposés (rien n'est téléchargé)
  resolve <id>                         métadonnées exactes en ligne : taille, sha256, licence, révision
  install <id> --yes --accept-license  télécharge, vérifie l'empreinte, enregistre (jamais en OFFLINE)
  install-engine <id> --yes --accept-license   idem pour llama.cpp
  register <id> <fichier.gguf> --roles chat,planning [--license ID]   fichier déjà présent
  list                                 registre local (modèles, moteurs, benchmarks)
  serve <id> [--port P] [--threads N] [--parallel N] [--ctx N]   serveur partagé, affiche LOCAL_LLM_URL
  status | stop                        état / arrêt du serveur
  bench <id>                           banc d'essai sur le serveur en cours, résultat enregistré
  remove <id> --yes                    retire le modèle du registre ET supprime son fichier
Codes de sortie : 0 succès, 1 échec, 2 configuration invalide.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import config as agent_config
from local_models import bench, catalog, installer, registry, server


def _settings() -> dict | None:
    res = agent_config.load_soulbah_settings()
    if res["errors"]:
        for e in res["errors"]:
            print(f"✖ Configuration : {e}", file=sys.stderr)
        return None
    return res["settings"]


def _progress(done: int, total: int | None) -> None:
    if total:
        pct = done * 100 // total
        if pct % 5 == 0:
            print(f"\r   {done / 1024 ** 3:.2f} / {total / 1024 ** 3:.2f} Go ({pct} %)", end="", flush=True)


def cmd_catalog(_a) -> int:
    print("Candidats (PROPOSITIONS : `resolve <id>` lit taille, empreinte et licence exactes en ligne) :")
    for mid, m in catalog.MODELS.items():
        print(f"  {mid:<36} {', '.join(m['roles']):<32} {m['repo']}  (licence attendue : {m['expected_license']})")
    print("Moteurs :")
    for eid, e in catalog.ENGINES.items():
        print(f"  {eid:<36} {e['repo']}  (licence attendue : {e['expected_license']})")
    return 0


def _resolve(kind: str, ident: str) -> dict:
    return catalog.resolve_engine(ident) if kind == "engine" else catalog.resolve_model(ident)


def cmd_resolve(a) -> int:
    kind = "engine" if a.id in catalog.ENGINES else "model"
    r = _resolve(kind, a.id)
    target = os.path.join(registry.engines_dir() if kind == "engine" else os.path.join(registry.base_dir(), a.id),
                          r["file"])
    for line in installer.summary(r, target):
        print(line)
    return 0


def _install(a, kind: str) -> int:
    settings = _settings()
    if settings is None:
        return 2
    r = _resolve(kind, a.id)
    target = os.path.join(registry.engines_dir() if kind == "engine" else os.path.join(registry.base_dir(), a.id), r["file"])
    for line in installer.summary(r, target):
        print(line)
    fn = installer.install_engine if kind == "engine" else installer.install_model
    entry = fn(r, settings, yes=a.yes, accept_license=a.accept_license, progress=_progress)
    print(f"\n✔ Installé et vérifié (sha256) : {entry['path']}")
    return 0


def cmd_register(a) -> int:
    entry = installer.register_existing(a.id, a.path, [r.strip() for r in a.roles.split(",") if r.strip()],
                                        license_id=a.license)
    print(f"✔ Enregistré : {entry['id']} · {entry['size_bytes'] / 1024 ** 3:.2f} Go · sha256 {entry['sha256']}")
    return 0


def cmd_list(_a) -> int:
    data = registry.load()
    if not data["models"] and not data["engines"]:
        print("Aucun modèle ni moteur installé. Voir : python soulbah_models.py catalog")
    for m in data["models"].values():
        b = m.get("benchmark") or {}
        bench_txt = f" · banc {b.get('score')} à {b.get('tokens_per_s')} jetons/s" if b else ""
        print(f"  [{m.get('status')}] {m['id']} · {', '.join(m.get('roles') or [])} · "
              f"{(m.get('size_bytes') or 0) / 1024 ** 3:.2f} Go · RAM ≈ {m.get('ram_estimate_gb')} Go{bench_txt}")
    for e in data["engines"].values():
        print(f"  [moteur {e.get('status')}] {e['id']} · {e.get('release')} · {e.get('path')}")
    return 0


def cmd_serve(a) -> int:
    st = server.start(a.id, port=a.port, threads=a.threads, parallel=a.parallel, ctx_per_slot=a.ctx)
    print(f"✔ Serveur prêt (pid {st['pid']}) : {st['url']} · {st['threads']} threads · {st['parallel']} contexte(s)")
    print(f"   LOCAL_LLM_URL={st['url']}")
    print(f"   LOCAL_LLM_MODEL={a.id}")
    return 0


def cmd_status(_a) -> int:
    print(json.dumps(server.status(), ensure_ascii=False, indent=2))
    return 0


def cmd_stop(_a) -> int:
    print("Serveur arrêté." if server.stop() else "Aucun serveur en cours.")
    return 0


def cmd_bench(a) -> int:
    st = server.status()
    if not st.get("running") or st.get("model_id") != a.id:
        print(f"✖ Démarrez d'abord le serveur pour ce modèle : python soulbah_models.py serve {a.id}", file=sys.stderr)
        return 1
    report = bench.run_and_record(a.id, st["url"], server_pid=int(st["pid"]))
    for t in report["tasks"]:
        print(f"  {'✔' if t.get('passed') else '✖'} {t['id']:<15} {t.get('seconds', '-')} s · "
              f"{t.get('tokens_per_s') or '-'} jetons/s {('· ' + t['error']) if t.get('error') else ''}")
    print(f"Score {report['score']} · {report['tokens_per_s']} jetons/s · mémoire de pointe "
          f"{report.get('server_peak_mb')} Mo")
    return 0 if report["passed"] else 1


def cmd_remove(a) -> int:
    if not a.yes:
        print("✖ Suppression non confirmée : relancez avec --yes (le fichier du modèle sera effacé).", file=sys.stderr)
        return 1
    entry = registry.load()["models"].get(a.id)
    if not entry:
        print(f"✖ Modèle inconnu : {a.id}", file=sys.stderr)
        return 1
    st = server.status()
    if st.get("running") and st.get("model_id") == a.id:
        server.stop()
    path = entry.get("path")
    if path and os.path.isfile(path) and os.path.realpath(path).startswith(os.path.realpath(registry.base_dir())):
        os.remove(path)
    registry.remove("models", a.id)
    print(f"✔ Retiré : {a.id}")
    return 0


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="Modèles et moteurs locaux de Soulbah.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("catalog")
    p = sub.add_parser("resolve")
    p.add_argument("id")
    for name in ("install", "install-engine"):
        p = sub.add_parser(name)
        p.add_argument("id")
        p.add_argument("--yes", action="store_true")
        p.add_argument("--accept-license", action="store_true")
    p = sub.add_parser("register")
    p.add_argument("id")
    p.add_argument("path")
    p.add_argument("--roles", required=True)
    p.add_argument("--license")
    sub.add_parser("list")
    p = sub.add_parser("serve")
    p.add_argument("id")
    p.add_argument("--port", type=int, default=server.DEFAULT_PORT)
    p.add_argument("--threads", type=int)
    p.add_argument("--parallel", type=int)
    p.add_argument("--ctx", type=int)
    sub.add_parser("status")
    sub.add_parser("stop")
    p = sub.add_parser("bench")
    p.add_argument("id")
    p = sub.add_parser("remove")
    p.add_argument("id")
    p.add_argument("--yes", action="store_true")
    a = ap.parse_args(argv)
    handlers = {"catalog": cmd_catalog, "resolve": cmd_resolve, "install": lambda x: _install(x, "model"),
                "install-engine": lambda x: _install(x, "engine"), "register": cmd_register, "list": cmd_list,
                "serve": cmd_serve, "status": cmd_status, "stop": cmd_stop, "bench": cmd_bench, "remove": cmd_remove}
    try:
        return handlers[a.cmd](a)
    except (installer.InstallError, catalog.ResolveError, server.ServerError, ValueError) as e:
        print(f"✖ {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
