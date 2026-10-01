# Sauvegarde de la base SoulBah AI (Postgres Supabase) avec pg_dump - Windows PowerShell.
#
# Produit, dans backups\ (ignore par git) :
#   backups\soulbah_YYYYMMDD_HHMM.dump  - format custom (pg_restore)
#   backups\soulbah_YYYYMMDD_HHMM.sql   - format texte (psql)
#
# Connexion : $env:BACKUP_DATABASE_URL, sinon DATABASE_URL lu dans backend\.env.
# Le pooler Supabase en mode transaction (6543) est remplace par le mode session (5432).
# Schemas : $env:BACKUP_SCHEMAS (defaut : "public auth").
#
# Usage :
#   powershell -ExecutionPolicy Bypass -File scripts\backup_db.ps1

$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $Root 'backend\.env'
$OutDir  = Join-Path $Root 'backups'
$Schemas = if ($env:BACKUP_SCHEMAS) { $env:BACKUP_SCHEMAS } else { 'public auth' }

$DbUrl = $env:BACKUP_DATABASE_URL
if (-not $DbUrl) {
    if (-not (Test-Path $EnvFile)) {
        throw "backend\.env introuvable et BACKUP_DATABASE_URL non defini."
    }
    $line = Get-Content $EnvFile | Where-Object { $_ -match '^\s*DATABASE_URL=' } | Select-Object -Last 1
    if ($line) { $DbUrl = ($line -replace '^\s*DATABASE_URL=', '').Trim().Trim('"').Trim("'") }
}
if (-not $DbUrl) { throw "DATABASE_URL vide dans backend\.env." }

$DbUrl = $DbUrl -replace 'pooler\.supabase\.com:6543', 'pooler.supabase.com:5432'
if (-not $env:PGSSLMODE) { $env:PGSSLMODE = 'require' }

$PgDump = (Get-Command pg_dump -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $PgDump) {
    $PgDump = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\pg_dump.exe' -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.Directory.Parent.Name -replace '\D', '') } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $PgDump) { throw "pg_dump introuvable (installez les outils client PostgreSQL)." }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$Base  = Join-Path $OutDir "soulbah_$Stamp"

$SchemaArgs = @()
foreach ($s in ($Schemas -split '\s+' | Where-Object { $_ })) { $SchemaArgs += "--schema=$s" }

Write-Host "pg_dump : $PgDump - schemas : $Schemas"

Write-Host "-> $Base.dump (format custom)"
& $PgDump "--dbname=$DbUrl" --format=custom --no-owner --no-privileges @SchemaArgs "--file=$Base.dump"
if ($LASTEXITCODE -ne 0) { throw "pg_dump (custom) a echoue (code $LASTEXITCODE)." }

Write-Host "-> $Base.sql (format texte)"
& $PgDump "--dbname=$DbUrl" --format=plain --no-owner --no-privileges @SchemaArgs "--file=$Base.sql"
if ($LASTEXITCODE -ne 0) { throw "pg_dump (texte) a echoue (code $LASTEXITCODE)." }

Get-Item "$Base.dump", "$Base.sql" | Format-Table Name, Length
Write-Host "Sauvegarde terminee."
