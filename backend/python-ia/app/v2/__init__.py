"""API V2 de python-ia (audit §11 : `app/v2/` = API du routeur de modèles).

Les routeurs FastAPI de ce paquet sont montés par main.py sous le même middleware
(x-ia-token, taille du corps, x-deadline-ms, x-llm-usage) que les routes historiques.
"""
from fastapi import APIRouter

from .models import router as models_router
from .planner import router as planner_router

router = APIRouter(prefix="/v2")
router.include_router(models_router)
router.include_router(planner_router)

__all__ = ["router"]
