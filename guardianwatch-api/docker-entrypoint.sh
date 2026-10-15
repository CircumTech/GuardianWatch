#!/bin/sh
# Runs migrations before the server starts, every container start.
# `alembic upgrade head` is idempotent — a no-op if already current — so
# this is safe on every deploy and every restart, not just the first one.
# Safe for a single-instance deployment (Render's "starter" plan, this
# project's target); if this ever runs as multiple concurrent replicas,
# move this to a separate one-off release step instead, so N containers
# don't all race to migrate at once on a rolling deploy.
set -e

echo "Running database migrations..."
alembic upgrade head

echo "Starting server..."
# `exec` here (not just running uvicorn as a plain command) replaces this
# shell process with uvicorn, so uvicorn becomes PID 1 and receives
# SIGTERM directly from Docker/Render on shutdown — without it, the shell
# swallows the signal and the container has to be force-killed after its
# grace period instead of stopping cleanly.
exec uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8080}"
