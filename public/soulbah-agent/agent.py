#!/usr/bin/env python3
"""
SOULBAH Agent Local - Agent d'automatisation PC
================================================
Ce programme s'installe sur votre machine et exécute les tâches
envoyées par l'application web SOULBAH IA.

Fonctionnalités :
- Capture d'écran et enregistrement vidéo (FFmpeg)
- Contrôle souris/clavier (PyAutoGUI)
- Synthèse vocale locale (pyttsx3)
- Ouverture de logiciels (VS Code, terminal, etc.)
- Assemblage audio + vidéo
- Communication sécurisée avec l'app web

Installation :
    pip install -r requirements.txt
    python agent.py --url <SUPABASE_URL> --user-id <YOUR_USER_ID> --agent-key <YOUR_KEY>
"""

import os
import sys
import json
import time
import logging
import argparse
import subprocess
import platform
from pathlib import Path
from datetime import datetime

try:
    import requests
    import pyautogui
    import pyttsx3
except ImportError:
    print("❌ Dépendances manquantes. Installez-les avec :")
    print("   pip install -r requirements.txt")
    sys.exit(1)

# Configuration du logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("soulbah-agent.log", encoding="utf-8"),
    ],
)
logger = logging.getLogger("SoulbahAgent")

# Sécurité PyAutoGUI
pyautogui.FAILSAFE = True
pyautogui.PAUSE = 0.5


class SoulbahAgent:
    """Agent local pour exécuter les tâches SOULBAH."""

    def __init__(self, api_url: str, user_id: str, agent_key: str):
        self.api_url = api_url.rstrip("/")
        self.user_id = user_id
        self.agent_key = agent_key
        self.output_dir = Path("output")
        self.output_dir.mkdir(exist_ok=True)
        self.tts_engine = pyttsx3.init()
        self.tts_engine.setProperty("rate", 160)
        self.running = True

        # Detect OS
        self.os_name = platform.system().lower()
        logger.info(f"🖥️  Système détecté : {platform.system()} {platform.release()}")
        logger.info(f"📁 Dossier de sortie : {self.output_dir.absolute()}")

    def poll_tasks(self) -> list:
        """Récupère les tâches en attente depuis le serveur."""
        try:
            resp = requests.get(
                f"{self.api_url}/functions/v1/agent-tasks",
                params={"action": "poll", "user_id": self.user_id},
                headers={
                    "x-agent-key": self.agent_key,
                    "Content-Type": "application/json",
                },
                timeout=10,
            )
            if resp.status_code == 200:
                data = resp.json()
                return data.get("tasks", [])
            else:
                logger.warning(f"Erreur polling: {resp.status_code}")
                return []
        except Exception as e:
            logger.error(f"Erreur connexion: {e}")
            return []

    def update_task(self, task_id: str, status: str, result=None, error_message=None):
        """Met à jour le statut d'une tâche sur le serveur."""
        try:
            body = {"task_id": task_id, "status": status}
            if result:
                body["result"] = result
            if error_message:
                body["error_message"] = error_message

            requests.get(
                f"{self.api_url}/functions/v1/agent-tasks",
                params={"action": "update"},
                headers={
                    "x-agent-key": self.agent_key,
                    "Content-Type": "application/json",
                },
                timeout=10,
            )
            # Use POST-like update via query param
            requests.post(
                f"{self.api_url}/functions/v1/agent-tasks?action=update",
                json=body,
                headers={
                    "x-agent-key": self.agent_key,
                    "Content-Type": "application/json",
                },
                timeout=10,
            )
            logger.info(f"✅ Tâche {task_id[:8]}... → {status}")
        except Exception as e:
            logger.error(f"Erreur update: {e}")

    # ─── TASK HANDLERS ─────────────────────────────────────────

    def handle_task(self, task: dict):
        """Dispatche une tâche vers le bon handler."""
        task_id = task["id"]
        task_type = task["task_type"]
        payload = task.get("payload", {})

        logger.info(f"🔧 Exécution: {task_type} (ID: {task_id[:8]}...)")
        self.update_task(task_id, "in_progress")

        handlers = {
            "screen_recording": self.task_screen_recording,
            "demo_execution": self.task_demo_execution,
            "video_production": self.task_video_production,
            "tts_generation": self.task_tts_generation,
            "open_software": self.task_open_software,
            "keyboard_action": self.task_keyboard_action,
            "mouse_action": self.task_mouse_action,
            "full_training_video": self.task_full_training_video,
        }

        handler = handlers.get(task_type)
        if not handler:
            self.update_task(task_id, "failed", error_message=f"Type inconnu: {task_type}")
            return

        try:
            result = handler(payload)
            self.update_task(task_id, "completed", result=result)
        except Exception as e:
            logger.error(f"❌ Erreur tâche {task_type}: {e}")
            self.update_task(task_id, "failed", error_message=str(e))

    def task_screen_recording(self, payload: dict) -> dict:
        """Enregistre l'écran avec FFmpeg."""
        duration = payload.get("duration", 30)
        filename = payload.get("filename", f"recording_{int(time.time())}.mp4")
        output_path = self.output_dir / filename

        if self.os_name == "windows":
            input_device = "desktop"
            cmd = [
                "ffmpeg", "-y", "-f", "gdigrab", "-framerate", "30",
                "-i", input_device, "-t", str(duration),
                "-c:v", "libx264", "-preset", "ultrafast",
                str(output_path),
            ]
        elif self.os_name == "darwin":
            cmd = [
                "ffmpeg", "-y", "-f", "avfoundation", "-framerate", "30",
                "-i", "1:none", "-t", str(duration),
                "-c:v", "libx264", "-preset", "ultrafast",
                str(output_path),
            ]
        else:  # Linux
            display = os.environ.get("DISPLAY", ":0")
            cmd = [
                "ffmpeg", "-y", "-f", "x11grab", "-framerate", "30",
                "-i", display, "-t", str(duration),
                "-c:v", "libx264", "-preset", "ultrafast",
                str(output_path),
            ]

        logger.info(f"🎬 Enregistrement écran: {duration}s → {filename}")
        subprocess.run(cmd, check=True, capture_output=True)
        logger.info(f"✅ Enregistrement terminé: {output_path}")

        return {"file": str(output_path), "duration": duration}

    def task_tts_generation(self, payload: dict) -> dict:
        """Génère un fichier audio à partir de texte (TTS local)."""
        text = payload.get("text", "")
        filename = payload.get("filename", f"tts_{int(time.time())}.wav")
        output_path = self.output_dir / filename

        logger.info(f"🔊 Génération TTS: {len(text)} caractères")
        self.tts_engine.save_to_file(text, str(output_path))
        self.tts_engine.runAndWait()
        logger.info(f"✅ Audio généré: {output_path}")

        return {"file": str(output_path)}

    def task_open_software(self, payload: dict) -> dict:
        """Ouvre un logiciel sur la machine."""
        software = payload.get("software", "")
        args = payload.get("args", [])

        software_map = {
            "vscode": {"windows": "code", "darwin": "code", "linux": "code"},
            "terminal": {
                "windows": "cmd",
                "darwin": "open -a Terminal",
                "linux": "gnome-terminal",
            },
            "browser": {
                "windows": "start chrome",
                "darwin": "open -a 'Google Chrome'",
                "linux": "google-chrome",
            },
            "notepad": {
                "windows": "notepad",
                "darwin": "open -a TextEdit",
                "linux": "gedit",
            },
        }

        cmd_map = software_map.get(software.lower(), {})
        cmd = cmd_map.get(self.os_name, software)

        logger.info(f"🚀 Ouverture: {software} ({cmd})")

        if self.os_name == "windows":
            subprocess.Popen(f"{cmd} {' '.join(args)}", shell=True)
        else:
            subprocess.Popen(f"{cmd} {' '.join(args)}", shell=True)

        time.sleep(2)  # Attendre que le logiciel s'ouvre
        return {"software": software, "status": "opened"}

    def task_keyboard_action(self, payload: dict) -> dict:
        """Exécute des actions clavier."""
        actions = payload.get("actions", [])

        for action in actions:
            action_type = action.get("type", "")
            if action_type == "type":
                text = action.get("text", "")
                interval = action.get("interval", 0.05)
                pyautogui.typewrite(text, interval=interval) if text.isascii() else pyautogui.write(text)
            elif action_type == "hotkey":
                keys = action.get("keys", [])
                pyautogui.hotkey(*keys)
            elif action_type == "press":
                key = action.get("key", "")
                pyautogui.press(key)
            elif action_type == "wait":
                time.sleep(action.get("seconds", 1))

            time.sleep(0.3)

        return {"actions_executed": len(actions)}

    def task_mouse_action(self, payload: dict) -> dict:
        """Exécute des actions souris."""
        actions = payload.get("actions", [])

        for action in actions:
            action_type = action.get("type", "")
            if action_type == "click":
                x, y = action.get("x", 0), action.get("y", 0)
                pyautogui.click(x, y)
            elif action_type == "move":
                x, y = action.get("x", 0), action.get("y", 0)
                duration = action.get("duration", 0.5)
                pyautogui.moveTo(x, y, duration=duration)
            elif action_type == "double_click":
                x, y = action.get("x", 0), action.get("y", 0)
                pyautogui.doubleClick(x, y)
            elif action_type == "scroll":
                amount = action.get("amount", 3)
                pyautogui.scroll(amount)

            time.sleep(0.3)

        return {"actions_executed": len(actions)}

    def task_demo_execution(self, payload: dict) -> dict:
        """Exécute une séquence de démonstration complète."""
        steps = payload.get("steps", [])
        results = []

        for i, step in enumerate(steps):
            logger.info(f"  📌 Étape {i+1}/{len(steps)}: {step.get('description', '...')}")
            step_type = step.get("type", "")

            if step_type == "open_software":
                r = self.task_open_software(step)
            elif step_type == "keyboard":
                r = self.task_keyboard_action(step)
            elif step_type == "mouse":
                r = self.task_mouse_action(step)
            elif step_type == "wait":
                time.sleep(step.get("seconds", 2))
                r = {"waited": step.get("seconds", 2)}
            elif step_type == "narrate":
                r = self.task_tts_generation({"text": step.get("text", ""), "filename": f"narration_{i}.wav"})
            else:
                r = {"skipped": step_type}

            results.append(r)

        return {"steps_completed": len(results), "results": results}

    def task_video_production(self, payload: dict) -> dict:
        """Assemble vidéo + audio en fichier final."""
        video_file = payload.get("video_file", "")
        audio_file = payload.get("audio_file", "")
        output_name = payload.get("output", f"final_{int(time.time())}.mp4")
        output_path = self.output_dir / output_name

        logger.info(f"🎞️ Assemblage: {video_file} + {audio_file}")

        cmd = [
            "ffmpeg", "-y",
            "-i", video_file,
            "-i", audio_file,
            "-c:v", "copy", "-c:a", "aac",
            "-map", "0:v:0", "-map", "1:a:0",
            "-shortest",
            str(output_path),
        ]

        subprocess.run(cmd, check=True, capture_output=True)
        logger.info(f"✅ Vidéo finale: {output_path}")

        return {"file": str(output_path)}

    def task_full_training_video(self, payload: dict) -> dict:
        """Pipeline complet : narration + capture + assemblage."""
        title = payload.get("title", "Formation")
        script = payload.get("script", "")
        steps = payload.get("steps", [])
        
        timestamp = int(time.time())
        
        # 1. Générer l'audio de narration
        logger.info("📢 Étape 1: Génération de la narration audio...")
        audio_file = self.output_dir / f"narration_{timestamp}.wav"
        self.tts_engine.save_to_file(script, str(audio_file))
        self.tts_engine.runAndWait()
        
        # 2. Exécuter la démo et capturer l'écran simultanément
        logger.info("🎬 Étape 2: Capture d'écran + exécution démo...")
        video_file = self.output_dir / f"capture_{timestamp}.mp4"
        
        # Calculer la durée estimée
        estimated_duration = max(len(script) / 15, 30)  # ~15 chars/sec TTS
        for step in steps:
            estimated_duration += step.get("duration", 3)
        
        # Lancer FFmpeg en arrière-plan
        if self.os_name == "windows":
            ffmpeg_cmd = [
                "ffmpeg", "-y", "-f", "gdigrab", "-framerate", "24",
                "-i", "desktop", "-t", str(int(estimated_duration)),
                "-c:v", "libx264", "-preset", "ultrafast",
                str(video_file),
            ]
        elif self.os_name == "darwin":
            ffmpeg_cmd = [
                "ffmpeg", "-y", "-f", "avfoundation", "-framerate", "24",
                "-i", "1:none", "-t", str(int(estimated_duration)),
                "-c:v", "libx264", "-preset", "ultrafast",
                str(video_file),
            ]
        else:
            display = os.environ.get("DISPLAY", ":0")
            ffmpeg_cmd = [
                "ffmpeg", "-y", "-f", "x11grab", "-framerate", "24",
                "-i", display, "-t", str(int(estimated_duration)),
                "-c:v", "libx264", "-preset", "ultrafast",
                str(video_file),
            ]
        
        ffmpeg_proc = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(2)  # Attendre que FFmpeg démarre
        
        # Exécuter les étapes de démonstration
        for i, step in enumerate(steps):
            logger.info(f"  ▶ Étape {i+1}: {step.get('description', '')}")
            self.task_demo_execution({"steps": [step]})
        
        # Attendre la fin de la capture
        ffmpeg_proc.wait()
        
        # 3. Assembler vidéo + audio
        logger.info("🎞️ Étape 3: Assemblage final...")
        final_file = self.output_dir / f"{title.replace(' ', '_')}_{timestamp}.mp4"
        
        assemble_cmd = [
            "ffmpeg", "-y",
            "-i", str(video_file),
            "-i", str(audio_file),
            "-c:v", "copy", "-c:a", "aac",
            "-map", "0:v:0", "-map", "1:a:0",
            "-shortest",
            str(final_file),
        ]
        subprocess.run(assemble_cmd, check=True, capture_output=True)
        
        logger.info(f"🎉 Vidéo de formation terminée: {final_file}")
        
        return {
            "file": str(final_file),
            "audio": str(audio_file),
            "video": str(video_file),
            "duration": estimated_duration,
        }

    # ─── MAIN LOOP ──────────────────────────────────────────────

    def run(self):
        """Boucle principale de l'agent."""
        logger.info("═" * 50)
        logger.info("🤖 SOULBAH Agent Local - Démarré")
        logger.info(f"🌐 Serveur: {self.api_url}")
        logger.info(f"👤 User ID: {self.user_id[:8]}...")
        logger.info("═" * 50)
        logger.info("⏳ En attente de tâches... (Ctrl+C pour arrêter)")

        while self.running:
            try:
                tasks = self.poll_tasks()
                if tasks:
                    logger.info(f"📬 {len(tasks)} tâche(s) reçue(s)")
                    for task in tasks:
                        self.handle_task(task)
                else:
                    time.sleep(5)  # Polling interval
            except KeyboardInterrupt:
                logger.info("🛑 Arrêt demandé par l'utilisateur")
                self.running = False
            except Exception as e:
                logger.error(f"Erreur boucle principale: {e}")
                time.sleep(10)

        logger.info("👋 Agent arrêté proprement.")


def main():
    parser = argparse.ArgumentParser(description="SOULBAH Agent Local")
    parser.add_argument("--url", required=True, help="URL du serveur (ex: https://xxx.supabase.co)")
    parser.add_argument("--user-id", required=True, help="Votre User ID")
    parser.add_argument("--agent-key", required=True, help="Clé d'authentification agent")
    parser.add_argument("--output-dir", default="output", help="Dossier de sortie des vidéos")
    args = parser.parse_args()

    agent = SoulbahAgent(args.url, args.user_id, args.agent_key)
    if args.output_dir != "output":
        agent.output_dir = Path(args.output_dir)
        agent.output_dir.mkdir(exist_ok=True)

    agent.run()


if __name__ == "__main__":
    main()
