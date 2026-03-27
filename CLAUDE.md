# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Provision a RunPod GPU pod with TensorFlow + NVIDIA CUDA, download a configurable HuggingFace model, and run a FastAPI inference server. The pod exposes JupyterLab (port 8888) and the inference API (port 8000) via RunPod's HTTPS proxy, plus SSH access.

## Stack

- **Cloud**: RunPod GPU pods (Secure Cloud) via REST API (`https://rest.runpod.io/v1`)
- **Base image**: `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04` — includes nginx (required for RunPod proxy), openssh-server, JupyterLab, and the canonical `/start.sh`
- **ML**: PyTorch (pre-installed in base image), HuggingFace `transformers` with PyTorch backend (`framework="pt"`)
- **Inference server**: FastAPI + Uvicorn, model loaded via `transformers.pipeline`
- **Persistent storage**: RunPod network volume mounted at `/workspace`; HF model cache at `/workspace/.cache/huggingface`

## Key Files

| File | Purpose |
|---|---|
| `Dockerfile` | Extends RunPod PyTorch base, installs TF + HF + FastAPI |
| `start.sh` | Canonical RunPod entrypoint: nginx → SSH → JupyterLab → `post_start.sh` → `sleep infinity` |
| `post_start.sh` | Downloads HF model weights, starts Uvicorn inference server |
| `inference/server.py` | FastAPI app: `/health`, `/model`, `POST /predict`, `POST /predict/batch` |
| `config.env.example` | All configurable env vars — copy to `config.env` before provisioning |
| `scripts/provision.sh` | Creates network volume + pod via RunPod REST API |
| `scripts/teardown.sh` | Stops (`--delete` to permanently delete) the pod |
| `scripts/start.sh` | Restarts a stopped pod |
| `scripts/status.sh` | Shows pod status and access URLs |
| `scripts/build_push.sh` | Builds and pushes Docker image to a registry |

## Development Workflow

```bash
# 1. Configure
cp config.env.example config.env
# edit config.env: RUNPOD_API_KEY, HF_MODEL_ID, JUPYTER_PASSWORD, GPU_TYPE, etc.

# 2. (Optional) Build and push your custom Docker image
DOCKER_REGISTRY=docker.io/youruser bash scripts/build_push.sh
# then set DOCKER_IMAGE in config.env

# 3. Provision pod + network volume
bash scripts/provision.sh

# 4. Check status / get URLs
bash scripts/status.sh

# 5. Stop (preserves /workspace) / Delete
bash scripts/teardown.sh
bash scripts/teardown.sh --delete

# 6. Restart a stopped pod
bash scripts/start.sh
```

### Local Docker testing (requires NVIDIA Container Toolkit)

```bash
docker build -t runpod-hf-inference .
docker run --gpus all \
  -p 8888:8888 -p 8000:8000 \
  --env-file config.env \
  -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  runpod-hf-inference
```

## Access URLs (after pod starts)

RunPod proxies HTTP ports through Cloudflare:

```
JupyterLab  : https://<POD_ID>-8888.proxy.runpod.net   (token = JUPYTER_PASSWORD)
Inference   : https://<POD_ID>-8000.proxy.runpod.net/docs
Health      : https://<POD_ID>-8000.proxy.runpod.net/health
SSH         : ssh <POD_ID>-<CONTAINER_ID>@ssh.runpod.io -i ~/.ssh/id_ed25519
```

The `POD_ID` is saved to `.pod_id` by `provision.sh`.

## RunPod Architecture Notes

- **`CMD` not `ENTRYPOINT`**: RunPod requires `CMD ["/start.sh"]`; an ENTRYPOINT would block RunPod's template start command.
- **`/post_start.sh` hook**: `start.sh` calls this automatically if it exists — put custom workload startup here, not in `start.sh`.
- **`PUBLIC_KEY` env var**: Injected by RunPod from your account SSH keys. `start.sh` writes it to `~/.ssh/authorized_keys`.
- **Port proxy timeout**: RunPod's HTTP proxy (Cloudflare) has a 100-second timeout. Use streaming or chunked responses for long inference calls.
- **Network volumes**: Secure Cloud only; attach at pod creation time; can't be resized down. HF cache persists across pod restarts.
- **Env var persistence**: `start.sh` exports all uppercase env vars to `/etc/rp_environment` (sourced in `.bashrc`), so they survive new SSH/JupyterLab terminal sessions.

## Changing the Model

Edit `HF_MODEL_ID` and `MODEL_TASK` in `config.env` before provisioning. Supported tasks:

```
text-classification, text-generation, token-classification,
question-answering, summarization, translation, fill-mask,
zero-shot-classification
```

For gated models (e.g. Meta Llama), set `HF_TOKEN`.

## PyTorch / CUDA

PyTorch 2.4 with CUDA 12.4 is pre-installed in the `runpod/pytorch` base image. Do not install TensorFlow alongside it — `tensorflow[and-cuda]` installs its own cuDNN wheels that conflict with PyTorch's `libcudnn.so.9` and cause an `ImportError` at startup.
