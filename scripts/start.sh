#!/bin/bash
# Restart a stopped pod (resumes from the same network volume).
#
# Usage:
#   bash scripts/start.sh
#   POD_ID=abc123 bash scripts/start.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/config.env"
POD_ID_FILE="$ROOT_DIR/.pod_id"

source "$ENV_FILE"
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in config.env}"

RUNPOD_API="https://rest.runpod.io/v1"
AUTH_HEADER="Authorization: Bearer $RUNPOD_API_KEY"

POD_ID="${POD_ID:-}"
if [[ -z "$POD_ID" && -f "$POD_ID_FILE" ]]; then
    POD_ID=$(cat "$POD_ID_FILE")
fi
if [[ -z "$POD_ID" ]]; then
    echo "ERROR: No pod ID found. Run scripts/provision.sh to create a new pod."
    exit 1
fi

echo "Starting pod $POD_ID..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$RUNPOD_API/pods/$POD_ID/start" \
    -H "$AUTH_HEADER")

if [[ "$HTTP_CODE" == "200" ]]; then
    INFERENCE_PORT="${INFERENCE_PORT:-8000}"
    echo "Pod $POD_ID starting."
    echo ""
    echo " JupyterLab : https://${POD_ID}-8888.proxy.runpod.net"
    echo " Inference  : https://${POD_ID}-${INFERENCE_PORT}.proxy.runpod.net/docs"
    echo " SSH        : see RunPod console → Connect"
else
    echo "ERROR: START returned HTTP $HTTP_CODE"
    exit 1
fi
