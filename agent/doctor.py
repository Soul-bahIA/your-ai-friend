"""`python doctor.py` — diagnostic local de Soulbah (V3 LOT 1).

Affiche le mode (configuration centrale), le profil matériel, les capacités locales et les
recommandations estimées. Rien n'est envoyé sur le réseau.

  python doctor.py            rapport lisible
  python doctor.py --bench    + mesures courtes (GFLOPS, bande passante mémoire, ≈ 2 s)
  python doctor.py --json     profil complet en JSON
  python doctor.py --save     enregistre aussi le profil dans %LOCALAPPDATA%\\Soulbah\\hardware.json
Code de sortie : 0 ; 2 si la configuration centrale est invalide.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import capabilities
import config as agent_config
import hardware
import soulbah_settings as S

ICONS = {"OFFLINE": "🟢", "LOCAL_INTERNET": "🔵", "HYBRID": "🟣"}
STATUS = {"available": "✔ disponible", "unavailable": "✖ indisponible", "disabled": "⊘ désactivé"}


def profile_path() -> str:
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(base, "Soulbah", "hardware.json")


def render(res: dict, prof: dict, caps: dict) -> str:
    st = res["settings"]
    cpu, mem, rec = prof["cpu"], prof["memory"], prof["recommendations"]
    feats = ", ".join(k.upper() for k, v in (cpu.get("features") or {}).items() if v) or "inconnues"
    lines = [
        f"{ICONS.get(st['mode'], '')} Mode : {S.mode_label(st)}"
        f"  (cloud : {'autorisé' if S.cloud_models_allowed(st) else 'refusé'}, "
        f"Internet : {'autorisé' if S.internet_allowed(st) else 'refusé'})",
        f"   Agents : {S.effective_max_agents(st)} (max_agents={st['max_agents']}, profil {st['resource_profile']})"
        f" · contrôle ordinateur : {'oui' if st['computer_control'] else 'non'}"
        f" · enregistrement : {'oui' if st['recording'] else 'non'}",
        f"   Source : {res['source']['file'] or 'aucun fichier'} ; variables : {', '.join(res['source']['env']) or 'aucune'}",
        "",
        f"Système : {prof['os']['system']} {prof['os']['release']} ({prof['os']['version']}), Python {prof['os']['python']}",
        f"CPU     : {cpu.get('name')} · {cpu.get('physical_cores')} cœurs / {cpu.get('logical_threads')} threads"
        f" · {cpu.get('max_mhz')} MHz · {feats}",
        f"RAM     : {mem.get('total_gb')} Go, {mem.get('available_gb')} Go disponibles",
    ]
    for g in prof.get("gpus") or []:
        tag = " (virtuel)" if g.get("virtual") else " (intégré)" if g.get("integrated") else ""
        lines.append(f"GPU     : {g['name']}{tag} · VRAM {g.get('vram_gb') or '?'} Go · pilote {g.get('driver_version')}")
    acc = prof.get("accelerators") or {}
    lines.append(f"Accél.  : CUDA {'oui' if acc.get('cuda') else 'non'} · Vulkan {'oui' if acc.get('vulkan') else 'non'}"
                 f" · DirectML {'oui' if acc.get('directml') else 'non'}")
    for d in prof.get("disks") or []:
        lines.append(f"Disque  : {d['path']} {d['free_gb']} Go libres / {d['total_gb']} Go")
    if prof.get("bench"):
        b = prof["bench"]
        lines.append(f"Mesures : {b.get('matmul_gflops')} GFLOPS fp32 · bande passante {b.get('mem_bandwidth_gbps')} Go/s")
    est = rec.get("est_tokens_per_s_cpu_by_model_size") or {}
    lines += [
        "",
        "Recommandations (ESTIMATIONS, à confirmer par les benchmarks de modèles) :",
        f"   accélérateur {rec['accelerator']} · fichier de modèle ≤ {rec['max_model_file_gb']} Go"
        f" · {rec['parallel_inferences']} inférence(s) simultanée(s) · profil conseillé {rec['suggested_resource_profile']}",
        f"   budget disque pour les modèles ≈ {rec['models_disk_budget_gb']} Go"
        f" · génération estimée : 1 Go ≈ {est.get('1.0_go')} jetons/s, 2 Go ≈ {est.get('2.0_go')},"
        f" 4,5 Go ≈ {est.get('4.5_go')} (bande passante {rec['bandwidth_source']})",
        "",
        "Capacités locales :",
    ]
    for name, c in caps.items():
        detail = c.get("via") or c.get("reason") or ""
        lines.append(f"   {name:<18} {STATUS.get(c['status'], c['status']):<16} {detail}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Diagnostic local de Soulbah (mode, matériel, capacités).")
    ap.add_argument("--bench", action="store_true", help="mesures courtes de calcul et de mémoire (≈ 2 s)")
    ap.add_argument("--json", action="store_true", help="profil complet en JSON")
    ap.add_argument("--save", action="store_true", help=f"enregistre le profil dans {profile_path()}")
    args = ap.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    res = agent_config.load_soulbah_settings()
    if res["errors"]:
        for e in res["errors"]:
            print(f"✖ Configuration : {e}", file=sys.stderr)
        return 2
    prof = hardware.profile(with_bench=args.bench, extra_paths=agent_config.load_config(require_key=False).allowed_dirs)
    caps = capabilities.local_capabilities(res["settings"], prof)
    if args.save:
        path = profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"profile": prof, "capabilities": caps, "settings": S.public_view(res["settings"])}, f,
                      ensure_ascii=False, indent=2)
    if args.json:
        print(json.dumps({"settings": S.public_view(res["settings"]), "profile": prof, "capabilities": caps},
                         ensure_ascii=False, indent=2))
    else:
        print(render(res, prof, caps))
        if args.save:
            print(f"\nProfil enregistré : {profile_path()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
