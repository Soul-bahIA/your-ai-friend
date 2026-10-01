@echo off
chcp 65001 >nul
title SoulBah Runtime V2
cd /d "%~dp0"
setlocal

echo ============================================================
echo    SOULBAH RUNTIME V2 (superviseur multi-agents)
echo ============================================================
echo.
echo Le runtime prend des taches V2 (sessions / missions) et lance
echo un processus par tache, chacun dans son propre Job Object.
echo Une seule instance a la fois : n'executez PAS Lancer_Agent.bat
echo en meme temps (le second refuse de demarrer).
echo Ctrl+C : plus de nouvelle tache, interruption des taches en
echo cours ; elles reprendront au prochain demarrage.
echo.
echo ------------------------------------------------------------
echo.

rem Meme environnement virtuel que l'agent V1 (agent\.venv).
set "VENV_PY=%~dp0.venv\Scripts\python.exe"
if not exist "%VENV_PY%" (
    echo [ERREUR] Environnement agent\.venv introuvable.
    echo Lancez d'abord Lancer_Agent.bat une fois, ou :
    echo   powershell -ExecutionPolicy Bypass -File ..\scripts\setup_venvs.ps1 -Target agent
    goto end
)

"%VENV_PY%" -m runtime.supervisor %*

:end
echo.
echo ------------------------------------------------------------
echo Runtime arrete. Appuyez sur une touche pour fermer.
pause >nul
endlocal
