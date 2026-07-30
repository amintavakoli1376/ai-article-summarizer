import os
import time

import asyncpg
import sentry_sdk
from fastapi import FastAPI, Request, Response
from fastapi.responses import PlainTextResponse
from prometheus_client import Counter, Gauge, Histogram, CONTENT_TYPE_LATEST, generate_latest
from redis.asyncio import from_url
from sentry_sdk.integrations.asgi import SentryAsgiMiddleware
from sentry_sdk.integrations.fastapi import FastApiIntegration

SENTRY_DSN = os.getenv("SENTRY_DSN")
TRACES_SAMPLE_RATE = float(os.getenv("SENTRY_TRACES_SAMPLE_RATE", "0.05"))

sentry_sdk.init(
    dsn=SENTRY_DSN,
    integrations=[FastApiIntegration()],
    traces_sample_rate=TRACES_SAMPLE_RATE,
    send_default_pii=True,
)

app = FastAPI(title="Article Summarizer API")
app.add_middleware(SentryAsgiMiddleware)

http_requests_total = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "path", "status"],
)
http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration",
    ["method", "path"],
)
celery_queue_depth = Gauge("celery_queue_depth", "Current Celery queue depth")
redis_memory_bytes = Gauge("redis_memory_bytes", "Redis used memory in bytes")
db_connection_count = Gauge("db_connection_count", "Active database connections")
pipeline_events_total = Counter(
    "pipeline_events_total",
    "Pipeline events processed",
    ["type"],
)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start_time = time.time()
    response = await call_next(request)
    request_time = time.time() - start_time
    path = request.url.path
    status_code = str(response.status_code)
    method = request.method

    http_requests_total.labels(method=method, path=path, status=status_code).inc()
    http_request_duration_seconds.labels(method=method, path=path).observe(request_time)
    if path == "/":
        pipeline_events_total.labels(type="http_request").inc()

    return response


async def update_dynamic_metrics():
    redis_url = os.getenv("REDIS_URL")
    if redis_url:
        try:
            redis_client = from_url(redis_url, decode_responses=True)
            info = await redis_client.info()
            redis_memory_bytes.set(int(info.get("used_memory", 0)))
            queue_len = await redis_client.llen("celery")
            celery_queue_depth.set(queue_len)
            await redis_client.close()
        except Exception:
            pass

    database_url = os.getenv("DATABASE_URL")
    if database_url:
        try:
            conn = await asyncpg.connect(database_url)
            result = await conn.fetchval("SELECT count(*) FROM pg_stat_activity")
            db_connection_count.set(int(result or 0))
            await conn.close()
        except Exception:
            pass


@app.get("/")
def read_root() -> dict[str, str]:
    pipeline_events_total.labels(type="health_check").inc()
    return {"message": "Article Summarizer API"}


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "api"}


@app.get("/metrics")
async def metrics() -> Response:
    await update_dynamic_metrics()
    data = generate_latest()
    return Response(content=data, media_type=CONTENT_TYPE_LATEST)
