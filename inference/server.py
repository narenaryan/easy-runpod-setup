"""
FastAPI inference server for HuggingFace models with TensorFlow backend.

Environment variables:
  HF_MODEL_ID   — HuggingFace model ID (default: google-bert/bert-base-uncased)
  MODEL_TASK    — HuggingFace pipeline task (default: text-classification)
  HF_TOKEN      — HuggingFace token for gated models (optional)
  INFERENCE_PORT— Port the server listens on (consumed by uvicorn via post_start.sh)

Endpoints:
  GET  /health       — liveness check
  GET  /model        — loaded model info
  POST /predict      — run inference
  POST /predict/batch— batch inference
"""

import os
import logging
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import transformers

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MODEL_ID = os.environ.get("HF_MODEL_ID", "google-bert/bert-base-uncased")
MODEL_TASK = os.environ.get("MODEL_TASK", "text-classification")
HF_TOKEN = os.environ.get("HF_TOKEN") or None

# ---------------------------------------------------------------------------
# Global pipeline (loaded once at startup)
# ---------------------------------------------------------------------------

_pipeline: transformers.Pipeline | None = None
_load_time: float = 0.0


def load_pipeline() -> transformers.Pipeline:
    global _pipeline, _load_time
    log.info("Loading pipeline  task=%s  model=%s  framework=tf", MODEL_TASK, MODEL_ID)
    t0 = time.time()
    pipe = transformers.pipeline(
        task=MODEL_TASK,
        model=MODEL_ID,
        framework="tf",       # TensorFlow backend
        token=HF_TOKEN,
        device=0,             # GPU 0; falls back to CPU if no GPU is available
    )
    _load_time = time.time() - t0
    log.info("Pipeline loaded in %.1fs", _load_time)
    return pipe


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _pipeline
    _pipeline = load_pipeline()
    yield
    # cleanup (TF sessions release on GC, nothing explicit needed)


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(
    title="HuggingFace Inference Server",
    description="TensorFlow-backed HuggingFace model inference on RunPod GPU",
    version="1.0.0",
    lifespan=lifespan,
)

# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------


class PredictRequest(BaseModel):
    inputs: str | list[str]
    # Optional pipeline kwargs forwarded verbatim (e.g. max_new_tokens, top_k)
    parameters: dict[str, Any] = {}


class PredictResponse(BaseModel):
    outputs: Any
    model_id: str
    task: str


class BatchPredictRequest(BaseModel):
    inputs: list[str]
    parameters: dict[str, Any] = {}


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/health")
def health():
    return {
        "status": "ok" if _pipeline is not None else "loading",
        "model_id": MODEL_ID,
        "task": MODEL_TASK,
    }


@app.get("/model")
def model_info():
    if _pipeline is None:
        raise HTTPException(status_code=503, detail="Model not loaded yet")
    config = getattr(_pipeline.model, "config", None)
    return {
        "model_id": MODEL_ID,
        "task": MODEL_TASK,
        "framework": "tf",
        "load_time_seconds": round(_load_time, 2),
        "model_type": getattr(config, "model_type", "unknown") if config else "unknown",
        "transformers_version": transformers.__version__,
    }


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    if _pipeline is None:
        raise HTTPException(status_code=503, detail="Model not loaded yet")
    try:
        outputs = _pipeline(req.inputs, **req.parameters)
    except Exception as exc:
        log.exception("Inference error")
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return PredictResponse(outputs=outputs, model_id=MODEL_ID, task=MODEL_TASK)


@app.post("/predict/batch", response_model=PredictResponse)
def predict_batch(req: BatchPredictRequest):
    if _pipeline is None:
        raise HTTPException(status_code=503, detail="Model not loaded yet")
    if not req.inputs:
        raise HTTPException(status_code=400, detail="inputs list is empty")
    try:
        outputs = _pipeline(req.inputs, **req.parameters)
    except Exception as exc:
        log.exception("Batch inference error")
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return PredictResponse(outputs=outputs, model_id=MODEL_ID, task=MODEL_TASK)
