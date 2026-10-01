# Enveloppe PowerShell de scripts/dev_db/dev_db.sh (base PostgreSQL locale jetable, LOT 3).
# Requiert Git for Windows (bash.exe). Memes commandes et variables que le script bash :
#   powershell -ExecutionPolicy Bypass -File scripts\dev_db\dev_db.ps1 up
#   powershell -ExecutionPolicy Bypass -File scripts\dev_db\dev_db.ps1 test
#   $env:PG_BIN = 'C:\Program Files\PostgreSQL\18\bin' ; ... (si PostgreSQL n'est pas detecte)
param(
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest
)

$bash = $null
$cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
if ($cmd) { $bash = $cmd.Source }
if (-not $bash) {
    foreach ($p in @("$env:ProgramFiles\Git\bin\bash.exe", "$env:ProgramFiles\Git\usr\bin\bash.exe",
                     "${env:ProgramFiles(x86)}\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if (Test-Path $p) { $bash = $p; break }
    }
}
if (-not $bash) { Write-Error "bash.exe introuvable : installez Git for Windows."; exit 1 }

$script = Join-Path $PSScriptRoot 'dev_db.sh'
& $bash $script @Rest
exit $LASTEXITCODE
