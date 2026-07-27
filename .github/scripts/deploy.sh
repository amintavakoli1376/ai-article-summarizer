#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/article-summarizer"
cd "$APP_DIR"

echo "Starting deployment..."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

docker compose -f docker-compose.prod.yml pull || true
docker compose -f docker-compose.prod.yml up -d --build

echo "Waiting for API health check..."
for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then
    echo "API is healthy"
    break
  fi
  sleep 2
done

docker compose -f docker-compose.prod.yml ps
