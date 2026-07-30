#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/article-summarizer"
cd "$APP_DIR"

export API_IMAGE_TAG="${API_IMAGE_TAG:-latest}"

echo "🚀 Starting zero-downtime deployment..."

echo "📥 Pulling latest API image..."
docker compose -f docker-compose.prod.yml pull api || true

echo "🔄 Scaling up API to 2 replicas..."
docker compose -f docker-compose.prod.yml up -d --no-deps --scale api=2

echo "⏳ Waiting for API health check..."
for i in $(seq 1 15); do
  if docker compose -f docker-compose.prod.yml exec -T api curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then
    echo "✅ API is healthy (attempt $i)"
    break
  fi
  if [ "$i" -eq 15 ]; then
    echo "❌ Health check failed — scaling back to 1 replica and exiting"
    docker compose -f docker-compose.prod.yml up -d --scale api=1
    exit 1
  fi
  sleep 2
done

echo "🧹 Scaling down API to 1 replica..."
docker compose -f docker-compose.prod.yml up -d --scale api=1

echo "🗄️ Running database migrations..."
docker compose -f docker-compose.prod.yml exec -T api alembic upgrade head || echo "⚠️ Migration skipped"

echo "🔄 Reloading Nginx..."
docker compose -f docker-compose.prod.yml exec -T nginx nginx -s reload 2>/dev/null || true

echo "🧹 Cleaning up unused images..."
docker image prune -f 2>/dev/null || true

echo "✅ Zero-downtime deployment complete!"
