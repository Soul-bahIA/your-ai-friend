@echo off
chcp 65001 >nul
title SoulBah Agent Local
cd /d "%~dp0"
setlocal

echo ============================================================
echo    SOULBAH AGENT LOCAL
echo ============================================================
echo.
echo Cet agent va chercher les taches que vous planifiez dans
echo l'application (page Automatisation) et les execute sur ce PC.
echo.
echo Il DEMANDE une confirmation avant chaque action sensible.
echo Laissez cette fenetre OUVERTE tant que vous utilisez l'agent.
echo Ctrl+C interrompt la tache en cours (statut "annulee") puis
echo arrete l'agent ; un second Ctrl+C force l'arret.
echo.
echo ------------------------------------------------------------
echo.

rem Environnement virtuel dedie a l'agent (agent\.venv), cree au premier lancement
rem (ou par scripts\setup_venvs.ps1 -Target agent). Jamais le Python global.
set "VENV_PY=%~dp0.venv\Scripts\python.exe"

if not exist "%VENV_PY%" goto create
"%VENV_PY%" -c "import requests, dotenv" >nul 2>nul
if errorlevel 1 goto install
goto run

:create
echo Premier lancement : creation de l'environnement virtuel agent\.venv ...
call :find_python
if not defined BOOT_PY goto no_python
%BOOT_PY% -m venv "%~dp0.venv"
if errorlevel 1 goto venv_error

:install
echo Installation des dependances (requirements.txt) - quelques minutes...
"%VENV_PY%" -m pip install --upgrade pip
"%VENV_PY%" -m pip install -r "%~dp0requirements.txt"
if errorlevel 1 goto pip_error
echo Dependances installees.
echo.

:run
"%VENV_PY%" soulbah_agent.py %*
goto end

:find_python
rem Le lanceur py.exe d'abord, puis python. Le raccourci Microsoft Store
rem (WindowsApps) echoue a "import sys" et n'est donc jamais retenu.
set "BOOT_PY="
where py >nul 2>nul
if not errorlevel 1 (
    py -3 -c "import sys" >nul 2>nul
    if not errorlevel 1 set "BOOT_PY=py -3"
)
if defined BOOT_PY exit /b 0
python -c "import sys" >nul 2>nul
if not errorlevel 1 set "BOOT_PY=python"
exit /b 0

:no_python
echo [ERREUR] Python 3 introuvable (le raccourci Microsoft Store ne suffit pas).
echo Installez Python 3.11+ depuis https://www.python.org/downloads/
echo en cochant "Add python.exe to PATH", puis relancez ce script.
goto end

:venv_error
echo [ERREUR] Creation de l'environnement virtuel agent\.venv impossible.
goto end

:pip_error
echo [ERREUR] Installation des dependances echouee (connexion internet ?).
echo Relancez ce script : l'installation reprendra.
goto end

:end
echo.
echo ------------------------------------------------------------
echo Agent arrete. Appuyez sur une touche pour fermer.
pause >nul
endlocal
