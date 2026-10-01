# Lance Soulbah IA EN LOCAL (V3) : base PostgreSQL de développement, modèle local (llama.cpp),
# python-ia, node-api, l'interface web et l'agent qui agit sur le PC, puis ouvre le navigateur.
# Aucun service cloud requis.
#
#   powershell -ExecutionPolicy Bypass -File scripts\dev_local\Lancer_Soulbah_Local.ps1
#   options : -Hybride (fournisseurs cloud de backend\.env autorisés) · -SansModele (pas de llama-server)
#             -AgentV2 (runtime V2 multi-agents au lieu de l'agent qui exécute les ordres de l'interface)
#             -SansAgent (n'exécute rien sur le PC) · -Contexte 8192 (jetons de contexte du modèle)
# L'agent agit dans le dossier autorisé de .dev_db\dev.env (SOULBAH_ALLOWED_DIRS). Les actions sensibles
# (écrire un fichier, taper au clavier, commandes…) attendent ton approbation dans l'application
# (badge d'approbations de la barre latérale, page Sécurité).
# Arrêt : scripts\dev_local\Arreter_Soulbah_Local.ps1. Journaux : .dev_db\logs\.
# Prérequis : base de dev créée (bash scripts/dev_db/dev_db.sh up), modèle installé
# (agent\soulbah_models.py install qwen2.5-1.5b-instruct-q4_k_m --yes --accept-license).
param([switch]$Hybride, [switch]$SansModele, [switch]$AgentV2, [switch]$SansAgent,
      [string]$Modele = 'qwen2.5-1.5b-instruct-q4_k_m', [int]$Contexte = 8192)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Logs = Join-Path $Root '.dev_db\logs'
New-Item -ItemType Directory -Force $Logs | Out-Null
$PidFile = Join-Path $Logs 'pids.json'

function Import-EnvFile([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $value = $Matches[2].Trim()
            if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            [Environment]::SetEnvironmentVariable($Matches[1], $value, 'Process')
        }
    }
}

function Test-Port([int]$Port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { return $c.ConnectAsync('127.0.0.1', $Port).Wait(800) -and $c.Connected } catch { return $false } finally { $c.Dispose() }
}

function Find-FreePort([int]$Start) {
    for ($p = $Start; $p -lt $Start + 30; $p++) { if (-not (Test-Port $p)) { return $p } }
    throw "Aucun port libre entre $Start et $($Start + 29)"
}

function Wait-Http([string]$Url, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -lt 500) { return $true }
        } catch { Start-Sleep -Milliseconds 700 }
    }
    return $false
}

function Start-Hidden([string]$Name, [string]$Exe, [string]$Arguments, [string]$Dir) {
    $log = Join-Path $Logs "$Name.log"
    # Nouvelle console cachée : le service survit à la fermeture de cette fenêtre.
    $cmdLine = '/s /c ""' + $Exe + '" ' + $Arguments + ' > "' + $log + '" 2>&1"'
    $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList $cmdLine -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
    Write-Host "  $Name démarré (journal : $log)"
    return $p.Id
}

Write-Host "Soulbah IA — lancement local"
Import-EnvFile (Join-Path $Root 'backend\.env')
Import-EnvFile (Join-Path $Root '.dev_db\dev.env')
if (-not $env:DEV_LOCAL_TOKEN -or -not $env:DEV_LOCAL_USER_ID) {
    throw "Base de développement absente : lancez d'abord  bash scripts/dev_db/dev_db.sh up"
}
if (Test-Path $PidFile) { throw "Une instance semble déjà lancée : arrêtez-la d'abord (Arreter_Soulbah_Local.ps1)." }
# Ports libres (un autre projet peut occuper 3000, 8000 ou 8080 : jamais arrêté par ce script).
$PortIA = Find-FreePort 8000
$PortApi = Find-FreePort 3000
$PortWeb = Find-FreePort 8080
$env:IA_SERVICE_URL = "http://127.0.0.1:$PortIA"
$env:PORT = "$PortApi"
$env:CORS_ORIGINS = "http://localhost:$PortWeb,http://127.0.0.1:$PortWeb"
$env:LLM_FAKE_PROVIDER = '0'
$env:SOULBAH_MODE = $(if ($Hybride) { 'HYBRID' } else { 'OFFLINE' })
$env:SOULBAH_ENV = 'dev'
$env:HOST = '127.0.0.1'

# 1. PostgreSQL de développement
if (-not (Test-Port 54329)) {
    Write-Host "  démarrage de PostgreSQL (port 54329)…"
    & "$env:ProgramFiles\Git\bin\bash.exe" (Join-Path $Root 'scripts/dev_db/dev_db.sh') up | Out-Null
    if (-not (Test-Port 54329)) { throw "PostgreSQL de développement injoignable sur 127.0.0.1:54329" }
}
Write-Host "  PostgreSQL : prêt (127.0.0.1:54329)"

# 2. Modèle local partagé
$py = Join-Path $Root 'agent\.venv\Scripts\python.exe'
if (-not $SansModele) {
    & $py (Join-Path $Root 'agent\soulbah_models.py') serve $Modele --parallel 1 --ctx $Contexte
    if ($LASTEXITCODE -ne 0) { throw "Le serveur de modèle n'a pas démarré (voir %LOCALAPPDATA%\Soulbah\models\server.log)" }
    $env:LOCAL_LLM_URL = 'http://127.0.0.1:8091/v1'
    $env:LOCAL_LLM_MODEL = $Modele
    # Modèle local sur CPU : plus lent qu'une API cloud — délais allongés (python-ia puis node-api).
    $env:LLM_TIMEOUT_S = '280'
    $env:LLM_BUDGET_S = '290'
    $env:IA_TIMEOUT_MS = '300000'
}

$pids = @{}
# 3. python-ia (routeur de modèles)
$pyia = Join-Path $Root 'backend\python-ia'
$pids['python-ia'] = Start-Hidden 'python-ia' (Join-Path $pyia '.venv\Scripts\python.exe') "-m uvicorn app.main:app --host 127.0.0.1 --port $PortIA" $pyia
# 4. node-api (plan de contrôle)
$node = Join-Path $Root 'backend\node-api'
$pids['node-api'] = Start-Hidden 'node-api' (Join-Path $node 'node_modules\.bin\tsx.cmd') 'src/server.ts' $node
# 5. Interface (connexion locale : serveur de développement uniquement)
$env:VITE_AUTH_MODE = 'dev-local'
$env:VITE_DEV_LOCAL_TOKEN = $env:DEV_LOCAL_TOKEN
$env:VITE_DEV_LOCAL_USER_ID = $env:DEV_LOCAL_USER_ID
$env:VITE_API_URL = "http://127.0.0.1:$PortApi"
$front = Join-Path $Root 'frontend'
$pids['frontend'] = Start-Hidden 'frontend' (Join-Path $front 'node_modules\.bin\vite.cmd') "--port $PortWeb --strictPort" $front

# 6. Agent qui AGIT sur le PC : par défaut la boucle qui exécute les ordres envoyés par l'interface
#    (page Automatisation, barre de commande) ; -AgentV2 : runtime multi-agents des missions V2.
if (-not $SansAgent) {
    $agentEnv = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $Root '.dev_db\dev.env') -Encoding UTF8) {
        if ($line -match '^\s*(SOULBAH_AGENT_KEY|SOULBAH_ALLOWED_DIRS)=(.*)$') { $agentEnv[$Matches[1]] = $Matches[2].Trim() }
    }
    $env:SOULBAH_NO_DOTENV = '1'
    $env:SOULBAH_API_URL = "http://127.0.0.1:$PortApi"
    $env:SOULBAH_AGENT_KEY = $agentEnv['SOULBAH_AGENT_KEY']
    $env:SOULBAH_ALLOWED_DIRS = $agentEnv['SOULBAH_ALLOWED_DIRS']
    $env:SOULBAH_PERMISSION_MODE = 'auto'      # actions confinées au dossier autorisé : sans question
    $env:SOULBAH_APPROVAL_MODE = 'remote'      # actions sensibles : approbation dans l'application
    New-Item -ItemType Directory -Force $env:SOULBAH_ALLOWED_DIRS | Out-Null
    $agentArgs = $(if ($AgentV2) { '-m runtime.supervisor --max-slots 2' } else { '-m runtime.supervisor --legacy' })
    $pids['agent'] = Start-Hidden 'agent' $py $agentArgs (Join-Path $Root 'agent')
    Write-Host "  agent : agit dans $($env:SOULBAH_ALLOWED_DIRS)"
}
$pids | ConvertTo-Json | Set-Content -LiteralPath $PidFile -Encoding UTF8

Write-Host "  attente des services…"
$ok = @{
    'python-ia' = Wait-Http "http://127.0.0.1:$PortIA/health" 120
    'node-api'  = Wait-Http "http://127.0.0.1:$PortApi/health" 120
    'frontend'  = Wait-Http "http://localhost:$PortWeb/" 180
}
foreach ($k in $ok.Keys) { Write-Host ("  {0,-10} {1}" -f $k, $(if ($ok[$k]) { 'prêt' } else { 'PAS PRÊT (voir le journal)' })) }
Write-Host "Mode : $env:SOULBAH_MODE · interface : http://localhost:$PortWeb/ · API : $PortApi · python-ia : $PortIA"
if ($ok['frontend']) { Start-Process "http://localhost:$PortWeb/" }
