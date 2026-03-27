# RunPod GPU Inference Sandbox

Spin up a RunPod GPU pod with TensorFlow + NVIDIA CUDA, load any HuggingFace model, and get a live inference API — plus JupyterLab and SSH access — in one command.

## What you get

- **Inference API** (FastAPI) at `https://<POD_ID>-8000.proxy.runpod.net`
- **JupyterLab** at `https://<POD_ID>-8888.proxy.runpod.net`
- **SSH** via RunPod's proxied SSH gateway
- Any HuggingFace model, configurable via env var — no code changes needed

## Prerequisites

- [RunPod account](https://runpod.io) with an API key
- SSH key added to your RunPod account (Settings → SSH Public Keys)
- `curl` and `python3` available locally

## Quickstart

```bash
# 1. Configure
cp config.env.example config.env
# Fill in: RUNPOD_API_KEY, HF_MODEL_ID, JUPYTER_PASSWORD

# 2. Provision
bash scripts/provision.sh

# 3. Check status (wait ~3-5 min for deps + model download)
bash scripts/status.sh

# 4. Tear down when done
bash scripts/teardown.sh
```

## Configuration

Copy `config.env.example` to `config.env` and set:

| Variable | Description | Example |
|---|---|---|
| `RUNPOD_API_KEY` | RunPod API key | `rpa_...` |
| `HF_MODEL_ID` | HuggingFace model ID | `google-bert/bert-base-uncased` |
| `MODEL_TASK` | Pipeline task type | `text-classification` |
| `JUPYTER_PASSWORD` | JupyterLab token | `changeme123` |
| `GPU_TYPE` | GPU to request | `NVIDIA GeForce RTX 4090` |
| `HF_TOKEN` | HuggingFace token (gated models only) | `hf_...` |

Supported `MODEL_TASK` values: `text-classification`, `text-generation`, `token-classification`, `question-answering`, `summarization`, `translation`, `fill-mask`, `zero-shot-classification`

## Scripts

| Command | Description |
|---|---|
| `bash scripts/provision.sh` | Create pod and tail startup progress |
| `bash scripts/provision.sh --no-tail` | Create pod without waiting |
| `bash scripts/logs.sh [POD_ID]` | Tail startup progress for a running pod |
| `bash scripts/status.sh` | Show pod status and access URLs |
| `bash scripts/teardown.sh` | **Stop + permanently delete** pod (default) |
| `bash scripts/teardown.sh --stop` | Stop only — pod can be resumed |
| `bash scripts/start.sh` | Resume a stopped pod |
| `bash scripts/build_push.sh` | Build and push custom Docker image to a registry |

## Inference API

Once the pod is running, the FastAPI server is available at `https://<POD_ID>-8000.proxy.runpod.net`.

**Interactive docs:** `/docs`

**Health check:**
```bash
curl https://<POD_ID>-8000.proxy.runpod.net/health
```

**Run inference:**
```bash
curl -X POST https://<POD_ID>-8000.proxy.runpod.net/predict \
  -H "Content-Type: application/json" \
  -d '{"inputs": "Hello, world!"}'
```

**Batch inference:**
```bash
curl -X POST https://<POD_ID>-8000.proxy.runpod.net/predict/batch \
  -H "Content-Type: application/json" \
  -d '{"inputs": ["Hello, world!", "How are you?"]}'
```

**Model info:**
```bash
curl https://<POD_ID>-8000.proxy.runpod.net/model
```

## Stack

- **GPU cloud**: RunPod Secure Cloud
- **Base image**: `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04`
- **ML**: TensorFlow 2.16 + HuggingFace `transformers` (TF backend)
- **Inference server**: FastAPI + Uvicorn
- **Dev access**: JupyterLab (port 8888) + SSH

## How it works

`provision.sh` base64-encodes `inference/server.py` and `post_start.sh` and injects them into the pod's startup command — no Docker registry required. On boot:

1. `start.sh` starts nginx, SSH, and JupyterLab
2. `post_start.sh` installs Python dependencies, downloads model weights to `/workspace/.cache/huggingface`, and starts the Uvicorn server

Startup log is available at `/workspace/inference_server.log` (visible in JupyterLab terminal).
