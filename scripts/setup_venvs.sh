#!/usr/bin/env bash
# Crée un environnement Python ISOLÉ par composant (T34 : plus de Python global partagé) :
#   agent/.venv              ← agent/requirements.txt             (+ requirements-dev.txt)
#   backend/python-ia/.venv  ← backend/python-ia/requirements.txt (+ requirements-dev.txt)
#
# Les deux composants ont des épingles différentes (Pillow, opencv, requests…) : ne
# jamais installer l'un dans le venv de l'autre ni dans le Python global.
#
# Usage (git-bash / Linux / macOS, depuis n'importe où) :
#   bash scripts/setup_venvs.sh                 # les deux
#   bash scripts/setup_venvs.sh agent --recreate
#   PYTHON=python3.11 bash scripts/setup_venvs.sh python-ia
#
# Arguments : [all|agent|python-ia] [--no-dev] [--recreate]
# Variables : PYTHON       interpréteur de base (défaut : premier exécutable parmi
#                          py -3.11, python3.11, python3, python)
#             SOULBAH_ROOT racine du dépôt (défaut : dossier parent de scripts/)
set -euo pipefail

ROOT="${SOULBAH_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TARGET="all"; DEV=1; RECREATE=0
for arg in "$@"; do
  case "$arg" in
    all|agent|python-ia) TARGET="$arg" ;;
    --no-dev)   DEV=0 ;;
    --recreate) RECREATE=1 ;;
    -h|--help)  sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Argument inconnu : $arg" >&2; exit 2 ;;
  esac
done

# Premier candidat qui EXÉCUTE réellement un Python >= 3.11 (sous Windows, `python3`
# peut être le raccourci Microsoft Store qui n'exécute rien).
probe() {
  "$@" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1
}
BASE=()
if [[ -n "${PYTHON:-}" ]]; then
  read -r -a BASE <<< "$PYTHON"
  probe "${BASE[@]}" || { echo "PYTHON='$PYTHON' n'est pas un Python >= 3.11 exécutable." >&2; exit 1; }
else
  for cand in "py -3.11" "/c/Windows/py.exe -3.11" "python3.11" "python3" "python"; do
    read -r -a c <<< "$cand"
    if probe "${c[@]}"; then BASE=("${c[@]}"); break; fi
  done
  (( ${#BASE[@]} > 0 )) || { echo "Aucun Python >= 3.11 exécutable trouvé (définir PYTHON=...)." >&2; exit 1; }
fi
ver="$("${BASE[@]}" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
echo "Python de base : ${BASE[*]} ($ver)"

setup_one() {
  local name="$1" dir="$2"
  local req="$dir/requirements.txt" dev="$dir/requirements-dev.txt" venv="$dir/.venv"
  [[ -f "$req" ]] || { echo "$req introuvable." >&2; exit 1; }

  echo
  echo "== $name → $venv"
  if [[ "$RECREATE" == 1 && -d "$venv" ]]; then
    echo "   suppression de l'ancien venv"
    rm -rf "$venv"
  fi
  # Windows (git-bash) : Scripts/python.exe ; Linux/macOS : bin/python
  local vpy="$venv/bin/python"
  [[ -x "$venv/Scripts/python.exe" ]] && vpy="$venv/Scripts/python.exe"
  if [[ ! -x "$vpy" ]]; then
    "${BASE[@]}" -m venv "$venv"
    vpy="$venv/bin/python"
    [[ -x "$venv/Scripts/python.exe" ]] && vpy="$venv/Scripts/python.exe"
  fi

  "$vpy" -m pip install --upgrade pip --disable-pip-version-check -q
  "$vpy" -m pip install --disable-pip-version-check -r "$req"
  if [[ "$DEV" == 1 ]]; then
    if [[ -f "$dev" ]]; then
      "$vpy" -m pip install --disable-pip-version-check -r "$dev"
    else
      "$vpy" -m pip install --disable-pip-version-check pytest
    fi
  fi
  "$vpy" -m pip check || echo "ATTENTION : pip check signale des incompatibilités dans $venv." >&2
  echo "   OK : $vpy"
}

[[ "$TARGET" == all || "$TARGET" == agent     ]] && setup_one agent     "$ROOT/agent"
[[ "$TARGET" == all || "$TARGET" == python-ia ]] && setup_one python-ia "$ROOT/backend/python-ia"

echo
echo "Venvs prêts. Le Python global n'a pas été modifié."
