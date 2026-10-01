from __future__ import annotations

import hmac
import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from typing import Annotated
from uuid import UUID

import anyio
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, StringConstraints
from starlette.datastructures import Headers
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import request_context
from .agents import AGENTS, route_request
from .config import check_startup_config, service_token, soulbah_env
from .formation import analyze_request, build_module, build_program
from .generation import generate_application, generate_formation
from .llm import LLMError
from .pdf import build_formation_pdf
from .providers import orchestrator
from .reasoning import analyze_performance, evaluate_execution, plan_goal
from .research import synthesize
from .rust_client import ComputeUnavailable, heavy_compute
from .video import VideoCancelled, build_formation_video

logger = logging.getLogger("python-ia")


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    # S14 / contrat §1 : hors dev/test, refus de démarrer sans IA_SERVICE_TOKEN
    # (RuntimeError -> uvicorn s'arrête avec un message explicite).
    for warning in check_startup_config():
        logger.warning(warning)
    logger.info("python-ia démarré (SOULBAH_ENV=%s)", soulbah_env())
    yield


app = FastAPI(title="SOULBAH IA Service", version="0.3.0", lifespan=_lifespan)

# Dossier partagé où les vidéos produites sont écrites (servi par Node sous /media).
MEDIA_DIR = os.path.realpath(
    os.getenv("MEDIA_DIR", os.path.join(os.path.dirname(__file__), "..", "..", "media"))
)
os.makedirs(MEDIA_DIR, exist_ok=True)

# ---------------------------------------------------------------------------
# Garde inter-services (middleware ASGI pur, pas BaseHTTPMiddleware) :
#  - x-ia-token : si IA_SERVICE_TOKEN est défini, toute route sauf GET /health exige
#    l'en-tête identique (comparaison en temps constant). Sans token : dev/test only
#    (hors dev/test, le service refuse de démarrer, cf. config.check_startup_config).
#  - taille du corps : Content-Length annoncé ET octets réellement reçus (S29 : un
#    corps chunked sans Content-Length est compté au fil de l'eau -> 413).
#  - x-deadline-ms : budget restant (ms) de l'appelant -> délais LLM alignés.
#  - x-llm-usage : en-tête de réponse JSON {calls,input_tokens,output_tokens,models}
#    quand la requête a fait au moins un appel LLM (métrage, informatif).
# ---------------------------------------------------------------------------
TOKEN_HEADER = "x-ia-token"
# Taille maximale d'un corps de requête (les captures base64 de /agent/evaluate
# sont les plus lourdes).
MAX_BODY_BYTES = int(os.getenv("IA_MAX_BODY_BYTES", str(40 * 1024 * 1024)))


def _service_token() -> str:
    return service_token()


class BodyTooLarge(StarletteHTTPException):
    def __init__(self) -> None:
        super().__init__(status_code=413, detail="Requête trop volumineuse")


async def _send_json(send, status: int, detail: str) -> None:
    body = json.dumps({"detail": detail}, ensure_ascii=False).encode("utf-8")
    await send({
        "type": "http.response.start",
        "status": status,
        "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())],
    })
    await send({"type": "http.response.body", "body": body})


class ServiceGuardMiddleware:
    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        headers = Headers(scope=scope)

        if not (scope["method"] == "GET" and scope["path"] == "/health"):
            expected = _service_token()
            if expected:
                provided = headers.get(TOKEN_HEADER, "")
                if not hmac.compare_digest(provided.encode("utf-8"), expected.encode("utf-8")):
                    await _send_json(send, 401, "Jeton de service invalide")
                    return

        limit = MAX_BODY_BYTES
        length = headers.get("content-length")
        if length is not None:
            try:
                too_big = int(length) > limit
            except ValueError:
                await _send_json(send, 400, "Content-Length invalide")
                return
            if too_big:
                await _send_json(send, 413, "Requête trop volumineuse")
                return

        try:
            deadline_ms = request_context.parse_deadline_ms(headers.get(request_context.DEADLINE_HEADER))
        except ValueError:
            await _send_json(send, 400, "En-tête x-deadline-ms invalide (entier > 0 attendu)")
            return

        received = 0

        async def limited_receive():
            nonlocal received
            message = await receive()
            if message.get("type") == "http.request":
                received += len(message.get("body", b"") or b"")
                if received > limit:
                    raise BodyTooLarge()
            return message

        started = False

        async def send_with_usage(message):
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
                summary = request_context.usage_summary()
                if summary:
                    message = dict(message)
                    message["headers"] = list(message.get("headers", [])) + [
                        (request_context.USAGE_HEADER.encode("latin-1"), json.dumps(summary).encode("latin-1"))
                    ]
            await send(message)

        tokens = request_context.begin_request(deadline_ms)
        try:
            await self.app(scope, limited_receive, send_with_usage)
        except BodyTooLarge:
            # Filet de sécurité : normalement converti en 413 par FastAPI.
            if not started:
                await _send_json(send, 413, "Requête trop volumineuse")
        finally:
            request_context.end_request(tokens)


app.add_middleware(ServiceGuardMiddleware)


# ---------------------------------------------------------------------------
# Erreurs (S23) : jamais de texte d'exception interne ni de corps amont vers le
# client. Les messages d'LLMError sont construits pour être exposables ; tout le
# reste est journalisé avec une référence courte renvoyée au client.
# ---------------------------------------------------------------------------
def _error_ref() -> str:
    return uuid.uuid4().hex[:12]


@app.exception_handler(LLMError)
async def _llm_error_handler(_request: Request, exc: LLMError):
    return JSONResponse(status_code=exc.status, content={"detail": exc.message})


@app.exception_handler(ComputeUnavailable)
async def _compute_unavailable_handler(_request: Request, exc: ComputeUnavailable):
    return JSONResponse(status_code=503, content={"detail": exc.message})


@app.exception_handler(Exception)
async def _unhandled_error_handler(_request: Request, exc: Exception):
    ref = _error_ref()
    logger.error("Erreur interne non gérée (réf. %s)", ref, exc_info=exc)
    return JSONResponse(status_code=500, content={"detail": f"Erreur interne du service IA (réf. {ref})"})


def _internal_error(what: str) -> HTTPException:
    """Journalise l'exception courante et renvoie une 500 générique référencée."""
    ref = _error_ref()
    logger.exception("%s (réf. %s)", what, ref)
    return HTTPException(status_code=500, detail=f"{what} (réf. {ref})")


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


# `provider` (optionnel, tous les modèles ci-dessous) : impose un fournisseur d'IA.
# Accepté UNIQUEMENT s'il figure dans LLM_ALLOWED_OVERRIDES (vide par défaut) ;
# sinon 400 (S32).
class FormationRequest(BaseModel):
    topic: ShortStr
    details: TextStr | None = None
    provider: ProviderId | None = None


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
    """État de l'orchestration multi-fournisseurs : modèles, capacités, profils,
    overrides autorisés, disjoncteurs."""
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
    decision = await route_request(req.request, req.provider)
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
    # rust-compute injoignable -> ComputeUnavailable -> 503 (jamais 500).
    compute = await heavy_compute(features)
    return InferResponse(label=label, score=score, compute=compute)


# ---------------------------------------------------------------------------
# Génération IA (migré depuis les edge functions) — sans état, pas d'accès DB.
# Node vérifie l'auth, persiste le résultat et journalise.
# Les LLMError sont converties par _llm_error_handler (statut + message sûr).
# ---------------------------------------------------------------------------
@app.post("/generate/formation")
async def gen_formation(req: FormationRequest):
    try:
        formation = await generate_formation(req.topic, req.details, req.provider)
    except ValueError:
        logger.warning("Formation générée invalide", exc_info=True)
        raise HTTPException(status_code=502, detail="Réponse IA invalide (formation)")
    return {"formation": formation}


@app.post("/generate/application")
async def gen_application(req: ApplicationRequest):
    try:
        application = await generate_application(
            req.appName, req.appDesc, req.conversationHistory, req.existingArchitecture, req.provider
        )
    except ValueError:
        logger.warning("Application générée invalide", exc_info=True)
        raise HTTPException(status_code=502, detail="Réponse IA invalide (application)")
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
    plan = await plan_goal(goal, req.context)
    return {"plan": plan}


@app.post("/agent/evaluate")
async def agent_evaluate(req: EvaluateRequest):
    """Verdicts : success | retry | abort | not_evaluable (run simulé, plan vide,
    tâche annulée ou 0 étape exécutée : aucun appel LLM, `evaluable: false`)."""
    evaluation = await evaluate_execution(req.goal, req.steps, req.result, req.screenshots)
    return {"evaluation": evaluation}


class FormationVideoRequest(BaseModel):
    formationId: UUID
    title: ShortStr
    lessons: list[dict] = Field(max_length=100)
    max_slides: int | None = Field(default=None, ge=1, le=500)


def _cancel_checker(request: Request):
    """Fonction d'annulation pour un endpoint `def` (exécuté dans un thread AnyIO) :
    vrai si l'échéance x-deadline-ms est dépassée ou si le client s'est déconnecté
    (node a abandonné : inutile de continuer à payer des TTS)."""

    def should_cancel() -> bool:
        if request_context.deadline_exceeded():
            return True
        try:
            return bool(anyio.from_thread.run(request.is_disconnected))
        except Exception:  # noqa: BLE001 — hors thread AnyIO / boucle fermée
            return False

    return should_cancel


# `def` (et non `async def`) : production entièrement synchrone (httpx bloquant +
# moviepy/ffmpeg) -> FastAPI l'exécute dans le threadpool sans bloquer la boucle.
@app.post("/generate/formation-video")
def gen_formation_video(req: FormationVideoRequest, request: Request):
    if not req.lessons:
        raise HTTPException(status_code=400, detail="Aucune leçon à mettre en vidéo")
    filename, out_path = _media_path("formation", req.formationId, "mp4")
    try:
        info = build_formation_video(
            req.title, req.lessons, out_path, req.max_slides, should_cancel=_cancel_checker(request)
        )
    except LLMError:
        raise
    except VideoCancelled:
        timed_out = request_context.deadline_exceeded()
        logger.info("Production vidéo annulée (%s) : %s", "échéance" if timed_out else "client parti",
                    req.formationId)
        raise HTTPException(status_code=504 if timed_out else 499, detail="Production vidéo annulée")
    except Exception:  # noqa: BLE001
        raise _internal_error("Échec production vidéo")
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
    analysis = await analyze_request(req.topic, req.details, req.provider)
    return {"analysis": analysis}


@app.post("/formation/program")
async def formation_program(req: ProgramRequest):
    program = await build_program(req.analysis, req.research_notes, req.provider)
    return {"program": program}


@app.post("/formation/module")
async def formation_module(req: ModuleRequest):
    detail = await build_module(req.program_title, req.module, req.research_notes, req.provider)
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
    except Exception:  # noqa: BLE001
        raise _internal_error("Échec génération PDF")
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
    synthesis = await synthesize(req.query, req.sources, req.known, req.domain, req.provider)
    return {"synthesis": synthesis}


class SelfImproveRequest(BaseModel):
    summary: LongStr


@app.post("/agent/self-improve")
async def agent_self_improve(req: SelfImproveRequest):
    report = await analyze_performance(req.summary)
    return {"report": report}
