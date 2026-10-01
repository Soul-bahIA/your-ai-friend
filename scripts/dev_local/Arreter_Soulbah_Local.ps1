# Arrête Soulbah IA lancé par Lancer_Soulbah_Local.ps1 : interface, node-api, python-ia et modèle
# local. La base PostgreSQL de développement reste démarrée (bash scripts/dev_db/dev_db.sh down).
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$PidFile = Join-Path $Root '.dev_db\logs\pids.json'
if (Test-Path $PidFile) {
    $pids = Get-Content -LiteralPath $PidFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $pids.PSObject.Properties) {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $p.Value /T /F 2>$null | Out-Null
        Write-Host "  $($p.Name) arrêté"
    }
    Remove-Item -LiteralPath $PidFile -Force
}
& (Join-Path $Root 'agent\.venv\Scripts\python.exe') (Join-Path $Root 'agent\soulbah_models.py') stop
