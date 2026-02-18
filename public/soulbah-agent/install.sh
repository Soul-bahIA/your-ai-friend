#!/bin/bash
echo "========================================"
echo "  SOULBAH Agent Local - Installation"
echo "========================================"
echo

if ! command -v python3 &> /dev/null; then
    echo "❌ Python3 n'est pas installé."
    echo "   sudo apt install python3 python3-pip"
    exit 1
fi

echo "✅ Python3 détecté"
echo
echo "Installation des dépendances..."
pip3 install -r requirements.txt

echo
echo "✅ Installation terminée !"
echo
echo "Pour lancer l'agent :"
echo '  python3 agent.py --url "VOTRE_URL" --user-id "VOTRE_ID" --agent-key "VOTRE_CLE"'
