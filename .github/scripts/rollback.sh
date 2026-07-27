#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/article-summarizer"
cd "$APP_DIR"

REASON="${1:-No reason provided}"
echo "Rolling back deployment: $REASON"

docker compose -f docker-compose.prod.yml down || true
docker compose -f docker-compose.prod.yml up -d --build || true

echo "Rollback completed."
