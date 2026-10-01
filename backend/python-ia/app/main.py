from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

import os

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

app = FastAPI(title="SOULBAH IA Service", version="0.2.0")

# Dossier partagé où les vidéos produites sont écrites (servi par Node sous /media).
MEDIA_DIR = os.getenv("MEDIA_DIR", os.path.join(os.path.dirname(__file__), "..", "..", "media"))
os.makedirs(MEDIA_DIR, exist_ok=True)


class InferRequest(BaseModel):
    text: str


class InferResponse(BaseModel):
    label: str
    score: float
    compute: dict


class FormationRequest(BaseModel):
    topic: str
    details: str | None = None
    provider: str | None = None  # imposer un fournisseur d'IA (optionnel)


class ApplicationRequest(BaseModel):
    appName: str
    appDesc: str | None = None
    conversationHistory: list[dict] | None = None
    existingArchitecture: dict | None = None
    provider: str | None = None


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
    request: str
    provider: str | None = None


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
    goal: str
    context: str | None = None


class EvaluateRequest(BaseModel):
    goal: str
    steps: list[dict]
    result: dict
    screenshots: list[str] | None = None  # captures base64 (vision) prises pendant l'exécution


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
    formationId: str
    title: str
    lessons: list[dict]
    max_slides: int | None = None


@app.post("/generate/formation-video")
async def gen_formation_video(req: FormationVideoRequest):
    if not req.lessons:
        raise HTTPException(status_code=400, detail="Aucune leçon à mettre en vidéo")
    filename = f"formation_{req.formationId}.mp4"
    out_path = os.path.join(MEDIA_DIR, filename)
    try:
        info = build_formation_video(req.title, req.lessons, out_path, req.max_slides)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Échec production vidéo : {e}")
    return {"filename": filename, "slides": info["slides"], "duration_s": info["duration_s"]}


class AnalyzeFormationRequest(BaseModel):
    topic: str
    details: str | None = None
    provider: str | None = None


class ProgramRequest(BaseModel):
    analysis: dict
    research_notes: list[dict] = []
    provider: str | None = None


class ModuleRequest(BaseModel):
    program_title: str
    module: dict
    research_notes: list[dict] = []
    provider: str | None = None


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
    formationId: str
    curriculum: dict


@app.post("/formation/pdf")
async def formation_pdf(req: FormationPdfRequest):
    filename = f"formation_{req.formationId}.pdf"
    out_path = os.path.join(MEDIA_DIR, filename)
    try:
        info = build_formation_pdf(req.curriculum, out_path)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Échec génération PDF : {e}")
    return {"filename": filename, "pages": info["pages"]}


class SynthesizeRequest(BaseModel):
    query: str
    sources: list[dict] = []
    known: list[dict] | None = None
    domain: str | None = None
    provider: str | None = None


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
    summary: str


@app.post("/agent/self-improve")
async def agent_self_improve(req: SelfImproveRequest):
    try:
        report = await analyze_performance(req.summary)
    except LLMError as e:
        raise HTTPException(status_code=e.status, detail=e.message)
    return {"report": report}
