"""Registre des skills : associe chaque `type` d'étape à un skill."""
from __future__ import annotations

from skills.base import Skill, SkillResult
from skills.open_app import OpenAppSkill
from skills.screenshot import ScreenshotSkill
from skills.type_text import TypeTextSkill
from skills.wait import WaitSkill
from skills.move_file import MoveFileSkill
from skills.mouse import MouseSkill
from skills.hotkey import HotkeySkill
from skills.window import WindowSkill
from skills.run_command import RunCommandSkill
from skills.filesystem import FileOpsSkill
from skills.record_screen import RecordScreenSkill
from skills.record_bg import StartRecordingBgSkill, StopRecordingBgSkill
from skills.edit_video import EditVideoSkill
from skills.resolve_montage import ResolveMontageSkill
from skills.phone import PhoneSkill, PhoneListDevicesSkill

_ALL_SKILLS: list[Skill] = [
    OpenAppSkill(),
    ScreenshotSkill(),
    TypeTextSkill(),
    WaitSkill(),
    MoveFileSkill(),
    MouseSkill(),
    HotkeySkill(),
    WindowSkill(),
    RunCommandSkill(),
    FileOpsSkill(),
    RecordScreenSkill(),
    StartRecordingBgSkill(),
    StopRecordingBgSkill(),
    EditVideoSkill(),
    ResolveMontageSkill(),
    PhoneListDevicesSkill(),
    PhoneSkill(),
]

# Table de dispatch : type d'étape -> instance de skill
REGISTRY: dict[str, Skill] = {
    step_type: skill for skill in _ALL_SKILLS for step_type in skill.step_types
}


def get_skill(step_type: str) -> Skill | None:
    return REGISTRY.get(step_type)


__all__ = ["Skill", "SkillResult", "REGISTRY", "get_skill"]
