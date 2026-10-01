# Demarrage automatique du runtime V2 de SoulBah a l'ouverture de session (LOT 8).
#
# Cree (ou remplace) la tache planifiee Windows « SoulbahRuntime » de l'utilisateur courant :
#   declencheur : ouverture de session de CET utilisateur (session interactive : le runtime
#                 pilote le bureau, il ne doit jamais tourner comme service sans bureau) ;
#   action      : agent\.venv\Scripts\pythonw.exe -m runtime.supervisor, dossier agent\ ;
#   relance     : 3 fois a 1 minute d'intervalle en cas d'echec ; pas de limite de duree.
#
# Usage (PowerShell utilisateur, PAS en administrateur) :
#   powershell -ExecutionPolicy Bypass -File agent\scripts\install_autostart.ps1
#   powershell -ExecutionPolicy Bypass -File agent\scripts\install_autostart.ps1 -Uninstall
#   powershell -ExecutionPolicy Bypass -File agent\scripts\install_autostart.ps1 -Console   # fenetre visible (python.exe)
#
# Journal : %LOCALAPPDATA%\Soulbah\runtime\logs\supervisor.log (SOULBAH_RUNTIME_DIR pour changer).
param(
    [switch]$Uninstall,
    [switch]$Console,
    [string]$TaskName = 'SoulbahRuntime'
)
$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Tache planifiee « $TaskName » supprimee."
    } else {
        Write-Host "Aucune tache planifiee « $TaskName »."
    }
    exit 0
}

$agentDir = Split-Path -Parent $PSScriptRoot
$exeName = if ($Console) { 'python.exe' } else { 'pythonw.exe' }
$python = Join-Path $agentDir ".venv\Scripts\$exeName"
if (-not (Test-Path $python)) {
    Write-Error "Interpreteur introuvable : $python. Lancez d'abord agent\Lancer_Agent.bat (ou scripts\setup_venvs.ps1 -Target agent)."
    exit 1
}

$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $python -Argument '-m runtime.supervisor' -WorkingDirectory $agentDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'SoulBah runtime V2 (superviseur multi-agents) - demarrage a l''ouverture de session' -Force | Out-Null

Write-Host "Tache planifiee « $TaskName » installee pour $user (demarrage a l'ouverture de session)."
Write-Host "Demarrer maintenant : Start-ScheduledTask -TaskName $TaskName"
Write-Host "Retirer             : powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Uninstall"
