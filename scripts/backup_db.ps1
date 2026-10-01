# Sauvegarde de la base SoulBah AI (Postgres Supabase) avec pg_dump - Windows PowerShell.
#
# Produit, dans backups\ (ignore par git) :
#   backups\soulbah_YYYYMMDD_HHMM.dump  - format custom (pg_restore)
#   backups\soulbah_YYYYMMDD_HHMM.sql   - format texte (psql)
# (+ .gpg / .age si le chiffrement est configure, voir plus bas)
#
# Connexion : $env:BACKUP_DATABASE_URL, sinon DATABASE_URL lu dans backend\.env.
# Le pooler Supabase en mode transaction (6543) est remplace par le mode session (5432).
# Schemas : $env:BACKUP_SCHEMAS (defaut : "public auth").
# Dossier : $env:BACKUP_DIR (defaut : backups\ a la racine du depot).
#
# Secret : le mot de passe n'apparait JAMAIS sur la ligne de commande de pg_dump.
# L'URL est decomposee en PGHOST/PGPORT/PGUSER/PGDATABASE et le mot de passe est ecrit
# dans un fichier pgpass temporaire (PGPASSFILE, dans %TEMP% de l'utilisateur),
# supprime a la fin du script, meme en cas d'erreur.
#
# Chiffrement OBLIGATOIRE par defaut (S30 : le dump contient toutes les donnees, dont les
# empreintes de mots de passe d'auth.users) - une des variables :
#   $env:BACKUP_AGE_RECIPIENT = 'age1...'          -> age -r <cle publique>       (.age)
#   $env:BACKUP_GPG_RECIPIENT = '<id ou e-mail>'   -> gpg --encrypt (cle publique) (.gpg)
#   $env:BACKUP_GPG_PASSPHRASE_FILE = '<fichier>'  -> gpg --symmetric AES256, phrase lue dans le fichier
# gpg : celui du PATH, sinon celui de Git for Windows (C:\Program Files\Git\usr\bin\gpg.exe).
# Apres chiffrement reussi, les fichiers en clair sont supprimes ($env:BACKUP_KEEP_PLAINTEXT='1'
# pour les garder). Sans aucune de ces variables, le script REFUSE de s'executer (code 2),
# sauf $env:BACKUP_ALLOW_PLAINTEXT='1' (dump en clair assume, par exemple base jetable).
#
# Droits (S19) : les GRANT/REVOKE sont CONSERVES dans le dump (pas de --no-privileges) : une
# restauration ne doit pas rendre has_role / is_admin a PUBLIC ou anon. Seule la propriete
# des objets est omise (--no-owner). Restauration : README.md, section Sauvegardes.
#
# Verification TLS stricte (facultatif) : $env:PGSSLMODE='verify-full'; $env:PGSSLROOTCERT='<CA Supabase>'.
#
# Usage :
#   powershell -ExecutionPolicy Bypass -File scripts\backup_db.ps1
# Tests : scripts\ci\test_backup_db.ps1

$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $Root 'backend\.env'
$OutDir  = if ($env:BACKUP_DIR) { $env:BACKUP_DIR } else { Join-Path $Root 'backups' }
$Schemas = if ($env:BACKUP_SCHEMAS) { $env:BACKUP_SCHEMAS } else { 'public auth' }

# --- Chiffrement : decide AVANT toute lecture de secret ou connexion (echec rapide) -------
$Encrypt = ''
$Tool = $null
if ($env:BACKUP_AGE_RECIPIENT) {
    $Tool = (Get-Command age -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $Tool) { throw "BACKUP_AGE_RECIPIENT defini mais 'age' introuvable." }
    $Encrypt = 'age'
} elseif ($env:BACKUP_GPG_RECIPIENT -or $env:BACKUP_GPG_PASSPHRASE_FILE) {
    $Tool = (Get-Command gpg -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $Tool -and (Test-Path 'C:\Program Files\Git\usr\bin\gpg.exe')) { $Tool = 'C:\Program Files\Git\usr\bin\gpg.exe' }
    if (-not $Tool) { throw "Chiffrement gpg demande mais 'gpg' introuvable." }
    if (-not $env:BACKUP_GPG_RECIPIENT -and -not (Test-Path $env:BACKUP_GPG_PASSPHRASE_FILE)) {
        throw "BACKUP_GPG_PASSPHRASE_FILE introuvable : $($env:BACKUP_GPG_PASSPHRASE_FILE)"
    }
    $Encrypt = 'gpg'
} elseif ($env:BACKUP_ALLOW_PLAINTEXT -ne '1') {
    [Console]::Error.WriteLine("REFUS : aucun chiffrement configure (S30) - le dump contiendrait toutes les donnees en clair,")
    [Console]::Error.WriteLine("        y compris les empreintes de mots de passe (schema auth).")
    [Console]::Error.WriteLine("        Definir BACKUP_AGE_RECIPIENT, BACKUP_GPG_RECIPIENT ou BACKUP_GPG_PASSPHRASE_FILE,")
    [Console]::Error.WriteLine("        ou BACKUP_ALLOW_PLAINTEXT=1 pour assumer explicitement un dump en clair.")
    exit 2
}

$DbUrl = $env:BACKUP_DATABASE_URL
if (-not $DbUrl) {
    if (-not (Test-Path $EnvFile)) {
        throw "backend\.env introuvable et BACKUP_DATABASE_URL non defini."
    }
    $line = Get-Content $EnvFile | Where-Object { $_ -match '^\s*DATABASE_URL=' } | Select-Object -Last 1
    if ($line) { $DbUrl = ($line -replace '^\s*DATABASE_URL=', '').Trim().Trim('"').Trim("'") }
}
if (-not $DbUrl) { throw "DATABASE_URL vide dans backend\.env." }
if ($DbUrl -notmatch '^postgres(ql)?://') { throw "DATABASE_URL doit commencer par postgres:// ou postgresql://" }

# --- Decomposition de l'URL ------------------------------------------------------------
$Uri = [System.Uri]$DbUrl
$UserInfo = $Uri.UserInfo
$DbUser = ''; $DbPass = ''
if ($UserInfo) {
    $i = $UserInfo.IndexOf(':')
    if ($i -ge 0) {
        $DbUser = [System.Uri]::UnescapeDataString($UserInfo.Substring(0, $i))
        $DbPass = [System.Uri]::UnescapeDataString($UserInfo.Substring($i + 1))
    } else {
        $DbUser = [System.Uri]::UnescapeDataString($UserInfo)
    }
}
$DbHost = $Uri.Host
$DbPort = if ($Uri.Port -gt 0) { $Uri.Port } else { 5432 }
$DbName = [System.Uri]::UnescapeDataString($Uri.AbsolutePath.TrimStart('/'))
if (-not $DbName) { $DbName = 'postgres' }

# Pooler Supabase : mode transaction (6543) -> mode session (5432).
if ($DbHost -like '*pooler.supabase.com' -and $DbPort -eq 6543) { $DbPort = 5432 }

# sslmode eventuel de l'URL ; require par defaut (Supabase exige TLS).
if (-not $env:PGSSLMODE -and $Uri.Query -match '[?&]sslmode=([^&]+)') { $env:PGSSLMODE = $Matches[1] }
if (-not $env:PGSSLMODE) { $env:PGSSLMODE = 'require' }

$PgDump = (Get-Command pg_dump -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $PgDump) {
    $PgDump = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\pg_dump.exe' -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.Directory.Parent.Name -replace '\D', '') } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $PgDump) { throw "pg_dump introuvable (installez les outils client PostgreSQL)." }

function Protect-BackupFile([string]$Path) {
    switch ($Encrypt) {
        'age' { & $Tool -r $env:BACKUP_AGE_RECIPIENT -o "$Path.age" $Path }
        'gpg' {
            if ($env:BACKUP_GPG_RECIPIENT) {
                & $Tool --batch --yes --encrypt --recipient $env:BACKUP_GPG_RECIPIENT --output "$Path.gpg" $Path
            } else {
                & $Tool --batch --yes --pinentry-mode loopback --symmetric --cipher-algo AES256 `
                    --passphrase-file $env:BACKUP_GPG_PASSPHRASE_FILE --output "$Path.gpg" $Path
            }
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "Chiffrement $Encrypt de $Path echoue (code $LASTEXITCODE)." }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$Base  = Join-Path $OutDir "soulbah_$Stamp"

$SchemaArgs = @()
foreach ($s in ($Schemas -split '\s+' | Where-Object { $_ })) { $SchemaArgs += "--schema=$s" }

# Variables libpq propres a ce processus (restaurees a la fin).
$Saved = @{}
foreach ($n in 'PGHOST', 'PGPORT', 'PGUSER', 'PGDATABASE', 'PGPASSFILE', 'PGPASSWORD', 'PGAPPNAME') {
    $Saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
}
$PassFile = $null
$Success = $false
try {
    $env:PGHOST = $DbHost; $env:PGPORT = "$DbPort"; $env:PGUSER = $DbUser; $env:PGDATABASE = $DbName
    $env:PGAPPNAME = 'soulbah-backup'
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue   # jamais de mot de passe dans l'environnement
    if ($DbPass) {
        $esc = { param($v) ($v -replace '\\', '\\') -replace ':', '\:' }
        $PassFile = Join-Path ([System.IO.Path]::GetTempPath()) ("soulbah_pgpass_" + [guid]::NewGuid().ToString('N') + ".conf")
        $entry = "{0}:{1}:*:{2}:{3}" -f (& $esc $DbHost), $DbPort, (& $esc $DbUser), (& $esc $DbPass)
        [System.IO.File]::WriteAllText($PassFile, $entry + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $env:PGPASSFILE = $PassFile
    }
    $DbPass = $null; $DbUrl = $null

    Write-Host "pg_dump : $PgDump - $DbUser@${DbHost}:$DbPort/$DbName (sslmode=$($env:PGSSLMODE)) - schemas : $Schemas"

    # Droits conserves (pas de --no-privileges) : voir l'en-tete (S19).
    Write-Host "-> $Base.dump (format custom)"
    & $PgDump --format=custom --no-owner @SchemaArgs "--file=$Base.dump"
    if ($LASTEXITCODE -ne 0) { throw "pg_dump (custom) a echoue (code $LASTEXITCODE)." }

    Write-Host "-> $Base.sql (format texte)"
    & $PgDump --format=plain --no-owner @SchemaArgs "--file=$Base.sql"
    if ($LASTEXITCODE -ne 0) { throw "pg_dump (texte) a echoue (code $LASTEXITCODE)." }

    if ($Encrypt) {
        foreach ($f in "$Base.dump", "$Base.sql") {
            Write-Host "-> chiffrement $Encrypt : $f"
            Protect-BackupFile $f
            if ($env:BACKUP_KEEP_PLAINTEXT -ne '1') { Remove-Item -Force $f }
        }
        Get-ChildItem "$Base.*" | Format-Table Name, Length
    } else {
        Get-Item "$Base.dump", "$Base.sql" | Format-Table Name, Length
        Write-Warning "Sauvegarde NON chiffree (BACKUP_ALLOW_PLAINTEXT=1) : toutes les donnees en clair."
    }
    $Success = $true
    Write-Host "Sauvegarde terminee."
} finally {
    if ($PassFile -and (Test-Path $PassFile)) { Remove-Item -Force $PassFile }
    foreach ($n in $Saved.Keys) { [Environment]::SetEnvironmentVariable($n, $Saved[$n], 'Process') }
    if (-not $Success) {
        # Echec : ne pas laisser de dump partiel (ou en clair) derriere soi.
        foreach ($ext in '.dump', '.sql', '.dump.gpg', '.sql.gpg', '.dump.age', '.sql.age') {
            if (Test-Path "$Base$ext") { Remove-Item -Force "$Base$ext" }
        }
    }
}
