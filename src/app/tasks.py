import os
from celery import Celery
from prometheus_client import Counter
from sentry_sdk import capture_exception

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

celery = Celery(
    "article_summarizer",
    broker=REDIS_URL,
    backend=REDIS_URL,
)

celery.conf.task_default_queue = "celery"
celery.conf.task_routes = {"app.tasks.summarize_article": {"queue": "celery"}}

CELERY_TASKS_TOTAL = Counter(
    "celery_tasks_total",
    "Total Celery tasks executed",
    ["task", "status"],
)
CELERY_TASK_FAILURES_TOTAL = Counter(
    "celery_task_failures_total",
    "Total failed Celery tasks",
    ["task"],
)


@celery.task(bind=True, name="app.tasks.summarize_article")
def summarize_article(self, article_text: str) -> str:
    try:
        result = article_text[:200]
        CELERY_TASKS_TOTAL.labels(task=self.name, status="success").inc()
        return result
    except Exception as exc:
        CELERY_TASK_FAILURES_TOTAL.labels(task=self.name).inc()
        capture_exception(exc)
        raise
