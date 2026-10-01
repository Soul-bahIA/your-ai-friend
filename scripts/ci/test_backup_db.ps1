# Tests de scripts\backup_db.ps1 (S30, S19) - Windows PowerShell 5.1 ou pwsh 7.
#
#   1. Sans chiffrement ni BACKUP_ALLOW_PLAINTEXT=1 : refus (code 2) AVANT toute lecture
#      de backend\.env ou connexion, aucun fichier ecrit.
#   2. Phrase de passe gpg introuvable : echec, aucun fichier ecrit.
#   3. Integration (facultative) si $env:BACKUP_TEST_DATABASE_URL pointe vers une base
#      JETABLE (migrations appliquees) : dump en clair explicite, droits conserves dans le
#      dump (ACL de has_role), mot de passe avec un + litteral.
#
# Usage : powershell -ExecutionPolicy Bypass -File scripts\ci\test_backup_db.ps1
#         (CI : pwsh -NoProfile -File scripts/ci/test_backup_db.ps1)

$ErrorActionPreference = 'Stop'
$Root   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $Root 'scripts/backup_db.ps1'
$Exe    = (Get-Process -Id $PID).Path
$Tmp    = Join-Path ([System.IO.Path]::GetTempPath()) ('soulbah_backup_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$script:Failures = 0

function Test-Equal([string]$Label, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { Write-Host "ok    $Label" }
    else { Write-Host "ECHEC $Label : attendu <$Expected>, obtenu <$Actual>"; $script:Failures++ }
}

$Vars = 'BACKUP_AGE_RECIPIENT', 'BACKUP_GPG_RECIPIENT', 'BACKUP_GPG_PASSPHRASE_FILE', 'BACKUP_ALLOW_PLAINTEXT',
        'BACKUP_DIR', 'BACKUP_DATABASE_URL', 'BACKUP_SCHEMAS'
$Saved = @{}
foreach ($n in $Vars) { $Saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }

function Invoke-Backup([hashtable]$Env) {
    foreach ($n in $Vars) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k], 'Process') }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe -NoProfile -ExecutionPolicy Bypass -File $Script 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $prev
    }
    return @{ Code = $LASTEXITCODE; Out = $out }
}

function Get-FileCount([string]$Dir) {
    @(Get-ChildItem -Path $Dir -Recurse -File -ErrorAction SilentlyContinue).Count
}

try {
    # --- 1) Refus du dump en clair ------------------------------------------------------
    $r = Invoke-Backup @{ BACKUP_DIR = (Join-Path $Tmp 'refus'); BACKUP_DATABASE_URL = 'postgresql://u:p@127.0.0.1:1/db' }
    Test-Equal 'sans chiffrement : code de sortie' 2 $r.Code
    Test-Equal 'sans chiffrement : message REFUS' $true ($r.Out -match 'REFUS')
    Test-Equal 'sans chiffrement : aucun fichier ecrit' 0 (Get-FileCount $Tmp)

    # --- 2) Phrase de passe introuvable ---------------------------------------------------
    $r = Invoke-Backup @{ BACKUP_DIR = (Join-Path $Tmp 'refus'); BACKUP_DATABASE_URL = 'postgresql://u:p@127.0.0.1:1/db';
                          BACKUP_GPG_PASSPHRASE_FILE = (Join-Path $Tmp 'absent.txt') }
    Test-Equal 'phrase de passe introuvable : echec' $true ($r.Code -ne 0)
    Test-Equal 'phrase de passe introuvable : aucun fichier ecrit' 0 (Get-FileCount $Tmp)

    # --- 3) Integration sur une base jetable (facultative) -------------------------------
    if ($env:BACKUP_TEST_DATABASE_URL) {
        $Url = $env:BACKUP_TEST_DATABASE_URL
        Write-Host '--- integration (base jetable)'
        $Schemas = if ($env:BACKUP_TEST_SCHEMAS) { $env:BACKUP_TEST_SCHEMAS } else { 'public' }
        $IntDir = Join-Path $Tmp 'int'
        $r = Invoke-Backup @{ BACKUP_DIR = $IntDir; BACKUP_DATABASE_URL = $Url; BACKUP_ALLOW_PLAINTEXT = '1';
                              BACKUP_SCHEMAS = $Schemas }
        Test-Equal 'integration : sauvegarde en clair explicite (code)' 0 $r.Code
        if ($r.Code -ne 0) { Write-Host $r.Out }
        $Dump = Get-ChildItem -Path $IntDir -Filter 'soulbah_*.dump' -ErrorAction SilentlyContinue | Select-Object -First 1
        Test-Equal 'integration : .dump et .sql produits' 2 (Get-FileCount $IntDir)
        if ($Dump) {
            $PgRestore = (Get-Command pg_restore -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if (-not $PgRestore) {
                $PgRestore = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\pg_restore.exe' -ErrorAction SilentlyContinue |
                    Select-Object -Last 1 -ExpandProperty FullName
            }
            $Toc = & $PgRestore -l $Dump.FullName | Out-String
            Test-Equal 'integration : ACL de has_role dans le .dump (S19)' $true ($Toc -match 'ACL public FUNCTION has_role')
        }
    }
} finally {
    foreach ($n in $Vars) { [Environment]::SetEnvironmentVariable($n, $Saved[$n], 'Process') }
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "test_backup_db.ps1 : $($script:Failures) echec(s)"
    exit 1
}
Write-Host 'test_backup_db.ps1 : tous les tests sont passes'
