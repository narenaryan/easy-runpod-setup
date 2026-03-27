"""
OpenAI-compatible inference server for HuggingFace models (PyTorch backend).

Exposes /v1/chat/completions so any OpenAI-compatible client (OpenCode, Continue,
Cursor, etc.) can use it directly. Also keeps /predict for simple text generation.

Environment variables:
  HF_MODEL_ID   — HuggingFace model ID (default: google-bert/bert-base-uncased)
  HF_TOKEN      — HuggingFace token for gated models (optional)
  INFERENCE_PORT— Port uvicorn listens on (set by post_start.sh)

Endpoints:
  GET  /health                  — liveness / readiness check
  GET  /model                   — loaded model info
  GET  /v1/models               — OpenAI-compatible model list
  POST /v1/chat/completions     — OpenAI-compatible chat endpoint (used by OpenCode)
  POST /predict                 — simple text-in / text-out generation
"""

import json, os, time, uuid, logging
from contextlib import asynccontextmanager
from threading import Thread
from typing import Any, Iterator

import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from transformers import AutoModelForCausalLM, AutoTokenizer, TextIteratorStreamer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

MODEL_ID  = os.environ.get("HF_MODEL_ID", "google-bert/bert-base-uncased")
HF_TOKEN  = os.environ.get("HF_TOKEN") or None

_model: AutoModelForCausalLM | None = None
_tokenizer: AutoTokenizer | None    = None
_load_time: float = 0.0


def load_model():
    global _model, _tokenizer, _load_time
    log.info("Loading model: %s", MODEL_ID)
    t0 = time.time()
    _tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, token=HF_TOKEN)
    _model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        torch_dtype="auto",   # bf16 on Ampere+, fp16 elsewhere
        device_map="auto",    # fills all available GPUs
        token=HF_TOKEN,
    )
    _model.eval()
    _load_time = time.time() - t0
    log.info("Model loaded in %.1fs on %s", _load_time, next(_model.parameters()).device)


@asynccontextmanager
async def lifespan(app: FastAPI):
    load_model()
    yield


app = FastAPI(
    title="HuggingFace Inference Server (OpenAI-compatible)",
    description="PyTorch-backed HuggingFace model inference on RunPod GPU",
    version="1.0.0",
    lifespan=lifespan,
)

# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

class ChatMessage(BaseModel):
    role: str
    content: str


class ChatCompletionRequest(BaseModel):
    model: str = MODEL_ID
    messages: list[ChatMessage]
    max_tokens: int = 2048
    temperature: float = 0.6
    top_p: float = 0.95
    top_k: int = 20
    stream: bool = False        # streaming not yet supported


class PredictRequest(BaseModel):
    inputs: str | list[str]
    parameters: dict[str, Any] = {}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _generate(input_ids: torch.Tensor, **kwargs) -> torch.Tensor:
    with torch.no_grad():
        return _model.generate(input_ids, **kwargs)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health")
def health():
    return {
        "status": "ok" if _model is not None else "loading",
        "model_id": MODEL_ID,
    }


@app.get("/model")
def model_info():
    if _model is None:
        raise HTTPException(503, "Model not loaded yet")
    return {
        "model_id": MODEL_ID,
        "framework": "pt",
        "load_time_seconds": round(_load_time, 2),
        "device": str(next(_model.parameters()).device),
        "dtype": str(next(_model.parameters()).dtype),
    }


@app.get("/v1/models")
def list_models():
    """OpenAI-compatible model list — required by OpenCode on startup."""
    return {
        "object": "list",
        "data": [{
            "id": MODEL_ID,
            "object": "model",
            "created": 0,
            "owned_by": "local",
        }],
    }


def _sse(data: dict) -> str:
    return f"data: {json.dumps(data)}\n\n"


def _stream_tokens(req: ChatCompletionRequest, encoded, completion_id: str) -> Iterator[str]:
    """Yield OpenAI-format SSE chunks token by token using TextIteratorStreamer."""
    streamer = TextIteratorStreamer(
        _tokenizer, skip_prompt=True, skip_special_tokens=True
    )
    gen_kwargs = dict(
        input_ids=encoded.input_ids,
        max_new_tokens=req.max_tokens,
        temperature=req.temperature if req.temperature > 0 else None,
        top_p=req.top_p,
        top_k=req.top_k,
        do_sample=req.temperature > 0,
        pad_token_id=_tokenizer.eos_token_id,
        streamer=streamer,
    )

    # Generate in a background thread so we can stream from the main thread
    thread = Thread(target=_model.generate, kwargs=gen_kwargs, daemon=True)
    thread.start()

    created = int(time.time())
    chunk_base = {"id": completion_id, "object": "chat.completion.chunk",
                  "created": created, "model": req.model}

    # First chunk: role
    yield _sse({**chunk_base, "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]})

    for token_text in streamer:
        yield _sse({**chunk_base, "choices": [{"index": 0, "delta": {"content": token_text}, "finish_reason": None}]})

    # Final chunk: finish_reason
    yield _sse({**chunk_base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
    yield "data: [DONE]\n\n"

    thread.join()


@app.post("/v1/chat/completions")
def chat_completions(req: ChatCompletionRequest):
    """OpenAI-compatible chat completions — supports both streaming and non-streaming."""
    if _model is None:
        raise HTTPException(503, "Model not loaded yet")

    messages = [{"role": m.role, "content": m.content} for m in req.messages]
    text = _tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )
    encoded     = _tokenizer([text], return_tensors="pt").to(_model.device)
    completion_id = f"chatcmpl-{uuid.uuid4().hex[:8]}"

    if req.stream:
        return StreamingResponse(
            _stream_tokens(req, encoded, completion_id),
            media_type="text/event-stream",
            headers={"X-Accel-Buffering": "no"},   # disable nginx buffering
        )

    # Non-streaming path
    try:
        output_ids = _generate(
            encoded.input_ids,
            max_new_tokens=req.max_tokens,
            temperature=req.temperature if req.temperature > 0 else None,
            top_p=req.top_p,
            top_k=req.top_k,
            do_sample=req.temperature > 0,
            pad_token_id=_tokenizer.eos_token_id,
        )
    except Exception as exc:
        log.exception("Generation error")
        raise HTTPException(500, str(exc))

    new_tokens    = output_ids[0][encoded.input_ids.shape[-1]:]
    content       = _tokenizer.decode(new_tokens, skip_special_tokens=True)
    prompt_tokens = encoded.input_ids.shape[-1]
    comp_tokens   = len(new_tokens)

    return {
        "id":      completion_id,
        "object":  "chat.completion",
        "created": int(time.time()),
        "model":   req.model,
        "choices": [{
            "index":         0,
            "message":       {"role": "assistant", "content": content},
            "finish_reason": "stop",
        }],
        "usage": {
            "prompt_tokens":     prompt_tokens,
            "completion_tokens": comp_tokens,
            "total_tokens":      prompt_tokens + comp_tokens,
        },
    }


@app.post("/predict")
def predict(req: PredictRequest):
    """Simple text-in / text-out endpoint (no chat template applied)."""
    if _model is None:
        raise HTTPException(503, "Model not loaded yet")

    inputs_list = [req.inputs] if isinstance(req.inputs, str) else req.inputs
    results = []

    for text in inputs_list:
        encoded = _tokenizer([text], return_tensors="pt").to(_model.device)
        gen_kwargs: dict[str, Any] = {
            "max_new_tokens": 256,
            "pad_token_id":   _tokenizer.eos_token_id,
        }
        gen_kwargs.update(req.parameters)
        try:
            output_ids = _generate(encoded.input_ids, **gen_kwargs)
            new_tokens = output_ids[0][encoded.input_ids.shape[-1]:]
            results.append({"generated_text": _tokenizer.decode(new_tokens, skip_special_tokens=True)})
        except Exception as exc:
            log.exception("Inference error")
            raise HTTPException(500, str(exc))

    outputs = results[0] if isinstance(req.inputs, str) else results
    return {"outputs": outputs, "model_id": MODEL_ID}
