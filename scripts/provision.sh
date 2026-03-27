#!/bin/bash
# Provision a RunPod GPU pod for HuggingFace inference.
# No Docker registry required — inference code is injected via base64 at pod boot.
#
# Usage:
#   cp config.env.example config.env  # fill in your values
#   bash scripts/provision.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/config.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found. Copy config.env.example to config.env and fill in values."
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in config.env}"
: "${HF_MODEL_ID:?Set HF_MODEL_ID in config.env}"
: "${JUPYTER_PASSWORD:?Set JUPYTER_PASSWORD in config.env}"

GPU_TYPE="${GPU_TYPE:-NVIDIA GeForce RTX 4090}"
GPU_COUNT="${GPU_COUNT:-1}"
CLOUD_TYPE="${CLOUD_TYPE:-SECURE}"
DATACENTER_ID="${DATACENTER_ID:-US-TX-1}"
CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-50}"
NETWORK_VOLUME_GB="${NETWORK_VOLUME_GB:-100}"
NETWORK_VOLUME_NAME="${NETWORK_VOLUME_NAME:-hf-model-cache}"
POD_NAME="${POD_NAME:-hf-inference-pod}"
INFERENCE_PORT="${INFERENCE_PORT:-8000}"
DOCKER_IMAGE="${DOCKER_IMAGE:-runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04}"

RUNPOD_API="https://rest.runpod.io/v1"
AUTH_HEADER="Authorization: Bearer $RUNPOD_API_KEY"

echo "=== RunPod Provisioner ==="
echo "Model   : $HF_MODEL_ID"
echo "GPU     : ${GPU_COUNT}x $GPU_TYPE ($CLOUD_TYPE)"
echo "Image   : $DOCKER_IMAGE"

# ---------------------------------------------------------------------------
# Step 1: Create (or reuse) network volume
# ---------------------------------------------------------------------------
NETWORK_VOLUME_ID="${NETWORK_VOLUME_ID:-}"

if [[ -z "$NETWORK_VOLUME_ID" && "${NETWORK_VOLUME_GB:-0}" -gt 0 ]]; then
    echo ""
    echo "Creating network volume '$NETWORK_VOLUME_NAME' (${NETWORK_VOLUME_GB} GB)..."
    VOL_RESPONSE=$(curl -s -X POST "$RUNPOD_API/networkvolumes" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$NETWORK_VOLUME_NAME\", \"size\": $NETWORK_VOLUME_GB, \"dataCenterId\": \"$DATACENTER_ID\"}")
    NETWORK_VOLUME_ID=$(echo "$VOL_RESPONSE" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); r=d[0] if isinstance(d,list) else d; print(r.get('id',''))" 2>/dev/null || true)
    if [[ -z "$NETWORK_VOLUME_ID" ]]; then
        echo "WARNING: Could not create network volume: $VOL_RESPONSE"
        echo "Continuing without network volume (HF cache will be ephemeral)."
    else
        echo "Network volume created: $NETWORK_VOLUME_ID"
        echo "  → Add NETWORK_VOLUME_ID=$NETWORK_VOLUME_ID to config.env to reuse it."
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: Build JSON payload via Python (handles escaping + base64 injection)
# ---------------------------------------------------------------------------
echo ""
echo "Building pod payload..."

RESPONSE=$(python3 - <<PYEOF
import base64, json, os, sys

root = "$ROOT_DIR"

def b64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode()

server_py   = b64(os.path.join(root, "inference", "server.py"))
init_py     = b64(os.path.join(root, "inference", "__init__.py"))
post_start  = b64(os.path.join(root, "post_start.sh"))

# Bootstrap command: decode files onto disk then hand off to /start.sh
# /start.sh (from base RunPod image) then calls /post_start.sh automatically
bootstrap = (
    "set -e && "
    "mkdir -p /inference && "
    f"echo '{server_py}'  | base64 -d > /inference/server.py && "
    f"echo '{init_py}'    | base64 -d > /inference/__init__.py && "
    f"echo '{post_start}' | base64 -d > /post_start.sh && "
    "chmod +x /post_start.sh && "
    "exec /start.sh"
)

env = {
    "HF_MODEL_ID":          "$HF_MODEL_ID",
    "MODEL_TASK":           "${MODEL_TASK:-text-classification}",
    "JUPYTER_PASSWORD":     "$JUPYTER_PASSWORD",
    "INFERENCE_PORT":       "$INFERENCE_PORT",
    "HF_HOME":              "/workspace/.cache/huggingface",
    "TRANSFORMERS_CACHE":   "/workspace/.cache/huggingface/hub",
}
hf_token = "${HF_TOKEN:-}"
if hf_token:
    env["HF_TOKEN"] = hf_token

network_volume_id = "$NETWORK_VOLUME_ID"
volume_config = (
    {"networkVolumeId": network_volume_id}
    if network_volume_id
    else {"volumeInGb": 20}
)

payload = {
    "name":               "$POD_NAME",
    "imageName":          "$DOCKER_IMAGE",
    "gpuTypeIds":         ["$GPU_TYPE"],
    "gpuCount":           int("$GPU_COUNT"),
    "cloudType":          "$CLOUD_TYPE",
    "containerDiskInGb":  int("$CONTAINER_DISK_GB"),
    "volumeMountPath":    "/workspace",
    "ports":              ["${INFERENCE_PORT}/http", "8888/http", "22/tcp"],
    "env":                env,
    "dockerStartCmd":     ["/bin/bash", "-c", bootstrap],
    **volume_config,
}

print(json.dumps(payload))
PYEOF
)

# ---------------------------------------------------------------------------
# Step 3: Create the pod
# ---------------------------------------------------------------------------
echo "Creating pod '$POD_NAME'..."
API_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$RUNPOD_API/pods" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$RESPONSE")

HTTP_CODE=$(echo "$API_RESPONSE" | tail -1)
BODY=$(echo "$API_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "201" ]]; then
    echo "ERROR: Pod creation failed (HTTP $HTTP_CODE)"
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: Parse and display access info
# ---------------------------------------------------------------------------
POD_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
COST=$(echo "$BODY"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('costPerHr','?'))")

echo "$POD_ID" > "$ROOT_DIR/.pod_id"
[[ -n "$NETWORK_VOLUME_ID" ]] && echo "$NETWORK_VOLUME_ID" > "$ROOT_DIR/.volume_id"

echo ""
echo "========================================="
echo " Pod created successfully!"
echo "========================================="
echo " Pod ID  : $POD_ID"
echo " Cost    : ~\$$COST/hr"
echo ""
echo " Wait ~3-5 min for dependencies to install and model to download."
echo ""
echo " JupyterLab : https://${POD_ID}-8888.proxy.runpod.net"
echo "   Token   : $JUPYTER_PASSWORD"
echo ""
echo " Inference  : https://${POD_ID}-${INFERENCE_PORT}.proxy.runpod.net"
echo "   Health  : https://${POD_ID}-${INFERENCE_PORT}.proxy.runpod.net/health"
echo "   Docs    : https://${POD_ID}-${INFERENCE_PORT}.proxy.runpod.net/docs"
echo ""
echo " SSH: see RunPod console → Connect (pod must be RUNNING first)"
echo ""
echo " Monitor startup: tail -f /workspace/inference_server.log  (via JupyterLab terminal)"
echo ""
echo " To stop:  bash scripts/teardown.sh"
echo "========================================="
