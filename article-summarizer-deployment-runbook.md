# Deployment Runbook — Article Summarizer
## Complete Deployment & Recovery Procedures

---

**نسخه:** 1.0  
**تاریخ:** جولای 2026  
**وضعیت:** ✓ Ready for Production  

---

## ۱. Deployment Overview

### معماری

```
GitHub → Push to main
    ↓
GitHub Actions → SSH
    ↓
Hetzner VPS → Docker Compose
    ↓
API (x2) · Frontend · PostgreSQL · Redis · Nginx
```

### فایل‌های مهم

| فایل | مسیر روی سرور |
|------|--------------|
| `docker-compose.prod.yml` | `/opt/article-summarizer/docker-compose.prod.yml` |
| `.env` | `/opt/article-summarizer/.env` |
| `deploy.sh` | `/opt/article-summarizer/scripts/deploy.sh` |
| `rollback.sh` | `/opt/article-summarizer/scripts/rollback.sh` |
| `docker-compose.dev.yml` | ریپو — فقط برای توسعه |

---

## ۲. Normal Deployment (دپلوی معمولی)

### ۲.۱ Automatic (CI/CD)

```
Event: Merge to main
   ↓
GitHub Actions: deploy.yml
   ↓
1. Checkout code
2. SCP files → /opt/article-summarizer
3. SSH → bash deploy.sh
4. Health check → ✅
   ↓
Done
```

**زمان:** ~۲ دقیقه  
**قطع سرویس:** ۰ ثانیه (zero-downtime)

### ۲.۲ Manual Deployment (دستی)

اگه CI/CD کار نکرد:

```bash
# ۱. SSH به سرور
ssh deploy@hetzner-ip

# ۲. برو به پوشه پروژه
cd /opt/article-summarizer

# ۳. Pull latest from GitHub
git pull origin main

# ۴. Build و Restart
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml up -d

# ۵. Migration
docker compose -f docker-compose.prod.yml exec -T api alembic upgrade head

# ۶. Health check
curl -sSf http://localhost:8000/health
```

---

## ۳. Rollback Script

فایل `scripts/rollback.sh`:

```bash
#!/bin/bash
# ⏪ Rollback Script — Article Summarizer
# Usage: bash rollback.sh [version]
#        bash rollback.sh latest-1    (یک نسخه قبل)
#        bash rollback.sh sha-abc123  (نسخه خاص)
#        bash rollback.sh --list      (نمایش نسخه‌های موجود)

set -euo pipefail

PROJECT_DIR="/opt/article-summarizer"
LOG_FILE="${PROJECT_DIR}/logs/rollback.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "${PROJECT_DIR}/logs"

log() {
    echo -e "$TIMESTAMP — $1" | tee -a "$LOG_FILE"
}

# ─── نمایش راهنما ─────────────────────────────────────────
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "⏪ Rollback Script — Article Summarizer"
    echo ""
    echo "Usage:"
    echo "  bash rollback.sh latest-1       Rollback to previous version"
    echo "  bash rollback.sh sha-abc123     Rollback to specific version"
    echo "  bash rollback.sh --list         List available versions"
    echo "  bash rollback.sh --dry-run      Simulate rollback"
    echo ""
    exit 0
fi

# ─── نمایش نسخه‌های موجود ─────────────────────────────────
if [ "$1" = "--list" ]; then
    echo "📋 Available Docker images:"
    docker images ghcr.io/*/article-summarizer --format "table {{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
    echo ""
    echo "📋 Saved deploys:"
    ls -la "${PROJECT_DIR}/deploys/" 2>/dev/null || echo "  No saved deploys found"
    exit 0
fi

# ─── Dry run ────────────────────────────────────────────────
if [ "$1" = "--dry-run" ]; then
    echo "⏪ DRY RUN — Nothing will be changed"
    echo "  Would rollback API containers"
    echo "  Would restart services"
    echo "  Would run health check"
    exit 0
fi

# ─── Main Rollback ─────────────────────────────────────────
VERSION="${1:-latest-1}"
log "⏪ Starting rollback to: $VERSION"

cd "$PROJECT_DIR"

# 1. Save current state for re-rollback
log "📝 Saving current state..."
CURRENT_SHA=$(docker images ghcr.io/*/article-summarizer --format "{{.Tag}}" | head -1)
mkdir -p deploys
echo "$CURRENT_SHA" > "deploys/pre-rollback-$(date +%Y%m%d%H%M).txt"
log "  Current version: $CURRENT_SHA"

# 2. Pull the target version
log "📥 Pulling target version: $VERSION"
docker pull "ghcr.io/amintavakoli1376/article-summarizer:$VERSION" || {
    log "❌ Failed to pull version: $VERSION"
    echo "  Available versions:"
    docker images ghcr.io/*/article-summarizer --format "table {{.Tag}}"
    exit 1
}

# 3. Tag the target as current
log "🏷️ Tagging image..."
docker tag "ghcr.io/amintavakoli1376/article-summarizer:$VERSION" \
         "ghcr.io/amintavakoli1376/article-summarizer:current"

# 4. Restart with old version (zero-downtime)
log "🔄 Restarting services..."
docker compose -f docker-compose.prod.yml up -d --no-deps --scale api=2 || {
    log "❌ Failed to start new containers"
    exit 1
}

# 5. Health check
log "⏳ Running health check..."
HEALTH_PASSED=false
for i in $(seq 1 15); do
    if curl -sSf http://localhost:8000/health > /dev/null 2>&1; then
        HEALTH_PASSED=true
        log "✅ Health check passed (attempt $i)"
        break
    fi
    sleep 2
done

if [ "$HEALTH_PASSED" = false ]; then
    log "❌ Health check failed after rollback!"
    log "🔄 Attempting to restore original version..."

    docker tag "ghcr.io/amintavakoli1376/article-summarizer:$CURRENT_SHA" \
               "ghcr.io/amintavakoli1376/article-summarizer:current"
    docker compose -f docker-compose.prod.yml up -d --no-deps --scale api=2

    log "⚠️ Rollback also failed — manual intervention needed!"
    echo ""
    echo "🔴 MANUAL INTERVENTION REQUIRED"
    echo "  SSH to server: ssh deploy@hetzner-ip"
    echo "  Check logs: docker compose logs api"
    echo "  Or restore from backup: bash rollback.sh $CURRENT_SHA"
    exit 1
fi

# 6. Scale down to single instance
log "🧹 Scaling down..."
docker compose -f docker-compose.prod.yml up -d --scale api=1

# 7. Run migrations if needed
log "🗄️ Running migrations..."
docker compose -f docker-compose.prod.yml exec -T api alembic upgrade head 2>/dev/null || \
    log "  ⚠️ Migration skipped or failed"

# 8. Reload Nginx
log "🔄 Reloading Nginx..."
docker compose -f docker-compose.prod.yml exec -T nginx nginx -s reload 2>/dev/null || true

# 9. Cleanup
log "🧹 Cleaning up..."
docker image prune -f > /dev/null 2>&1 || true

log "✅ Rollback to $VERSION completed successfully!"
echo ""
echo "📋 Rollback Summary:"
echo "  From: $CURRENT_SHA"
echo "  To:   $VERSION"
echo "  Time: $(date '+%Y-%m-%d %H:%M:%S')"
```

---

## ۴. Recovery Procedures

### ۴.۱ 🔴 Critical: API Down

| Step | Action | Command |
|------|--------|---------|
| ۱ | Check if Docker is running | `docker info` |
| ۲ | Check container status | `docker ps -a` |
| ۳ | View logs | `docker compose logs api --tail=50` |
| ۴ | Restart API | `docker compose restart api` |
| ۵ | Full restart if needed | `docker compose down && docker compose up -d` |
| ۶ | Rollback if new code broke | `bash rollback.sh latest-1` |

### ۴.۲ 🟡 High: Database Issues

| Step | Action | Command |
|------|--------|---------|
| ۱ | Check PostgreSQL status | `docker compose ps postgres` |
| ۲ | View DB logs | `docker compose logs postgres --tail=30` |
| ۳ | Check disk space | `df -h` |
| ۴ | Restart PostgreSQL | `docker compose restart postgres` |
| ۵ | Restore from backup | `cat backup.sql \| docker exec -i summarizer-postgres psql -U summarizer` |

### ۴.۳ 🟡 High: SSL Certificate Expired

```bash
# Manual SSL renew
docker compose exec certbot certbot renew
docker compose exec nginx nginx -s reload
```

### ۴.۴ 🟢 Medium: Nginx Issues

```bash
# Check config
docker compose exec nginx nginx -t

# Reload
docker compose exec nginx nginx -s reload

# Restart
docker compose restart nginx
```

### ۴.۵ 🟢 Medium: Full Server Halt

```bash
# ۱. SSH to Hetzner Console (out-of-band)

# ۲. Check system
htop
df -h
free -m

# ۳. Start Docker if not running
sudo systemctl start docker

# ۴. Start all services
cd /opt/article-summarizer
docker compose -f docker-compose.prod.yml up -d

# ۵. Verify
curl -sSf http://localhost:8000/health
```

---

## ۵. Backup & Restore

### ۵.۱ Automated Backup (Cron Job)

```bash
# روی سرور: /etc/cron.d/article-summarizer
0 3 * * * deploy /opt/article-summarizer/scripts/backup.sh
```

فایل `scripts/backup.sh`:

```bash
#!/bin/bash
# 📦 Database Backup Script

BACKUP_DIR="/opt/article-summarizer/backups"
RETENTION_DAYS=7
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

# Backup PostgreSQL
docker exec summarizer-postgres pg_dumpall -c -U summarizer \
  | gzip > "${BACKUP_DIR}/db_${TIMESTAMP}.sql.gz"

# Backup .env
cp /opt/article-summarizer/.env "${BACKUP_DIR}/env_${TIMESTAMP}.bak"

# Clean old backups
find "$BACKUP_DIR" -name "db_*.sql.gz" -mtime +$RETENTION_DAYS -delete
find "$BACKUP_DIR" -name "env_*.bak" -mtime +$RETENTION_DAYS -delete

echo "✅ Backup complete: db_${TIMESTAMP}.sql.gz"
```

### ۵.۲ Manual Restore

```bash
# List backups
ls -la /opt/article-summarizer/backups/

# Restore database
gunzip -c /opt/article-summarizer/backups/db_20260726_030000.sql.gz | \
  docker exec -i summarizer-postgres psql -U summarizer
```

---

## ۶. Monitoring & Alerts

### ۶.۱ لاگ‌های مهم

| Log | Location | Size Limit |
|-----|----------|-----------|
| Docker logs | `docker compose logs` | 10MB per service |
| Nginx access | `/var/log/nginx/access.log` | Rotated weekly |
| Nginx error | `/var/log/nginx/error.log` | Rotated weekly |
| Rollback history | `logs/rollback.log` | Appended |

### ۶.۲ دستورات سریع

```bash
# Check all services
docker compose ps

# View logs (all)
docker compose logs --tail=50 -f

# View logs (specific service)
docker compose logs api --tail=100

# Real-time API log tail
docker compose logs api -f

# Resource usage
docker stats --no-stream

# Disk
df -h /opt/
```

---

## ۷. نکات امنیتی

| نکته | توضیح |
|------|-------|
| 🔑 **SSH Key Only** | رمز ورود غیرفعاله |
| 🔒 **UFW** | فقط ۲۲, ۸۰, ۴۴۳ |
| 🛡️ **Fail2ban** | ۵ بار اشتباه = ۱ ساعت ban |
| 📝 **لاگ‌ها** | ۷ روز نگهداری |
| 🔄 **Backup** | روزانه ۳ صبح |
| ⏪ **Rollback** | همیشه ورژن قبلی保留 |

---

## ۸. Quick Reference Card

### 🚀 Deploy

```bash
# Automatic: Merge to main در GitHub
# Manual:
ssh deploy@hetzner-ip
cd /opt/article-summarizer
git pull
docker compose up -d --build
```

### ⏪ Rollback

```bash
bash scripts/rollback.sh latest-1
bash scripts/rollback.sh --list
```

### 📊 Health Check

```bash
curl https://example.com/health
docker compose ps
docker stats --no-stream
```

### 💾 Backup & Restore

```bash
# Backup
bash scripts/backup.sh

# Restore
gunzip -c backups/db_*.sql.gz | docker exec -i summarizer-postgres psql -U summarizer
```

### 🔍 Troubleshooting

```bash
# P1: API down
docker compose logs api --tail=50
docker compose restart api

# P0: Full server down
# → SSH via Hetzner Console
sudo systemctl start docker
cd /opt/article-summarizer && docker compose up -d
```

---

## ۹. Acceptance Criteria Checklist

- [x] ✅ **rollback.sh** — اسکریپت بازگشت کامل
- [x] ✅ **deploy.sh** — اسکریپت دپلوی zero-downtime
- [x] ✅ **backup.sh** — پشتیبان‌گیری روزانه
- [x] ✅ **Runbook** — همه مراحل recovery مستند شده
- [x] ✅ **Health check** — بعد از هر deploy و rollback
- [x] ✅ **Logging** — همه عملیات لاگ میشه
- [x] ✅ **Manual procedures** — برای مواقع بحرانی

---

> **پایین سند**  
> **نسخه:** 1.0  
> **تاریخ:** جولای 2026  
> **وضعیت:** ✓ Ready for Production  
> **Story Points:** 3
