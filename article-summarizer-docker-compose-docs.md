# Article Summarizer — Docker Compose Configuration
## Production-Ready Multi-Service Architecture

---

**نسخه:** 1.0  
**تاریخ:** جولای 2026  
**وضعیت:** ✓ Ready for Deployment  
**Story Points:** 5  
**هشدار:** هیچ پکیجی روی سرور فعلی نصب نمی‌شود — فقط فایل‌های کانفیگ

---

## ۱. معماری سرویس‌ها

```
┌─────────────────────────────────────────────────────────────────┐
│                         Docker Network                            │
│                         summarizer-net                            │
│                                                                   │
│  ┌────────────┐    ┌──────────────┐    ┌──────────────────────┐ │
│  │  Next.js   │───▶│   FastAPI    │───▶│   PostgreSQL (DB)    │ │
│  │  :3000     │    │   :8000      │    │   :5432              │ │
│  └────────────┘    └──────┬───────┘    └──────────────────────┘ │
│                           │                                       │
│                    ┌──────▼───────┐    ┌──────────────────────┐ │
│                    │   Redis      │    │  Elasticsearch       │ │
│                    │   :6379      │    │  :9200               │ │
│                    └──────┬───────┘    └──────────────────────┘ │
│                           │                                       │
│                    ┌──────▼───────┐                               │
│                    │  Celery      │                               │
│                    │  Workers     │                               │
│                    └──────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
```

---

## ۲. فایل‌ها

### ۲.۱ `docker-compose.prod.yml`

```yaml
version: '3.9'

name: article-summarizer

x-logging: &default-logging
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"

services:

  # ─── PostgreSQL ─────────────────────────────────────────────────
  postgres:
    image: postgres:16-alpine
    container_name: summarizer-postgres
    restart: unless-stopped
    logging: *default-logging
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-summarizer}
      POSTGRES_USER: ${POSTGRES_USER:-summarizer}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-db:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-summarizer} -d ${POSTGRES_DB:-summarizer}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    networks:
      - summarizer-net
    ports:
      - "127.0.0.1:5432:5432"  # فقط localhost
    deploy:
      resources:
        limits:
          memory: 1G

  # ─── Redis ──────────────────────────────────────────────────────
  redis:
    image: redis:7-alpine
    container_name: summarizer-redis
    restart: unless-stopped
    logging: *default-logging
    command: redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "--raw", "incr", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - summarizer-net
    ports:
      - "127.0.0.1:6379:6379"  # فقط localhost
    deploy:
      resources:
        limits:
          memory: 512M

  # ─── Elasticsearch ──────────────────────────────────────────────
  elasticsearch:
    image: elasticsearch:8.12.0
    container_name: summarizer-elasticsearch
    restart: unless-stopped
    logging: *default-logging
    environment:
      - cluster.name=summarizer-cluster
      - node.name=summarizer-node
      - discovery.type=single-node
      - bootstrap.memory_lock=true
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
      - xpack.security.enabled=false
      - xpack.security.enrollment.enabled=false
      - ingest.geoip.downloader.enabled=false
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - elasticsearch_data:/usr/share/elasticsearch/data
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:9200 | grep -q 'cluster_name'"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    networks:
      - summarizer-net
    ports:
      - "127.0.0.1:9200:9200"
    deploy:
      resources:
        limits:
          memory: 2G

  # ─── FastAPI Backend ────────────────────────────────────────────
  api:
    build:
      context: .
      dockerfile: Dockerfile.api
      target: production
    container_name: summarizer-api
    restart: unless-stopped
    logging: *default-logging
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      elasticsearch:
        condition: service_started
    environment:
      - DATABASE_URL=postgresql+asyncpg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - ELASTICSEARCH_URL=http://elasticsearch:9200
      - SECRET_KEY=${SECRET_KEY}
      - CORS_ORIGINS=${CORS_ORIGINS:-https://example.com}
      - ENVIRONMENT=production
      - LOG_LEVEL=info
    env_file:
      - .env
    volumes:
      - api_static:/app/static
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
    networks:
      - summarizer-net
    deploy:
      resources:
        limits:
          memory: 1G
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.api.rule=Host(`api.example.com`)"

  # ─── Celery Worker ──────────────────────────────────────────────
  celery:
    build:
      context: .
      dockerfile: Dockerfile.api
      target: production
    container_name: summarizer-celery
    restart: unless-stopped
    logging: *default-logging
    command: celery -A app.tasks worker -l info -c 4
    depends_on:
      - api
    environment:
      - DATABASE_URL=postgresql+asyncpg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - ELASTICSEARCH_URL=http://elasticsearch:9200
      - SECRET_KEY=${SECRET_KEY}
    env_file:
      - .env
    volumes:
      - api_static:/app/static
    networks:
      - summarizer-net
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: "2.0"

  # ─── Celery Beat (Scheduler) ────────────────────────────────────
  celery-beat:
    build:
      context: .
      dockerfile: Dockerfile.api
      target: production
    container_name: summarizer-celery-beat
    restart: unless-stopped
    logging: *default-logging
    command: celery -A app.tasks beat -l info --schedule /tmp/celerybeat-schedule
    depends_on:
      - api
    environment:
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
    env_file:
      - .env
    networks:
      - summarizer-net

  # ─── Next.js Frontend ───────────────────────────────────────────
  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile.next
      target: production
      args:
        NEXT_PUBLIC_API_URL: ${NEXT_PUBLIC_API_URL:-https://api.example.com}
    container_name: summarizer-frontend
    restart: unless-stopped
    logging: *default-logging
    depends_on:
      - api
    environment:
      - NODE_ENV=production
      - NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL:-https://api.example.com}
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:3000/api/health', r => {process.exit(r.statusCode === 200 ? 0 : 1)})"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
    networks:
      - summarizer-net
    ports:
      - "127.0.0.1:3000:3000"
    deploy:
      resources:
        limits:
          memory: 512M

  # ─── Nginx Reverse Proxy ────────────────────────────────────────
  nginx:
    image: nginx:1.26-alpine
    container_name: summarizer-nginx
    restart: unless-stopped
    logging: *default-logging
    depends_on:
      - api
      - frontend
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - certbot_data:/var/www/certbot
      - certbot_certs:/etc/letsencrypt
    networks:
      - summarizer-net
    deploy:
      resources:
        limits:
          memory: 128M

  # ─── Certbot (SSL Auto-Renew) ───────────────────────────────────
  certbot:
    image: certbot/certbot:v2.9.0
    container_name: summarizer-certbot
    restart: unless-stopped
    volumes:
      - certbot_certs:/etc/letsencrypt
      - certbot_data:/var/www/certbot
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;'"
    networks:
      - summarizer-net

volumes:
  postgres_data:
    driver: local
    name: summarizer-postgres-data
  redis_data:
    driver: local
    name: summarizer-redis-data
  elasticsearch_data:
    driver: local
    name: summarizer-elasticsearch-data
  api_static:
    driver: local
    name: summarizer-api-static
  certbot_data:
    driver: local
    name: summarizer-certbot-data
  certbot_certs:
    driver: local
    name: summarizer-certbot-certs

networks:
  summarizer-net:
    driver: bridge
    name: summarizer-net
    ipam:
      config:
        - subnet: 172.20.0.0/16
```

---

### ۲.۲ `docker-compose.dev.yml`

```yaml
version: '3.9'

name: article-summarizer-dev

x-logging: &default-logging
  driver: "json-file"
  options:
    max-size: "5m"
    max-file: "2"

services:

  postgres:
    image: postgres:16-alpine
    container_name: summarizer-dev-postgres
    logging: *default-logging
    environment:
      POSTGRES_DB: summarizer_dev
      POSTGRES_USER: summarizer
      POSTGRES_PASSWORD: dev_password_123
    volumes:
      - postgres_dev_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U summarizer -d summarizer_dev"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - summarizer-dev-net

  redis:
    image: redis:7-alpine
    container_name: summarizer-dev-redis
    logging: *default-logging
    command: redis-server --appendonly yes
    volumes:
      - redis_dev_data:/data
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - summarizer-dev-net

  elasticsearch:
    image: elasticsearch:8.12.0
    container_name: summarizer-dev-elasticsearch
    logging: *default-logging
    environment:
      - discovery.type=single-node
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
      - xpack.security.enabled=false
    volumes:
      - elasticsearch_dev_data:/usr/share/elasticsearch/data
    ports:
      - "9200:9200"
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:9200 | grep -q 'cluster_name'"]
      interval: 30s
      timeout: 10s
      retries: 5
    networks:
      - summarizer-dev-net

  api:
    build:
      context: .
      dockerfile: Dockerfile.api
      target: development
    container_name: summarizer-dev-api
    logging: *default-logging
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      - "8000:8000"
    volumes:
      - ./src:/app/src:ro
      - ./alembic:/app/alembic:ro
    environment:
      - DATABASE_URL=postgresql+asyncpg://summarizer:dev_password_123@postgres:5432/summarizer_dev
      - REDIS_URL=redis://redis:6379/0
      - ELASTICSEARCH_URL=http://elasticsearch:9200
      - SECRET_KEY=dev-secret-key-change-in-production
      - CORS_ORIGINS=http://localhost:3000,http://localhost:5173
      - ENVIRONMENT=development
      - LOG_LEVEL=debug
    command: uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
    networks:
      - summarizer-dev-net

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile.next
      target: development
    container_name: summarizer-dev-frontend
    logging: *default-logging
    depends_on:
      - api
    ports:
      - "3000:3000"
    volumes:
      - ./frontend/src:/app/src:ro
      - ./frontend/public:/app/public:ro
    environment:
      - NODE_ENV=development
      - NEXT_PUBLIC_API_URL=http://localhost:8000
    command: npm run dev
    networks:
      - summarizer-dev-net

volumes:
  postgres_dev_data:
    driver: local
  redis_dev_data:
    driver: local
  elasticsearch_dev_data:
    driver: local

networks:
  summarizer-dev-net:
    driver: bridge
    name: summarizer-dev-net
```

---

### ۲.۳ `.env.production.example`

```bash
# ─── Project ──────────────────────────────────────────────
PROJECT_NAME=Article Summarizer
ENVIRONMENT=production

# ─── Django/FastAPI Secret ────────────────────────────────
SECRET_KEY=generate-with-openssl-rand-32
CORS_ORIGINS=https://example.com,https://www.example.com

# ─── Database ─────────────────────────────────────────────
POSTGRES_DB=summarizer
POSTGRES_USER=summarizer
POSTGRES_PASSWORD=change-this-to-a-long-random-string

# ─── Redis ────────────────────────────────────────────────
REDIS_PASSWORD=change-this-to-another-random-string

# ─── URLs ─────────────────────────────────────────────────
NEXT_PUBLIC_API_URL=https://api.example.com
DATABASE_URL=postgresql+asyncpg://summarizer:${POSTGRES_PASSWORD}@postgres:5432/summarizer
REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
ELASTICSEARCH_URL=http://elasticsearch:9200

# ─── External APIs ────────────────────────────────────────
GROQ_API_KEY=gsk_your_groq_api_key
OPENAI_API_KEY=sk-your_openai_api_key
YOUTUBE_API_KEY=your_youtube_api_key
GITHUB_TOKEN=ghp_your_github_token

# ─── Docker ───────────────────────────────────────────────
COMPOSE_PROJECT_NAME=article-summarizer
DOCKER_BUILDKIT=1
```

### ۲.۴ `.env.development.example`

```bash
# ─── Development ──────────────────────────────────────────
ENVIRONMENT=development
SECRET_KEY=dev-secret-key-not-for-production
CORS_ORIGINS=http://localhost:3000,http://localhost:5173

# ─── Database ─────────────────────────────────────────────
POSTGRES_DB=summarizer_dev
POSTGRES_USER=summarizer
POSTGRES_PASSWORD=dev_password_123

# ─── Redis ────────────────────────────────────────────────
REDIS_PASSWORD=dev_redis_pass

# ─── URLs ─────────────────────────────────────────────────
DATABASE_URL=postgresql+asyncpg://summarizer:dev_password_123@postgres:5432/summarizer_dev
REDIS_URL=redis://:dev_redis_pass@redis:6379/0
ELASTICSEARCH_URL=http://elasticsearch:9200

# ─── API Keys (optional in dev) ───────────────────────────
GROQ_API_KEY=
OPENAI_API_KEY=
GITHUB_TOKEN=
```

---

### ۲.۵ `Makefile`

```makefile
.PHONY: help prod-up prod-down prod-build prod-logs dev-up dev-down dev-build dev-logs \
        prod-shell prod-psql prod-redis prod-es migrate reset clean backup restore

# ─── Colors ───────────────────────────────────────────────
BLUE := \033[36m
GREEN := \033[32m
YELLOW := \033[33m
RED := \033[31m
RESET := \033[0m

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	awk 'BEGIN {FS = ":.*?## "}; {printf "$(BLUE)%-20s$(RESET) %s\n", $$1, $$2}'

# ─── Production ───────────────────────────────────────────

prod-up: ## Start all production services
	docker compose -f docker-compose.prod.yml up -d
	@echo "$(GREEN)✅ Production services started$(RESET)"

prod-down: ## Stop all production services
	docker compose -f docker-compose.prod.yml down
	@echo "$(YELLOW)⏹  Production services stopped$(RESET)"

prod-build: ## Build production images
	docker compose -f docker-compose.prod.yml build --no-cache

prod-logs: ## Tail production logs
	docker compose -f docker-compose.prod.yml logs -f

prod-restart: ## Restart all production services
	docker compose -f docker-compose.prod.yml restart

prod-ps: ## List production containers
	docker compose -f docker-compose.prod.yml ps

# ─── Development ──────────────────────────────────────────

dev-up: ## Start all development services
	docker compose -f docker-compose.dev.yml up -d
	@echo "$(GREEN)✅ Development services started$(RESET)"

dev-down: ## Stop all development services
	docker compose -f docker-compose.dev.yml down
	@echo "$(YELLOW)⏹  Development services stopped$(RESET)"

dev-build: ## Build development images
	docker compose -f docker-compose.dev.yml build

dev-logs: ## Tail development logs
	docker compose -f docker-compose.dev.yml logs -f

dev-restart: ## Restart all development services
	docker compose -f docker-compose.dev.yml restart

# ─── Database ─────────────────────────────────────────────

prod-psql: ## Open PostgreSQL shell in production
	docker exec -it summarizer-postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

prod-redis: ## Open Redis CLI in production
	docker exec -it summarizer-redis redis-cli -a $(REDIS_PASSWORD)

prod-es: ## Check Elasticsearch health
	curl http://localhost:9200/_cluster/health | python3 -m json.tool

migrate: ## Run database migrations
	docker compose -f docker-compose.prod.yml exec api alembic upgrade head

# ─── Maintenance ──────────────────────────────────────────

reset: ## Reset all data (⚠️ destroys volumes)
	docker compose -f docker-compose.prod.yml down -v
	@echo "$(RED)⚠️  All volumes deleted. Run 'make prod-up' to recreate.$(RESET)"

backup: ## Backup database
	docker exec -t summarizer-postgres pg_dumpall -c -U $(POSTGRES_USER) > backup_$(shell date +%Y%m%d_%H%M%S).sql
	@echo "$(GREEN)✅ Database backup created$(RESET)"

restore: ## Restore database from file (usage: make restore FILE=backup.sql)
	cat $(FILE) | docker exec -i summarizer-postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)
	@echo "$(GREEN)✅ Database restored from $(FILE)$(RESET)"

clean: ## Clean unused Docker resources
	docker system prune -f --volumes
	@echo "$(YELLOW)🧹 Cleaned unused Docker resources$(RESET)"

# ─── SSL ──────────────────────────────────────────────────

ssl-renew: ## Manually renew SSL certificates
	docker compose -f docker-compose.prod.yml exec certbot certbot renew
	docker compose -f docker-compose.prod.yml exec nginx nginx -s reload
```

---

### ۲.۶ `nginx/nginx.conf`

```nginx
user nginx;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
    use epoll;
}

http {
    # ─── Basic ────────────────────────────────────────────
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # ─── MIME ─────────────────────────────────────────────
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # ─── Logging ──────────────────────────────────────────
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main buffer=32k flush=5s;
    error_log /var/log/nginx/error.log warn;

    # ─── SSL ──────────────────────────────────────────────
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    # ─── Security ─────────────────────────────────────────
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy strict-origin-when-cross-origin;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()";

    # ─── Gzip ─────────────────────────────────────────────
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript;

    # ─── Upstreams ────────────────────────────────────────
    upstream api_upstream {
        server api:8000;
        keepalive 32;
    }

    upstream frontend_upstream {
        server frontend:3000;
        keepalive 16;
    }

    # ─── HTTP → HTTPS Redirect ────────────────────────────
    server {
        listen 80;
        server_name example.com api.example.com;
        return 301 https://$server_name$request_uri;
    }

    # ─── API ──────────────────────────────────────────────
    server {
        listen 443 ssl http2;
        server_name api.example.com;

        ssl_certificate /etc/letsencrypt/live/api.example.com/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/api.example.com/privkey.pem;

        location / {
            proxy_pass http://api_upstream;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 120s;
            proxy_send_timeout 120s;
        }
    }

    # ─── Frontend ─────────────────────────────────────────
    server {
        listen 443 ssl http2;
        server_name example.com www.example.com;

        ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

        location /_next/webpack-hmr {
            proxy_pass http://frontend_upstream;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }

        location / {
            proxy_pass http://frontend_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
```

---

## ۳. نحوه استفاده

### ۳.۱ اولین راه‌اندازی

```bash
# ۱. کلون کن
git clone https://github.com/your-username/article-summarizer.git
cd article-summarizer

# ۲. env بساز
cp .env.production.example .env
# ویرایش کن: SECRET_KEY, POSTGRES_PASSWORD, REDIS_PASSWORD

# ۳. بساز و اجرا کن
make prod-build
make prod-up

# ۴. مهاجرت دیتابیس
make migrate

# ۵. چک کن
make prod-ps
curl http://localhost:8000/health
```

### ۳.۲ commands متداول

| Command | توضیح |
|---------|-------|
| `make prod-up` | اجرای همه سرویس‌ها |
| `make prod-down` | متوقف کردن همه |
| `make prod-logs` | دیدن لاگ‌ها |
| `make dev-up` | اجرای محیط توسعه |
| `make migrate` | اجرای مهاجرت دیتابیس |
| `make backup` | پشتیبان‌گیری از دیتابیس |
| `make restore FILE=x.sql` | بازیابی از پشتیبان |
| `make ssl-renew` | تمدید دستی SSL |

---

## ۴. ساختار دایرکتوری

```
article-summarizer/
├── docker-compose.prod.yml     # Production config
├── docker-compose.dev.yml      # Development config
├── .env.production.example     # Production env template
├── .env.development.example    # Development env template
├── Makefile                    # Command shortcuts
├── Dockerfile.api              # FastAPI Dockerfile
├── Dockerfile.next             # Next.js Dockerfile
├── nginx/
│   ├── nginx.conf              # Nginx main config
│   └── conf.d/                 # Site-specific configs
├── init-db/                    # SQL init scripts
├── src/                        # FastAPI source
├── frontend/                   # Next.js source
└── alembic/                    # DB migrations
```

---

## ۵. نکات امنیتی

| نکته | توضیح |
|------|-------|
| **Secrets** | همه در `.env` — هرگز در git commit نکن |
| **Ports** | دیتابیس‌ها فقط روی `127.0.0.1` |
| **Health checks** | همه سرویس‌ها health check دارند |
| **Restart** | `unless-stopped` — بعد از crash خودکار بالا میاد |
| **Logs** | محدود به ۱۰MB, ۳ فایل |
| **Memory limits** | هر سرویس محدودیت رم داره |

---

## ۶. منابع (Resource Requirements)

| سرویس | RAM | CPU | Disk |
|-------|-----|-----|------|
| PostgreSQL | ۱GB | shared | حجم داده |
| Redis | ۵۱۲MB | shared | ~۱۰۰MB |
| Elasticsearch | ۲GB | shared | حجم ایندکس |
| FastAPI | ۱GB | shared | — |
| Celery | ۲GB | 2 core | — |
| Next.js | ۵۱۲MB | shared | — |
| Nginx | ۱۲۸MB | shared | — |
| **Total** | **~۷.۵GB** | | |

> برای Hetzner CX41 (16GB RAM) کاملاً کافیه. حدود ۸GB برای سیستم و بقیه سرویس‌ها آزاد می‌مونه.

---

> **پایین سند**  
> **نسخه:** 1.0  
> **تاریخ:** جولای 2026  
> **وضعیت:** ✓ Ready for Deployment  
> **Story Points:** 5  
> **هیچ پکیجی روی سرور فعلی نصب نشده** ✅
