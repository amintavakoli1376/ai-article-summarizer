from fastapi import FastAPI

app = FastAPI(title="Article Summarizer API")


@app.get("/")
def read_root() -> dict[str, str]:
    return {"message": "Article Summarizer API"}


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "api"}
