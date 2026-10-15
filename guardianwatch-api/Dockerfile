# GuardianWrist API — production image.
#
# Built for Render (see render.yaml) — also runs unchanged on Cloud Run
# or anywhere else that takes a container and sets $PORT:
# `docker run -p 8080:8080 <image>`.

FROM python:3.12-slim

WORKDIR /app

# System deps: none of the pinned Python packages need compilation on
# python:3.12-slim (asyncpg, ai-edge-litert, xgboost all ship manylinux
# wheels) — kept minimal on purpose. Add build-essential here first if you
# introduce a dependency that needs to compile from source.

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY alembic ./alembic
COPY alembic.ini .
COPY docker-entrypoint.sh .
RUN chmod +x docker-entrypoint.sh

# Cloud Run / Render both set $PORT; default 8080 covers `docker run`
# without it.
ENV PORT=8080
ENV ENV=production
EXPOSE 8080

# Single stage, no reload, one worker per container — scale via
# Cloud Run / Render's instance count, not in-process workers, so each
# instance's ModelRegistry (loaded once at startup) stays a predictable
# memory cost.
ENTRYPOINT ["./docker-entrypoint.sh"]
