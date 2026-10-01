from __future__ import annotations

import hmac
import logging
import os
from contextlib import asynccontextmanager
from typing import Annotated
from uuid import UUID

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, StringConstraints

from .agents import AGENTS, route_request
from .formation import analyze_request, build_module, build_program
from .generation import generate_application, generate_formation
from .llm import LLMError
from .pdf import build_formation_pdf
from .providers import orchestrator
from .reasoning import analyze_performance, evaluate_execution, plan_goal
from .research import synthesize
from .rust_client import heavy_compute
from .video import build_formation_video

logger = logging.getLogger("python-ia")


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    if not os.getenv("IA_SERVICE_TOKEN", ""):
        logger.warning(
            "IA_SERVICE_TOKEN non défini : le service python-ia accepte les requêtes "
            "SANS authentification (acceptable uniquement en développement local)."
        )
    yield


app = FastAPI(title="SOULBAH IA Service", version="0.2.0", lifespan=_lifespan)

# Dossier partagé où les vidéos produites sont écrites (servi par Node sous /media).
MEDIA_DIR = os.path.realpath(
    os.getenv("MEDIA_DIR", os.path.join(os.path.dirname(__file__), "..", "..", "media"))
)
os.makedirs(MEDIA_DIR, exist_ok=True)

# ---------------------------------------------------------------------------
# Authentification service-à-service (Node -> Python).
# Si IA_SERVICE_TOKEN est défini, toute route sauf GET /health exige l'en-tête
# x-ia-token identique (comparaison en temps constant). Sinon : dev local, ouvert.
# ---------------------------------------------------------------------------
TOKEN_HEADER = "x-ia-token"
# Taille maximale d'un corps de requête (les captures base64 de /agent/evaluate
# sont les plus lourdes).
MAX_BODY_BYTES = int(os.getenv("IA_MAX_BODY_BYTES", str(40 * 1024 * 1024)))


def _service_token() -> str:
    return os.getenv("IA_SERVICE_TOKEN", "")


@app.middleware("http")
async def _guard(request: Request, call_next):
    if not (request.method == "GET" and request.url.path == "/health"):
        expected = _service_token()
        if expected:
            provided = request.headers.get(TOKEN_HEADER, "")
            if not hmac.compare_digest(provided.encode("utf-8"), expected.encode("utf-8")):
                return JSONResponse(status_code=401, content={"detail": "Jeton de service invalide"})
    length = request.headers.get("content-length")
    if length is not None:
        try:
            too_big = int(length) > MAX_BODY_BYTES
        except ValueError:
            return JSONResponse(status_code=400, content={"detail": "Content-Length invalide"})
        if too_big:
            return JSONResponse(status_code=413, content={"detail": "Requête trop volumineuse"})
    return await call_next(request)


# ---------------------------------------------------------------------------
# Bornes de validation des entrées
# ---------------------------------------------------------------------------
ShortStr = Annotated[str, StringConstraints(max_length=2_000)]
TextStr = Annotated[str, StringConstraints(max_length=20_000)]
LongStr = Annotated[str, StringConstraints(max_length=100_000)]
ProviderId = Annotated[str, StringConstraints(max_length=50)]
# Capture JPEG base64 (~6 Mo de texte max par image).
ScreenshotB64 = Annotated[str, StringConstraints(max_length=6 * 1024 * 1024)]


def _media_path(prefix: str, formation_id: UUID, ext: str) -> tuple[str, str]:
    """Construit un chemin de sortie SÛR dans MEDIA_DIR.

    formation_id est un UUID validé par pydantic (str(UUID) = forme canonique, sans
    séparateur de chemin) ; on vérifie en plus que le chemin résolu reste dans MEDIA_DIR.
    """
    filename = f"{prefix}_{formation_id}.{ext}"
    out_path = os.path.realpath(os.path.join(MEDIA_DIR, filename))
    if os.path.dirname(out_path) != MEDIA_DIR:
        raise HTTPException(status_code=400, detail="Chemin de sortie invalide")
    return filename, out_path


class InferRequest(BaseModel):
    text: TextStr


class InferResponse(BaseModel):
    label: str
    score: float
    compute: dict


class FormationRequest(BaseModel):
    topic: ShortStr
    details: TextStr | None = None
    provider: ProviderId | None = None  # imposer un fournisseur d'IA (optionnel)


class ApplicationRequest(BaseModel):
    appName: ShortStr
    appDesc: TextStr | None = None
    conversationHistory: list[dict] | None = Field(default=None, max_length=100)
    existingArchitecture: dict | None = None
    provider: ProviderId | None = None


@app.get("/health")
async def health():
    return {"status": "ok", "service": "python-ia"}


@app.get("/providers")
async def providers():
    """État de l'orchestration multi-fournisseurs : modèles configurés + routage."""
    return orchestrator.status()


@app.get("/agents")
async def agents():
    """Liste des agents spécialisés pilotés par le cerveau central."""
    return {"agents": [{"id": k, **v} for k, v in AGENTS.items()]}


class RouteRequest(BaseModel):
    request: TextStr
    provider: ProviderId | None = None


@app.post("/orchestrator/route")
async def orchestrator_route(req: RouteRequest):
    """Cerveau central : classe la demande et désigne l'agent spécialisé."""
    if not req.request.strip():
        raise HTTPException(status_code=400, detail="request vide")
    try:
        decision = await route_request(req.request, req.provider)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    return {"decision": decision}


# ---------------------------------------------------------------------------
# Démo (Node → Python → Rust)
# ---------------------------------------------------------------------------
@app.post("/infer", response_model=InferResponse)
async def infer(req: InferRequest):
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="text vide")

    features = [float(ord(c) % 97) for c in text[:64]] or [0.0]
    positives = sum(
        w in text.lower() for w in ("bon", "super", "génial", "aime", "excellent")
    )
    negatives = sum(
        w in text.lower() for w in ("mauvais", "nul", "déteste", "horrible", "bug")
    )
    label = "positif" if positives >= negatives else "négatif"
    score = round((positives + 1) / (positives + negatives + 2), 4)
    compute = await heavy_compute(features)
    return InferResponse(label=label, score=score, compute=compute)


# ---------------------------------------------------------------------------
# Génération IA (migré depuis les edge functions) — sans état, pas d'accès DB.
# Node vérifie l'auth, persiste le résultat et journalise.
# ---------------------------------------------------------------------------
@app.post("/generate/formation")
async def gen_formation(req: FormationRequest):
    try:
        formation = await generate_formation(req.topic, req.details, req.provider)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    except ValueError as e:
        raise HTTPException(status_code=502, detail=str(e))
    return {"formation": formation}


@app.post("/generate/application")
async def gen_application(req: ApplicationRequest):
    try:
        application = await generate_application(
            req.appName, req.appDesc, req.conversationHistory, req.existingArchitecture, req.provider
        )
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    except ValueError as e:
        raise HTTPException(status_code=502, detail=str(e))
    return {"application": application}


# ---------------------------------------------------------------------------
# Moteur de raisonnement (objectif → plan ; rapport → verdict/correction)
# ---------------------------------------------------------------------------
class PlanRequest(BaseModel):
    goal: TextStr
    context: LongStr | None = None


class EvaluateRequest(BaseModel):
    goal: TextStr
    steps: list[dict] = Field(max_length=200)
    result: dict
    # captures base64 (vision) prises pendant l'exécution
    screenshots: list[ScreenshotB64] | None = Field(default=None, max_length=10)


@app.post("/agent/plan")
async def agent_plan(req: PlanRequest):
    goal = req.goal.strip()
    if not goal:
        raise HTTPException(status_code=400, detail="goal vide")
    try:
        plan = await plan_goal(goal, req.context)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    return {"plan": plan}


@app.post("/agent/evaluate")
async def agent_evaluate(req: EvaluateRequest):
    try:
        evaluation = await evaluate_execution(req.goal, req.steps, req.result, req.screenshots)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    return {"evaluation": evaluation}


class FormationVideoRequest(BaseModel):
    formationId: UUID
    title: ShortStr
    lessons: list[dict] = Field(max_length=100)
    max_slides: int | None = Field(default=None, ge=1, le=500)


# `def` (et non `async def`) : production entièrement synchrone (httpx bloquant +
# moviepy/ffmpeg) -> FastAPI l'exécute dans le threadpool sans bloquer la boucle.
@app.post("/generate/formation-video")
def gen_formation_video(req: FormationVideoRequest):
    if not req.lessons:
        raise HTTPException(status_code=400, detail="Aucune leçon à mettre en vidéo")
    filename, out_path = _media_path("formation", req.formationId, "mp4")
    try:
        info = build_formation_video(req.title, req.lessons, out_path, req.max_slides)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    except Exception as e:  # noqa: BLE001
        logger.exception("Échec production vidéo")
        raise HTTPException(status_code=500, detail=f"Échec production vidéo : {e}")
    return {"filename": filename, "slides": info["slides"], "duration_s": info["duration_s"]}


class AnalyzeFormationRequest(BaseModel):
    topic: ShortStr
    details: TextStr | None = None
    provider: ProviderId | None = None


class ProgramRequest(BaseModel):
    analysis: dict
    research_notes: list[dict] = Field(default_factory=list, max_length=100)
    provider: ProviderId | None = None


class ModuleRequest(BaseModel):
    program_title: ShortStr
    module: dict
    research_notes: list[dict] = Field(default_factory=list, max_length=100)
    provider: ProviderId | None = None


@app.post("/formation/analyze")
async def formation_analyze(req: AnalyzeFormationRequest):
    if not req.topic.strip():
        raise HTTPException(status_code=400, detail="topic vide")
    try:
        analysis = await analyze_request(req.topic, req.details, req.provider)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    return {"analysis": analysis}


@app.post("/formation/program")
async def formation_program(req: ProgramRequest):
    try:
        program = await build_program(req.analysis, req.research_notes, req.provider)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    return {"program": program}


@app.post("/formation/module")
async def formation_module(req: ModuleRequest):
    try:
        detail = await build_module(req.program_title, req.module, req.research_notes, req.provider)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    return {"module": detail}


class FormationPdfRequest(BaseModel):
    formationId: UUID
    curriculum: dict


# `def` : génération PDF (fpdf2) synchrone et CPU-bound -> threadpool.
@app.post("/formation/pdf")
def formation_pdf(req: FormationPdfRequest):
    filename, out_path = _media_path("formation", req.formationId, "pdf")
    try:
        info = build_formation_pdf(req.curriculum, out_path)
    except Exception as e:  # noqa: BLE001
        logger.exception("Échec génération PDF")
        raise HTTPException(status_code=500, detail=f"Échec génération PDF : {e}")
    return {"filename": filename, "pages": info["pages"]}


class SynthesizeRequest(BaseModel):
    query: TextStr
    sources: list[dict] = Field(default_factory=list, max_length=100)
    known: list[dict] | None = Field(default=None, max_length=100)
    domain: ShortStr | None = None
    provider: ProviderId | None = None


@app.post("/synthesize")
async def do_synthesize(req: SynthesizeRequest):
    if not req.query.strip():
        raise HTTPException(status_code=400, detail="query vide")
    try:
        synthesis = await synthesize(req.query, req.sources, req.known, req.domain, req.provider)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    return {"synthesis": synthesis}


class SelfImproveRequest(BaseModel):
    summary: LongStr


@app.post("/agent/self-improve")
async def agent_self_improve(req: SelfImproveRequest):
    try:
        report = await analyze_performance(req.summary)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    return {"report": report}
