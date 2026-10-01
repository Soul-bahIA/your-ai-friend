FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Utilisateur non-root (uid fixe pour les permissions du volume /media partagé).
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home app \
    && mkdir -p /app/media && chown app:app /app/media

# Dossier de sortie vidéos/PDF (inscriptible par l'utilisateur non-root ; à monter en
# volume partagé avec node-api pour servir /media).
ENV MEDIA_DIR=/app/media

COPY --chown=app:app app ./app

USER app

EXPOSE 8000
# Écoute sur 0.0.0.0 À L'INTÉRIEUR du conteneur uniquement (le port n'est pas publié
# par compose). Pas de --reload en production.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-server-header"]
