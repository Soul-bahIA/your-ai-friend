# Cree un environnement Python ISOLE par composant (T34 : plus de Python global partage) :
#   agent\.venv              <- agent\requirements.txt             (+ requirements-dev.txt)
#   backend\python-ia\.venv  <- backend\python-ia\requirements.txt (+ requirements-dev.txt)
#
# Les deux composants ont des epingles differentes (Pillow, opencv, requests...) : ne
# jamais installer l'un dans le venv de l'autre ni dans le Python global.
#
# Usage (depuis n'importe ou) :
#   powershell -ExecutionPolicy Bypass -File scripts\setup_venvs.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\setup_venvs.ps1 -Target agent -Recreate
#   powershell -ExecutionPolicy Bypass -File scripts\setup_venvs.ps1 -Python "C:\Python311\python.exe"
#
# Parametres :
#   -Target    all (defaut) | agent | python-ia
#   -Python    interpreteur de base (defaut : premier executable parmi py -3.11, python3.11, python, python3)
#   -NoDev     n'installe pas requirements-dev.txt (ni pytest pour l'agent)
#   -Recreate  supprime et recree le venv (sinon : reutilise et met a jour)
#   -Root      racine du depot (defaut : dossier parent de scripts\)
#
# Ensuite :
#   agent      : agent\.venv\Scripts\python.exe soulbah_agent.py   (Lancer_Agent.bat)
#   python-ia  : cd backend\python-ia ; .venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
#   tests      : agent\.venv\Scripts\python.exe -m pytest agent\tests -q   (avec $env:SOULBAH_NO_DOTENV='1')
param(
    [ValidateSet('all', 'agent', 'python-ia')] [string]$Target = 'all',
    [string]$Python = '',
    [switch]$NoDev,
    [switch]$Recreate,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

# Interpreteur de base : premier candidat qui EXECUTE reellement un Python >= 3.11
# (python.exe peut etre le raccourci Microsoft Store de WindowsApps, qui n'execute rien).
function Test-Python([string[]]$Cmd) {
    $exe = $Cmd[0]; $rest = @($Cmd | Select-Object -Skip 1)
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $false }
    try {
        & $exe @rest -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}
$Base = $null
if ($Python) {
    if (-not (Test-Python @($Python))) { throw "-Python '$Python' n'est pas un Python >= 3.11 executable." }
    $Base = @($Python)
} else {
    foreach ($cand in @(@('py', '-3.11'), @('python3.11'), @('python'), @('python3'))) {
        if (Test-Python $cand) { $Base = $cand; break }
    }
    if (-not $Base) { throw "Aucun Python >= 3.11 executable trouve (utiliser -Python <chemin>)." }
}
$BaseExe = $Base[0]
$BaseArgs = @($Base | Select-Object -Skip 1)
$ver = (& $BaseExe @BaseArgs -c "import sys; print('%d.%d' % sys.version_info[:2])").Trim()
Write-Host "Python de base : $($Base -join ' ') ($ver)"

$Components = [ordered]@{
    'agent'     = Join-Path $Root 'agent'
    'python-ia' = Join-Path $Root 'backend\python-ia'
}

foreach ($name in $Components.Keys) {
    if ($Target -ne 'all' -and $Target -ne $name) { continue }
    $dir   = $Components[$name]
    $req   = Join-Path $dir 'requirements.txt'
    $dev   = Join-Path $dir 'requirements-dev.txt'
    $venv  = Join-Path $dir '.venv'
    $vpy   = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path $req)) { throw "$req introuvable." }

    Write-Host ""
    Write-Host "== $name -> $venv"
    if ($Recreate -and (Test-Path $venv)) {
        Write-Host "   suppression de l'ancien venv"
        Remove-Item -Recurse -Force $venv
    }
    if (-not (Test-Path $vpy)) {
        & $BaseExe @BaseArgs -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw "Creation du venv $venv echouee." }
    }

    & $vpy -m pip install --upgrade pip --disable-pip-version-check -q
    if ($LASTEXITCODE -ne 0) { throw "Mise a jour de pip echouee ($name)." }

    & $vpy -m pip install --disable-pip-version-check -r $req
    if ($LASTEXITCODE -ne 0) { throw "Installation de $req echouee." }

    if (-not $NoDev) {
        if (Test-Path $dev) {
            & $vpy -m pip install --disable-pip-version-check -r $dev
            if ($LASTEXITCODE -ne 0) { throw "Installation de $dev echouee." }
        } else {
            & $vpy -m pip install --disable-pip-version-check pytest
            if ($LASTEXITCODE -ne 0) { throw "Installation de pytest echouee ($name)." }
        }
    }

    & $vpy -m pip check
    if ($LASTEXITCODE -ne 0) { Write-Warning "pip check signale des incompatibilites dans $venv." }
    Write-Host "   OK : $vpy"
}

Write-Host ""
Write-Host "Venvs prets. Le Python global n'a pas ete modifie."
