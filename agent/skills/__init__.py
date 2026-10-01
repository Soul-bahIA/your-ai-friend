"""Registre des skills : associe chaque `type` d'étape à un skill.

LOT 2 : chaque type enregistré doit avoir un manifeste (skills/manifests.py, nom ou
alias) et inversement ; `manifest_errors()` le vérifie au démarrage de l'agent et dans
les tests (catégorie et délai propre du skill compris)."""
from __future__ import annotations

from typing import Mapping

from skills import manifests
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
from skills.git_workspace import (
    GitBranchDeleteSkill, GitCommitSkill, GitMergeSkill, GitPushSkill, GitWorktreeSkill,
)
from skills.browser import BrowserGetSkill
from skills.ui_snapshot import UiSnapshotSkill
from skills.vscode import VsCodeOpenSkill

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
    # LOT 12
    GitWorktreeSkill(),
    GitCommitSkill(),
    GitMergeSkill(),
    GitBranchDeleteSkill(),
    GitPushSkill(),
    BrowserGetSkill(),
    UiSnapshotSkill(),
    VsCodeOpenSkill(),
]

# Table de dispatch : type d'étape -> instance de skill
REGISTRY: dict[str, Skill] = {
    step_type: skill for skill in _ALL_SKILLS for step_type in skill.step_types
}


# Registre d'origine (les tests ajoutent des skills factices à REGISTRY à la volée).
BUILTIN_REGISTRY: dict[str, Skill] = dict(REGISTRY)


def get_skill(step_type: str) -> Skill | None:
    return REGISTRY.get(step_type)


def manifest_errors(registry: Mapping[str, Skill] | None = None) -> list[str]:
    """Écarts entre le registre des skills et les manifestes (liste vide = cohérent).

    - manifestes structurellement valides (manifests.manifest_problems) ;
    - chaque type enregistré a un manifeste, chaque nom/alias de manifeste un skill ;
    - tous les types d'un manifeste sont servis par le MÊME skill ;
    - catégorie (gate de permissions) et délai propre identiques au skill."""
    reg = BUILTIN_REGISTRY if registry is None else registry
    errors = list(manifests.manifest_problems())
    by_type = manifests.manifest_by_type()
    for step_type, skill in reg.items():
        m = by_type.get(step_type)
        if m is None:
            errors.append(f"type « {step_type} » (skill {skill.name}) enregistré sans manifeste")
            continue
        if m["category"] != skill.category:
            errors.append(f"« {step_type} » : catégorie du manifeste {m['category']!r} ≠ skill {skill.category!r}")
        if m["timeout_s"] != skill.timeout_s:
            errors.append(f"« {step_type} » : timeout_s du manifeste {m['timeout_s']!r} ≠ skill {skill.timeout_s!r}")
    for m in manifests.MANIFESTS:
        served = {id(reg[t]) for t in manifests.step_types(m) if t in reg}
        missing = [t for t in manifests.step_types(m) if t not in reg]
        if missing:
            errors.append(f"manifeste « {m['name']} » : type(s) sans skill enregistré : {', '.join(missing)}")
        if len(served) > 1:
            errors.append(f"manifeste « {m['name']} » : ses types sont servis par plusieurs skills")
    return errors


__all__ = ["Skill", "SkillResult", "REGISTRY", "BUILTIN_REGISTRY", "get_skill", "manifest_errors"]
