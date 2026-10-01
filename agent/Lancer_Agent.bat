@echo off
chcp 65001 >nul
title SoulBah Agent Local
cd /d "%~dp0"

echo ============================================================
echo    SOULBAH AGENT LOCAL
echo ============================================================
echo.
echo Cet agent va chercher les taches que vous planifiez dans
echo l'application (page Automatisation) et les execute sur ce PC.
echo.
echo Il DEMANDE une confirmation avant chaque action sensible.
echo Laissez cette fenetre OUVERTE tant que vous utilisez l'agent.
echo Fermez-la (ou Ctrl+C) pour arreter l'agent.
echo.
echo ------------------------------------------------------------
echo.

python soulbah_agent.py

echo.
echo ------------------------------------------------------------
echo Agent arrete. Appuyez sur une touche pour fermer.
pause >nul
