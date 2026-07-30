#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/opt/article-summarizer"
BACKUP_DIR="${PROJECT_DIR}/backups"
RETENTION_DAYS=7
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "📦 Starting backup..."

docker exec summarizer-postgres pg_dumpall -c -U summarizer | gzip > "${BACKUP_DIR}/db_${TIMESTAMP}.sql.gz"
cp "$PROJECT_DIR/.env" "${BACKUP_DIR}/env_${TIMESTAMP}.bak"

find "$BACKUP_DIR" -name 'db_*.sql.gz' -mtime +$RETENTION_DAYS -delete
find "$BACKUP_DIR" -name 'env_*.bak' -mtime +$RETENTION_DAYS -delete

echo "✅ Backup complete: ${BACKUP_DIR}/db_${TIMESTAMP}.sql.gz"
