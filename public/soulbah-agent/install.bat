@echo off
echo ========================================
echo   SOULBAH Agent Local - Installation
echo ========================================
echo.

python --version >nul 2>&1
if errorlevel 1 (
    echo ❌ Python n'est pas installe. Telechargez-le sur python.org
    pause
    exit /b 1
)

echo ✅ Python detecte
echo.
echo Installation des dependances...
pip install -r requirements.txt

echo.
echo ✅ Installation terminee !
echo.
echo Pour lancer l'agent :
echo   python agent.py --url "VOTRE_URL" --user-id "VOTRE_ID" --agent-key "VOTRE_CLE"
echo.
pause
