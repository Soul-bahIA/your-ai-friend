"""Génération des supports PDF d'une formation à partir du curriculum.

Produit un support complet : couverture, objectifs, modules (chapitres, points clés,
exemples, exercices + corrigés, quiz + réponses, étude de cas, projet), glossaire, FAQ.
Police Unicode (Arial Windows) pour gérer accents et symboles ; repli latin-1 sinon.
"""
from __future__ import annotations

import os
import uuid

from fpdf import FPDF

_ACCENT = (99, 102, 241)
_DARK = (30, 30, 40)
_MUTED = (110, 110, 120)

_FONT_REG = r"C:\Windows\Fonts\arial.ttf"
_FONT_BOLD = r"C:\Windows\Fonts\arialbd.ttf"
_FONT_ITAL = r"C:\Windows\Fonts\ariali.ttf"


class _PDF(FPDF):
    base_font = "Helvetica"

    def header(self):
        if self.page_no() == 1:
            return
        self.set_font(self.base_font, "", 8)
        self.set_text_color(*_MUTED)
        self.set_x(self.l_margin)
        self.cell(0, 6, "SoulBah AI — Formation", align="R")
        self.ln(8)

    def footer(self):
        self.set_y(-15)
        self.set_font(self.base_font, "", 8)
        self.set_text_color(*_MUTED)
        self.cell(0, 10, f"Page {self.page_no()}", align="C")


def build_formation_pdf(curriculum: dict, out_path: str) -> dict:
    pdf = _PDF()
    base = "Helvetica"
    if os.path.isfile(_FONT_REG):
        pdf.add_font("Uni", "", _FONT_REG)
        pdf.add_font("Uni", "B", _FONT_BOLD if os.path.isfile(_FONT_BOLD) else _FONT_REG)
        pdf.add_font("Uni", "I", _FONT_ITAL if os.path.isfile(_FONT_ITAL) else _FONT_REG)
        base = "Uni"
    pdf.base_font = base
    pdf.set_auto_page_break(True, margin=18)

    def prep(s: str) -> str:
        s = s or ""
        return s if base != "Helvetica" else s.encode("latin-1", "replace").decode("latin-1")

    def write(text: str, size: int = 11, style: str = "", color=_DARK, lh: float = 6):
        """Écrit un bloc en repartant TOUJOURS de la marge gauche (largeur pleine)."""
        pdf.set_font(base, style, size)
        pdf.set_text_color(*color)
        pdf.set_x(pdf.l_margin)
        pdf.multi_cell(0, lh, prep(text))

    def bullet(text: str, color=_DARK):
        write(f"  •  {text}", 11, "", color)

    def gap(mm: float = 2):
        pdf.ln(mm)

    # --- Couverture ---
    pdf.add_page()
    gap(40)
    write(str(curriculum.get("title", "Formation")), 26, "B", _ACCENT, 12)
    gap(4)
    write(f"Niveau : {curriculum.get('level', '—')}   |   Durée : {curriculum.get('duration', '—')}", 13, "", _MUTED, 8)
    if curriculum.get("audience"):
        write(f"Public : {curriculum['audience']}", 12, "", _MUTED, 8)
    gap(6)
    write(str(curriculum.get("description", "")), 11, "", _MUTED)
    gap(20)
    write("Support produit par SoulBah AI", 10, "", _MUTED)

    # --- Objectifs ---
    objectives = curriculum.get("objectives") or []
    if objectives:
        pdf.add_page()
        write("Objectifs pédagogiques", 18, "B", _ACCENT, 10); gap()
        for o in objectives:
            bullet(str(o))

    # --- Modules ---
    modules = curriculum.get("modules") or []
    for mi, m in enumerate(modules, 1):
        pdf.add_page()
        write(f"Module {mi} — {m.get('title', '')}", 16, "B", _ACCENT, 9)
        if m.get("summary"):
            write(str(m["summary"]), 11, "I", _MUTED)
        gap(2)

        for ci, ch in enumerate(m.get("chapters") or [], 1):
            write(f"{mi}.{ci}  {ch.get('title', '')}", 13, "B", _DARK, 8)
            if ch.get("content"):
                write(str(ch["content"]))
            for kp in ch.get("key_points") or []:
                bullet(str(kp))
            for ex in ch.get("examples") or []:
                write(f"Exemple : {ex}", 10, "I", _MUTED)
            gap(2)

        exercises = m.get("exercises") or []
        if exercises:
            write("Exercices & corrigés", 13, "B", _ACCENT, 8)
            for ei, ex in enumerate(exercises, 1):
                write(f"{ei}. {ex.get('question', '')}", 11, "B")
                write(f"Corrigé : {ex.get('solution', '')}", 10, "", _MUTED)
                gap(1)

        quiz = m.get("quiz") or []
        if quiz:
            write("Quiz", 13, "B", _ACCENT, 8)
            for qi, q in enumerate(quiz, 1):
                write(f"{qi}. {q.get('question', '')}", 11, "B")
                ans = q.get("answer")
                for idx, c in enumerate(q.get("choices") or []):
                    mark = "> " if idx == ans else "   "
                    write(f"{mark}{c}", 10, "B" if idx == ans else "", _DARK if idx == ans else _MUTED)
                if q.get("explanation"):
                    write(f"Explication : {q['explanation']}", 9, "I", _MUTED)
                gap(1)

        if m.get("case_study"):
            write("Étude de cas", 13, "B", _ACCENT, 8)
            write(str(m["case_study"]))
        if m.get("project"):
            write("Projet pratique", 13, "B", _ACCENT, 8)
            write(str(m["project"]))

    # --- Glossaire ---
    glossary = curriculum.get("glossary") or []
    if glossary:
        pdf.add_page()
        write("Glossaire", 18, "B", _ACCENT, 10); gap()
        for g in glossary:
            write(str(g.get("term", "")), 11, "B")
            write(str(g.get("definition", "")), 10, "", _MUTED)
            gap(1)

    # --- FAQ ---
    faq = curriculum.get("faq") or []
    if faq:
        pdf.add_page()
        write("FAQ", 18, "B", _ACCENT, 10); gap()
        for f in faq:
            write(str(f.get("question", "")), 11, "B")
            write(str(f.get("answer", "")), 10, "", _MUTED)
            gap(1)

    # Écriture atomique : fichier temporaire du même dossier puis os.replace.
    partial = f"{out_path}.{uuid.uuid4().hex}.part"
    try:
        pdf.output(partial)
        os.replace(partial, out_path)
    finally:
        if os.path.exists(partial):
            try:
                os.remove(partial)
            except OSError:
                pass
    return {"path": out_path, "pages": pdf.page_no(), "modules": len(modules)}
