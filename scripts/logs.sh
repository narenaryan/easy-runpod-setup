#!/bin/bash
# Wait for pod to be RUNNING, then tail inference server startup progress
# by polling the health endpoint and reporting model load status.
#
# Usage:
#   bash scripts/logs.sh                      # uses POD_ID from .pod_id
#   bash scripts/logs.sh <POD_ID>             # explicit pod ID
#   INFERENCE_PORT=8000 bash scripts/logs.sh  # custom port
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/config.env"
POD_ID_FILE="$ROOT_DIR/.pod_id"

source "$ENV_FILE"
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in config.env}"

INFERENCE_PORT="${INFERENCE_PORT:-8000}"

# Resolve pod ID from arg, env, or .pod_id file
POD_ID="${1:-${POD_ID:-}}"
if [[ -z "$POD_ID" && -f "$POD_ID_FILE" ]]; then
    POD_ID=$(cat "$POD_ID_FILE")
fi
if [[ -z "$POD_ID" ]]; then
    echo "Usage: bash scripts/logs.sh <POD_ID>"
    echo "Or run scripts/provision.sh first."
    exit 1
fi

BASE_URL="https://${POD_ID}-${INFERENCE_PORT}.proxy.runpod.net"
JUPYTER_URL="https://${POD_ID}-8888.proxy.runpod.net"

echo "=== Pod ${POD_ID} ==="
echo "Inference : ${BASE_URL}"
echo "JupyterLab: ${JUPYTER_URL}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Wait for pod to reach RUNNING status
# ---------------------------------------------------------------------------
echo "Waiting for pod to reach RUNNING status..."
while true; do
    STATUS=$(python3 - "$POD_ID" "$RUNPOD_API_KEY" <<'EOF'
import sys, json, urllib.request, urllib.error
pod_id, api_key = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"https://rest.runpod.io/v1/pods/{pod_id}",
    headers={"Authorization": f"Bearer {api_key}"},
)
try:
    with urllib.request.urlopen(req) as resp:
        d = json.loads(resp.read())
        data = d[0] if isinstance(d, list) else d
        print(data.get("desiredStatus", "UNKNOWN"))
except urllib.error.HTTPError as e:
    print("NOT_FOUND" if e.code == 404 else "ERROR")
EOF
)
    case "$STATUS" in
        RUNNING)
            echo "  Pod is RUNNING."
            break ;;
        EXITED|NOT_FOUND)
            echo "  Pod is $STATUS — run 'bash scripts/start.sh' first."
            exit 1 ;;
        *)
            printf "  Status: %-12s\r" "$STATUS"
            sleep 5 ;;
    esac
done

# ---------------------------------------------------------------------------
# Step 2: Poll health endpoint until inference server is up
# ---------------------------------------------------------------------------
echo ""
echo "Waiting for inference server to start (pip install + model download)..."
echo "Tip: tail logs live via JupyterLab terminal:"
echo "  ${JUPYTER_URL}  →  tail -f /workspace/inference_server.log"
echo ""

ATTEMPT=0
SERVER_UP=false
while true; do
    ATTEMPT=$((ATTEMPT + 1))
    RESULT=$(python3 - "$BASE_URL" <<'EOF'
import sys, json, urllib.request, urllib.error, socket
url = sys.argv[1] + "/health"
try:
    req = urllib.request.Request(url, headers={"User-Agent": "logs.sh"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read())
        print(body.get("status", "unknown"))
except urllib.error.HTTPError as e:
    print(f"http_{e.code}")
except Exception:
    print("unavailable")
EOF
)

    ELAPSED=$(( ATTEMPT * 10 ))
    MINS=$(( ELAPSED / 60 ))
    SECS=$(( ELAPSED % 60 ))
    TIMESTAMP=$(printf "%dm%02ds" $MINS $SECS)

    case "$RESULT" in
        ok)
            echo "  [${TIMESTAMP}] Inference server is UP."
            SERVER_UP=true
            break ;;
        loading)
            echo "  [${TIMESTAMP}] Server is up — model still loading into GPU..." ;;
        http_502|http_503|unavailable)
            echo "  [${TIMESTAMP}] Server not ready yet (${RESULT})..." ;;
        *)
            echo "  [${TIMESTAMP}] ${RESULT}" ;;
    esac

    sleep 10
done

# ---------------------------------------------------------------------------
# Step 3: Show final model info
# ---------------------------------------------------------------------------
if $SERVER_UP; then
    echo ""
    MODEL_INFO=$(python3 - "$BASE_URL" <<'EOF'
import sys, json, urllib.request
url = sys.argv[1] + "/model"
try:
    with urllib.request.urlopen(url, timeout=10) as resp:
        d = json.loads(resp.read())
        print(f"  Model   : {d.get('model_id','?')}")
        print(f"  Task    : {d.get('task','?')}")
        print(f"  Backend : {d.get('framework','?')}")
        print(f"  Load    : {d.get('load_time_seconds','?')}s")
except Exception as e:
    print(f"  (could not fetch model info: {e})")
EOF
)
    echo "$MODEL_INFO"
    echo ""
    echo "========================================="
    echo " Ready!"
    echo "========================================="
    echo " Health : ${BASE_URL}/health"
    echo " Docs   : ${BASE_URL}/docs"
    echo ""
    echo " Quick test:"
    echo "   curl -X POST ${BASE_URL}/predict \\"
    echo "     -H 'Content-Type: application/json' \\"
    echo "     -d '{\"inputs\": \"Write a hello world in Python\", \"parameters\": {\"max_new_tokens\": 100}}'"
    echo "========================================="
fi
