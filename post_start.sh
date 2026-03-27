#!/bin/bash
# Runs after SSH and JupyterLab are up (called by start.sh).
# 1. Installs Python dependencies (pip) — skipped if already installed
# 2. Pre-downloads the HuggingFace model to the persistent volume cache
# 3. Starts the FastAPI inference server
set -e

INFERENCE_PORT=${INFERENCE_PORT:-8000}
HF_MODEL_ID=${HF_MODEL_ID:-"google-bert/bert-base-uncased"}
MODEL_TASK=${MODEL_TASK:-"text-classification"}
LOG_FILE=/workspace/inference_server.log

echo "=== post_start.sh ==="
echo "Model : $HF_MODEL_ID"
echo "Task  : $MODEL_TASK"
echo "Port  : $INFERENCE_PORT"

# Ensure workspace cache directory exists on the volume
mkdir -p "${HF_HOME:-/workspace/.cache/huggingface}"

# Install dependencies if not already present
if ! python3 -c "import fastapi" &>/dev/null; then
    echo "Installing Python dependencies..."
    pip install --no-cache-dir \
        "tensorflow[and-cuda]==2.16.2" \
        "transformers>=4.40.0" \
        "huggingface_hub>=0.23.0" \
        "accelerate>=0.30.0" \
        "fastapi>=0.111.0" \
        "uvicorn[standard]>=0.29.0" \
        "pydantic>=2.7.0" \
        "numpy>=1.26.0"
    echo "Dependencies installed."
else
    echo "Dependencies already installed, skipping."
fi

# Pre-download model weights so the inference server starts immediately
echo "Pre-downloading model weights for $HF_MODEL_ID ..."
python3 - <<EOF
import os
from huggingface_hub import snapshot_download

model_id = os.environ.get("HF_MODEL_ID", "google-bert/bert-base-uncased")
hf_token = os.environ.get("HF_TOKEN") or None

snapshot_download(
    repo_id=model_id,
    token=hf_token,
    ignore_patterns=["*.msgpack", "flax_model*", "tf_model*"] if os.environ.get("MODEL_TASK") != "text-generation" else ["*.msgpack", "flax_model*"],
)
print(f"Model {model_id} ready.")
EOF

# Start the inference server
echo "Starting inference server (log: $LOG_FILE) ..."
cd / && nohup python3 -m uvicorn inference.server:app \
    --host 0.0.0.0 \
    --port "$INFERENCE_PORT" \
    --log-level info \
    &>"$LOG_FILE" &

echo "Inference server starting on port $INFERENCE_PORT"
