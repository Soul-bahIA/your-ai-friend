"""Copie les modules partagés Python vers leurs services (V3 LOT 1).

  python scripts/sync_shared.py          réécrit les copies
  python scripts/sync_shared.py --check  échoue (code 1) si une copie diffère de la source

Source → copies : shared/config/soulbah_settings.py → agent/soulbah_settings.py et
backend/python-ia/app/soulbah_settings.py. Les tests de chaque service vérifient aussi la
non-dérive (une copie modifiée à la main est refusée).
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
COPIES = {
    ROOT / "shared" / "config" / "soulbah_settings.py": [
        ROOT / "agent" / "soulbah_settings.py",
        ROOT / "backend" / "python-ia" / "app" / "soulbah_settings.py",
    ],
}


def main(argv: list[str]) -> int:
    check = "--check" in argv
    drift = 0
    for src, dests in COPIES.items():
        content = src.read_bytes()
        for dest in dests:
            same = dest.exists() and dest.read_bytes() == content
            if check:
                if not same:
                    print(f"dérive : {dest.relative_to(ROOT)} ≠ {src.relative_to(ROOT)}")
                    drift += 1
            elif not same:
                dest.write_bytes(content)
                print(f"écrit : {dest.relative_to(ROOT)}")
    if check:
        print("Modules partagés à jour." if not drift else f"{drift} copie(s) à régénérer : python scripts/sync_shared.py")
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
