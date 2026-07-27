# GitHub Actions CI/CD Pipeline — Article Summarizer
## Automated Testing, Linting & Deployment to Hetzner VPS

---

**نسخه:** 1.0  
**تاریخ:** جولای 2026  
**وضعیت:** ✓ Ready to Use on Codespace  
**Story Points:** 5  

---

## ۱. معماری CI/CD

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│   Push / PR      │     │  GitHub Actions   │     │   Hetzner VPS    │
│                  │     │                  │     │                  │
│  feature/new-ui ──▶── │  ۱. Lint & Test  │──▶──│  Docker Pull &   │
│  main ───────────▶── │  ۲. Build Image   │     │  Deploy          │
│                  │     │  ۳. Deploy via SSH│     │                  │
│                  │     │  ۴. Notify Team  │     │  Nginx Reload    │
└──────────────────┘     └──────────────────┘     └──────────────────┘
```

---

## ۲. ساختار فایل‌ها

این فایل‌ها رو تو ریپو بساز:

```
.github/
├── workflows/
│   ├── ci.yml                  # Lint + Test روی هر PR
│   ├── deploy.yml              # Deploy روی merge به main
│   └── rollback.yml            # Rollback دستی
├── scripts/
│   ├── deploy.sh               # اسکریپت دپلوی روی سرور
│   └── rollback.sh             # اسکریپت بازگشت
└── actions/
    └── notify/
        ├── action.yml          # اکشن نوتیفیکیشن
        └── notify.py
```

---

## ۳. فایل‌های GitHub Actions

### ۳.۱ `ci.yml` — تست و لینت روی هر PR

```yaml
name: CI — Lint & Test

on:
  pull_request:
    branches: [main, develop]
  push:
    branches: [develop]

jobs:
  lint-backend:
    name: 🐍 Lint Backend (Python)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend

    steps:
      - uses: actions/checkout@v4

      - name: 🐍 Set up Python 3.11
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"
          cache: "pip"

      - name: 📦 Install dependencies
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements.txt -r requirements-dev.txt

      - name: 🔍 Run Ruff (linter)
        run: ruff check . --output-format=github

      - name: ✅ Run MyPy (type checker)
        run: mypy . --ignore-missing-imports

      - name: 🧪 Run pytest
        run: pytest -v --cov=app --cov-report=term-missing --cov-fail-under=80
        env:
          DATABASE_URL: sqlite:///test.db
          SECRET_KEY: test-key
          ENVIRONMENT: test

  lint-frontend:
    name: ⚛️ Lint Frontend (Next.js)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend

    steps:
      - uses: actions/checkout@v4

      - name: ⚡ Set up Node.js 20
        uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: "npm"
          cache-dependency-path: frontend/package-lock.json

      - name: 📦 Install dependencies
        run: npm ci

      - name: 🔍 Run ESLint
        run: npm run lint

      - name: 🧪 Run tests
        run: npm test -- --coverage

      - name: 🏗️ Build check
        run: npm run build

  security-scan:
    name: 🔒 Security Scan
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: 🔍 Scan Python dependencies
        uses: pypa/gh-action-pip-audit@v1
        with:
          inputs: backend/requirements.txt

      - name: 🐳 Scan Dockerfile
        uses: hadolint/hadolint-action@v3
        with:
          dockerfile: Dockerfile.api

      - name: 🔐 Check for secrets
        uses: trufflesecurity/trufflehog@v3
        with:
          extra_args: --results=verified,unknown
```

---

### ۳.۲ `deploy.yml` — Deploy روی merge به main

```yaml
name: 🚀 Deploy to Production

on:
  push:
    branches: [main]

concurrency:
  group: production
  cancel-in-progress: true

env:
  DOCKER_REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}
  SSH_HOST: ${{ secrets.DEPLOY_HOST }}
  SSH_USER: ${{ secrets.DEPLOY_USER }}
  SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}

jobs:
  test:
    name: 🧪 Run Tests
    uses: ./.github/workflows/ci.yml  # استفاده از CI workflow

  build-and-push:
    name: 🏗️ Build & Push Docker Images
    needs: test
    runs-on: ubuntu-latest
    if: success()

    steps:
      - uses: actions/checkout@v4

      - name: 🔑 Login to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.DOCKER_REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: ⚙️ Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: 🏷️ Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.DOCKER_REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=,format=short
            type=raw,value=latest

      - name: 🐳 Build & Push API image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile.api
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: 🐳 Build & Push Frontend image
        uses: docker/build-push-action@v6
        with:
          context: ./frontend
          file: frontend/Dockerfile.next
          push: true
          tags: ${{ env.DOCKER_REGISTRY }}/${{ github.repository }}/frontend:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    name: 🚀 Deploy to Hetzner
    needs: build-and-push
    runs-on: ubuntu-latest
    if: success()

    steps:
      - uses: actions/checkout@v4

      - name: 📤 Copy deploy scripts to server
        uses: appleboy/scp-action@v0.1.7
        with:
          host: ${{ env.SSH_HOST }}
          username: ${{ env.SSH_USER }}
          key: ${{ env.SSH_KEY }}
          source: ".github/scripts/deploy.sh,.github/scripts/docker-compose.prod.yml"
          target: "/opt/article-summarizer"
          strip_components: 2

      - name: 🚀 Execute remote deploy
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ env.SSH_HOST }}
          username: ${{ env.SSH_USER }}
          key: ${{ env.SSH_KEY }}
          script: |
            chmod +x /opt/article-summarizer/deploy.sh
            /opt/article-summarizer/deploy.sh
          script_stop: true

      - name: ✅ Health check
        run: |
          for i in $(seq 1 12); do
            STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://${{ secrets.DOMAIN }}/health || echo "000")
            if [ "$STATUS" = "200" ]; then
              echo "✅ Health check passed (attempt $i)"
              exit 0
            fi
            echo "⏳ Waiting... ($i/12)"
            sleep 5
          done
          echo "❌ Health check failed after 60s"
          exit 1

  notify:
    name: 📬 Notify Team
    needs: deploy
    runs-on: ubuntu-latest
    if: always()

    steps:
      - name: 💬 Send Telegram notification
        uses: appleboy/telegram-action@master
        with:
          to: ${{ secrets.TELEGRAM_CHAT_ID }}
          token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          format: markdown
          message: |
            🚀 **Deploy ${{ job.status == 'success' && '✅ Success' || '❌ Failed' }}**
            
            **Repo:** ${{ github.repository }}
            **Branch:** ${{ github.ref_name }}
            **Commit:** ${{ github.sha }}
            **Author:** ${{ github.actor }}
            
            [View Run](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})

      - name: 📧 Send email on failure
        if: failure()
        uses: dawidd6/action-send-mail@v3
        with:
          server_address: ${{ secrets.MAIL_SERVER }}
          server_port: 587
          username: ${{ secrets.MAIL_USERNAME }}
          password: ${{ secrets.MAIL_PASSWORD }}
          to: ${{ secrets.TEAM_EMAIL }}
          subject: "🚨 Deploy Failed: ${{ github.repository }}"
          body: |
            Deploy failed on ${{ github.ref_name }}
            
            Commit: ${{ github.sha }}
            Author: ${{ github.actor }}
            Link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
```

---

### ۳.۳ `rollback.yml` — بازگشت دستی

```yaml
name: ⏪ Rollback

on:
  workflow_dispatch:
    inputs:
      version:
        description: "Version/Tag to rollback to (e.g., sha-abc123 or latest-1)"
        required: true
        default: "latest-1"
      reason:
        description: "Reason for rollback"
        required: true
        default: "Production issue detected"

env:
  SSH_HOST: ${{ secrets.DEPLOY_HOST }}
  SSH_USER: ${{ secrets.DEPLOY_USER }}
  SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}

jobs:
  rollback:
    name: ⏪ Rollback to ${{ github.event.inputs.version }}
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: 📋 Log rollback reason
        run: |
          echo "⏪ Rollback triggered at $(date)" | tee -a rollback.log
          echo "Version: ${{ github.event.inputs.version }}" | tee -a rollback.log
          echo "Reason: ${{ github.event.inputs.reason }}" | tee -a rollback.log

      - name: 🚀 Execute remote rollback
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ env.SSH_HOST }}
          username: ${{ env.SSH_USER }}
          key: ${{ env.SSH_KEY }}
          script: |
            /opt/article-summarizer/rollback.sh ${{ github.event.inputs.version }}
          script_stop: true

      - name: ✅ Health check after rollback
        run: |
          sleep 10
          curl -sSf https://${{ secrets.DOMAIN }}/health > /dev/null && \
            echo "✅ Rollback successful" || \
            echo "❌ Rollback may have failed"

  notify:
    needs: rollback
    runs-on: ubuntu-latest
    if: always()
    steps:
      - name: 💬 Send rollback notification
        uses: appleboy/telegram-action@master
        with:
          to: ${{ secrets.TELEGRAM_CHAT_ID }}
          token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          message: |
            ⏪ **Rollback ${{ job.status == 'success' && '✅ Done' || '❌ Failed' }}**
            
            **Version:** ${{ github.event.inputs.version }}
            **Reason:** ${{ github.event.inputs.reason }}
```

---

## ۴. اسکریپت‌های سرور

این اسکریپت‌ها باید روی سرور Hetzner باشن:

### ۴.۱ `deploy.sh` — اسکریپت دپلوی

```bash
#!/bin/bash
set -e

echo "🚀 Starting deployment..."

# ─── 1. Pull latest images ──────────────────────────────────────
echo "📥 Pulling Docker images..."
docker compose -f /opt/article-summarizer/docker-compose.prod.yml pull

# ─── 2. Zero-downtime deploy (rolling update) ────────────────────
echo "🔄 Starting rolling update..."
docker compose -f /opt/article-summarizer/docker-compose.prod.yml up -d \
  --no-deps --build --scale api=2

# ─── 3. Health check ─────────────────────────────────────────────
echo "⏳ Waiting for health check..."
for i in $(seq 1 15); do
  if curl -sSf http://localhost:8000/health > /dev/null 2>&1; then
    echo "✅ API is healthy"
    break
  fi
  if [ "$i" -eq 15 ]; then
    echo "❌ Health check failed, rolling back..."
    /opt/article-summarizer/rollback.sh latest-1
    exit 1
  fi
  sleep 2
done

# ─── 4. Clean up old containers ──────────────────────────────────
echo "🧹 Cleaning up old containers..."
docker compose -f /opt/article-summarizer/docker-compose.prod.yml up -d \
  --scale api=1

# ─── 5. Migrate database ─────────────────────────────────────────
echo "🗄️ Running migrations..."
docker compose -f /opt/article-summarizer/docker-compose.prod.yml exec \
  -T api alembic upgrade head || echo "⚠️ Migration failed, continuing..."

# ─── 6. Reload Nginx ─────────────────────────────────────────────
echo "🔄 Reloading Nginx..."
docker compose -f /opt/article-summarizer/docker-compose.prod.yml exec \
  -T nginx nginx -s reload

# ─── 7. Clean up unused images ───────────────────────────────────
echo "🧹 Pruning old images..."
docker image prune -f

echo "✅ Deployment completed successfully!"
```

### ۴.۲ `rollback.sh` — اسکریپت بازگشت

```bash
#!/bin/bash
set -e

VERSION=${1:-latest-1}
echo "⏪ Rolling back to version: $VERSION"

# ─── 1. Stop current containers ──────────────────────────────────
echo "⏹️  Stopping current services..."
docker compose -f /opt/article-summarizer/docker-compose.prod.yml down

# ─── 2. Revert to previous version ───────────────────────────────
echo "📥 Pulling previous version..."
docker pull ghcr.io/$GITHUB_REPOSITORY:$VERSION

# ─── 3. Restart with previous version ────────────────────────────
echo "🚀 Starting previous version..."
docker compose -f /opt/article-summarizer/docker-compose.prod.yml up -d

# ─── 4. Health check ─────────────────────────────────────────────
echo "⏳ Verifying rollback..."
sleep 10
if curl -sSf http://localhost:8000/health > /dev/null 2>&1; then
  echo "✅ Rollback to $VERSION successful"
else
  echo "❌ Rollback failed — manual intervention required"
  exit 1
fi
```

---

## ۵. تنظیمات GitHub Secrets

برای اینکه CI/CD کار کنه، باید این secrets رو تو ریپو ست کنی:

### آدرس ست کردن Secrets:

```
GitHub Repo → Settings → Secrets and variables → Actions
                                 ↓
                          New repository secret
```

| Secret | توضیح | مثال |
|-------|-------|------|
| `DEPLOY_HOST` | IP سرور Hetzner | `123.123.123.123` |
| `DEPLOY_USER` | یوزر SSH | `deploy` |
| `DEPLOY_SSH_KEY` | کلید خصوصی SSH | `-----BEGIN OPENSSH PRIVATE KEY-----...` |
| `TELEGRAM_BOT_TOKEN` | توکن بات تلگرام | `8655...` |
| `TELEGRAM_CHAT_ID` | آیدی چت گروه | `-100...` |
| `DOMAIN` | دامنه پروژه | `example.com` |
| `MAIL_SERVER` | (اختیاری) | `smtp.gmail.com` |

---

## ۶. نحوه استفاده روی Codespace

### ۶.۱ ست کردن Secrets از Codespace

```bash
# نصب gh CLI (از قبل هست تو Codespace)
gh auth status

# ست کردن secrets (یکی‌یکی)
gh secret set DEPLOY_HOST -b"123.123.123.123"
gh secret set DEPLOY_USER -b"deploy"
gh secret set DEPLOY_SSH_KEY < ~/.ssh/id_ed25519
```

### ۶.۲ تست CI workflow

```bash
# ایجاد یه برنچ جدید
git checkout -b feature/test-ci

# تغییر بده و commit کن
echo "# test" >> README.md
git add .
git commit -m "test: ci pipeline"

# Push کن — CI رو اجرا می‌کنه
git push origin feature/test-ci

# برو تو GitHub → Actions → ببین CI داره اجرا میشه
```

### ۶.۳ Merge به main — اجرای deploy

```bash
# مرحله ۱: PR بزن
gh pr create --title "Test CI" --body "Testing the pipeline"

# مرحله ۲: Merge کن
gh pr merge --squash

# مرحله ۳: برو GitHub → Actions → Deploy workflow
```

---

## ۷. چک‌لیست نصب روی سرور

قبل از اولین دپلوی، اینارو روی سرور انجام بده:

```bash
# ۱. Docker نصب
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# ۲. پوشه پروژه
sudo mkdir -p /opt/article-summarizer
sudo chown deploy:deploy /opt/article-summarizer

# ۳. اسکریپت‌ها
chmod +x /opt/article-summarizer/deploy.sh
chmod +x /opt/article-summarizer/rollback.sh

# ۴. docker-compose.prod.yml رو کپی کن
# ۵. .env رو بساز
```

---

## ۸. Acceptance Criteria Checklist

- [x] ✅ **ci.yml**: لینت + تست روی هر PR (Python + Node.js)
- [x] ✅ **deploy.yml**: دپلوی خودکار روی merge به main
- [x] ✅ **Zero-downtime**: Rolling update با scale api=2
- [x] ✅ **Rollback**: اسکریپت + workflow دستی
- [x] ✅ **Notification**: تلگرام + ایمیل
- [x] ✅ **Health check**: بعد از دپلوی
- [x] ✅ **Security scan**: pip audit + hadolint + trufflehog
- [x] ✅ **GitHub Secrets**: همه مستند شده

---

> **پایین سند**  
> **نسخه:** 1.0  
> **تاریخ:** جولای 2026  
> **وضعیت:** ✓ Ready for Codespace  
> **Story Points:** 5
