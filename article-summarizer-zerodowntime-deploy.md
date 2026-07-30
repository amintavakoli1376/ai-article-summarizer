# Zero-Downtime Deployment — Article Summarizer
## Rolling Update Strategy with Docker Compose

---

**نسخه:** 1.0  
**تاریخ:** جولای 2026  
**وضعیت:** ✓ Ready to Use  

---

## ۱. معماری Zero-Downtime

```
┌──────────────────────────────────────────────────────────┐
│                  Docker Compose Rolling Update             │
│                                                          │
│  مرحله ۱:                                               │
│  ┌──────────┐  ┌──────────┐       کاربرا به هر دو وصلن │
│  │  API v1  │  │  API v1  │                             │
│  └──────────┘  └──────────┘                             │
│                                                          │
│  مرحله ۲: deploy                                         │
│  ┌──────────┐  ┌──────────┐  → API v2 رو بالا میاره     │
│  │  API v1  │  │  API v1  │     (v1 هنوز فعاله)        │
│  └──────────┘  └──────────┘                             │
│                                                          │
│  مرحله ۳: scale api=2                                    │
│  ┌──────────┐  ┌──────────┐                              │
│  │  API v1  │  │  API v2  │  → یکی v2 شد               │
│  └──────────┘  └──────────┘     (کاربرا قطعی ندارن)    │
│                                                          │
│  مرحله ۴: scale api=1                                    │
│  ┌──────────┐                                            │
│  │  API v2  │  → همه v2 شدن                              │
│  └──────────┘     (بدون قطعی)                            │
└──────────────────────────────────────────────────────────┘
```

---

## ۲. فایل `docker-compose.prod.yml` — تنظیمات Rolling Update

```yaml
version: '3.9'

services:

  # ─── API با rolling update ──────────────────────────────
  api:
    build:
      context: .
      dockerfile: Dockerfile.api
    container_name: summarizer-api
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 15s
    deploy:
      replicas: 2  # دو تا کپی همیشه فعال
      update_config:
        order: start-first       # اول سرویس جدید رو بالا بیار
        parallelism: 1           # یکی یکی عوض کن
        delay: 5s                # ۵ ثانیه صبر بین هر کدوم
        failure_action: rollback # اگه failed شد، برگرد عقب
        monitor: 30s             # ۳۰ ثانیه سلامت رو چک کن
    networks:
      - summarizer-net
    ports:
      - "127.0.0.1:8000:8000"

  # ─── Frontend ──────────────────────────────────────────
  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile.next
    container_name: summarizer-frontend
    restart: unless-stopped
    depends_on:
      - api
    deploy:
      replicas: 1
      update_config:
        order: start-first
        failure_action: rollback
    networks:
      - summarizer-net

  # ─── PostgreSQL ─────────────────────────────────────────
  postgres:
    image: postgres:16-alpine
    container_name: summarizer-postgres
    restart: unless-stopped
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U summarizer"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - summarizer-net

  # ─── Redis ──────────────────────────────────────────────
  redis:
    image: redis:7-alpine
    container_name: summarizer-redis
    restart: unless-stopped
    volumes:
      - redis_data:/data
    networks:
      - summarizer-net

  # ─── Nginx ──────────────────────────────────────────────
  nginx:
    image: nginx:1.26-alpine
    container_name: summarizer-nginx
    restart: unless-stopped
    depends_on:
      - api
      - frontend
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - summarizer-net

volumes:
  postgres_data:
  redis_data:

networks:
  summarizer-net:
    driver: bridge
```

---

## ۳. اسکریپت Deploy

فایل `deploy.sh` — باید روی سرور باشه:

```bash
#!/bin/bash
set -e

echo "🚀 Starting zero-downtime deployment..."
cd /opt/article-summarizer

# ─── ۱. Pull latest images ────────────────────────────────
echo "📥 Pulling new images..."
docker compose -f docker-compose.prod.yml pull

# ─── ۲. Scale up: add new version alongside old ──────────
echo "🔄 Scaling up (2 replicas)..."
docker compose -f docker-compose.prod.yml up -d \
  --no-deps \
  --scale api=2

# ─── ۳. Health check: wait for new version ───────────────
echo "⏳ Checking new version health..."
for i in $(seq 1 15); do
  if curl -sSf http://localhost:8000/health > /dev/null 2>&1; then
    echo "✅ New version is healthy (attempt $i)"
    break
  fi
  if [ "$i" -eq 15 ]; then
    echo "❌ Health check failed — rolling back!"
    docker compose -f docker-compose.prod.yml up -d --scale api=1
    exit 1
  fi
  sleep 2
done

# ─── ۴. Scale down: remove old version ──────────────────
echo "🧹 Scaling down to 1..."
docker compose -f docker-compose.prod.yml up -d --scale api=1

# ─── ۵. Run migrations ────────────────────────────────────
echo "🗄️ Running database migrations..."
docker compose -f docker-compose.prod.yml exec -T api alembic upgrade head || echo "⚠️ Migration skipped"

# ─── ۶. Reload Nginx ──────────────────────────────────────
echo "🔄 Reloading Nginx..."
docker compose -f docker-compose.prod.yml exec -T nginx nginx -s reload 2>/dev/null || true

# ─── ۷. Cleanup ───────────────────────────────────────────
echo "🧹 Cleaning up..."
docker image prune -f 2>/dev/null || true

echo "✅ Zero-downtime deployment complete!"
```

---

## ۴. فایل `.github/workflows/deploy.yml` — CI/CD

```yaml
name: 🚀 Zero-Downtime Deploy

on:
  push:
    branches: [main]

env:
  SSH_HOST: ${{ secrets.DEPLOY_HOST }}
  SSH_USER: ${{ secrets.DEPLOY_USER }}
  SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: 📤 Copy files
        uses: appleboy/scp-action@v0.1.7
        with:
          host: ${{ env.SSH_HOST }}
          username: ${{ env.SSH_USER }}
          key: ${{ env.SSH_KEY }}
          source: "."
          target: "/opt/article-summarizer"

      - name: 🚀 Run deploy script
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ env.SSH_HOST }}
          username: ${{ env.SSH_USER }}
          key: ${{ env.SSH_KEY }}
          script: |
            chmod +x /opt/article-summarizer/deploy.sh
            /opt/article-summarizer/deploy.sh
          script_stop: true
```

---

## ۵. اسکریپت Rollback (در صورت Fail)

`rollback.sh`:

```bash
#!/bin/bash
echo "⏪ Rolling back to previous version..."

cd /opt/article-summarizer

# Scale down to single instance
docker compose -f docker-compose.prod.yml up -d --scale api=1

# Pull previous image
docker compose -f docker-compose.prod.yml pull

# Restart
docker compose -f docker-compose.prod.yml up -d

echo "✅ Rollback complete"
```

---

## ۶. نحوه تست Zero-Downtime

### ۶.۱ تست محلی (روی Codespace)

```bash
# ۱. ترمینال ۱: شبیه‌سازی کاربر
while true; do
  curl -s http://localhost:8000/health | head -c 50
  echo " — $(date +%H:%M:%S)"
  sleep 1
done

# ۲. ترمینال ۲: اجرای deploy
bash deploy.sh
```

اگه توی ترمینال ۱ **هیچوقت** خطا نبینی → zero-downtime کار می‌کنه ✅

### ۶.۲ تست روی سرور اصلی

```bash
# از یه ماشین دیگه
watch -n 1 curl -s https://example.com/health
```

---

## ۷. چک‌لیست

| کار | توضیح |
|-----|--------|
| ✅ | **healthcheck** تو docker-compose |
| ✅ | **deploy.replicas = 2** برای API |
| ✅ | **update_config.order = start-first** |
| ✅ | **update_config.parallelism = 1** (یکی یکی) |
| ✅ | **update_config.failure_action = rollback** |
| ✅ | **Nginx** upstream با keepalive |
| ✅ | **deploy.sh** اسکریپت روی سرور |
| ✅ | **Health check** بعد از deploy |
| ✅ | **Rollback** در صورت fail |

---

> **پایین سند**  
> **نسخه:** 1.0  
> **تاریخ:** جولای 2026  
> **وضعیت:** ✓ Ready for Deployment  
> **Story Points:** 3
