#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/article-summarizer"
cd "$APP_DIR"

IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"
IMAGE_NAME="${IMAGE_NAME:-amintavakoli1376/article-summarizer}"
COMMAND="${1:-latest}"

usage() {
  cat <<EOF
Usage: $0 [tag]
       $0 latest          # rollback to the latest published image
       $0 1234567         # rollback to a specific image tag
       $0 --list          # list available local images
       $0 --dry-run       # show actions without changing anything
       $0 --help          # show this help
EOF
}

if [[ "$COMMAND" == "--help" || "$COMMAND" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "$COMMAND" == "--list" ]]; then
  docker images "$IMAGE_REGISTRY/$IMAGE_NAME" --format "{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}\t{{.Size}}"
  exit 0
fi

if [[ "$COMMAND" == "--dry-run" ]]; then
  echo "DRY RUN: rollback API using image tag latest"
  echo "Would pull $IMAGE_REGISTRY/$IMAGE_NAME:latest and scale api=2"
  exit 0
fi

IMAGE_TAG="$COMMAND"
IMAGE="$IMAGE_REGISTRY/$IMAGE_NAME:$IMAGE_TAG"

echo "⏪ Rolling back API to image: $IMAGE"

docker pull "$IMAGE"

echo "🔄 Starting rollback deployment..."
API_IMAGE_TAG="$IMAGE_TAG" docker compose -f docker-compose.prod.yml up -d --no-deps --scale api=2

echo "⏳ Waiting for API health check..."
for i in $(seq 1 15); do
  if docker compose -f docker-compose.prod.yml exec -T api curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then
    echo "✅ API healthy after rollback (attempt $i)"
    break
  fi
  if [ "$i" -eq 15 ]; then
    echo "❌ Health check failed after rollback"
    docker compose -f docker-compose.prod.yml logs api --tail=50
    exit 1
  fi
  sleep 2
done

echo "🧹 Scaling down API to 1 replica..."
API_IMAGE_TAG="$IMAGE_TAG" docker compose -f docker-compose.prod.yml up -d --scale api=1

echo "✅ Rollback complete."
