#!/bin/bash
# Check pod status and print access URLs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/config.env"
POD_ID_FILE="$ROOT_DIR/.pod_id"

source "$ENV_FILE"
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in config.env}"

POD_ID="${POD_ID:-}"
if [[ -z "$POD_ID" && -f "$POD_ID_FILE" ]]; then
    POD_ID=$(cat "$POD_ID_FILE")
fi
if [[ -z "$POD_ID" ]]; then
    echo "No pod ID found. Run scripts/provision.sh first."
    exit 0
fi

INFERENCE_PORT="${INFERENCE_PORT:-8000}"

python3 - "$POD_ID" "$RUNPOD_API_KEY" "$INFERENCE_PORT" <<'EOF'
import json, sys, urllib.request, urllib.error

pod_id, api_key, inference_port = sys.argv[1], sys.argv[2], sys.argv[3]

req = urllib.request.Request(
    f"https://rest.runpod.io/v1/pods/{pod_id}",
    headers={"Authorization": f"Bearer {api_key}"},
)
try:
    with urllib.request.urlopen(req) as resp:
        raw = json.loads(resp.read())
except urllib.error.HTTPError as e:
    if e.code == 404:
        print(f"Pod {pod_id} not found (may have been deleted).")
        print("Run 'bash scripts/provision.sh' to create a new pod.")
        sys.exit(0)
    print(f"API error: HTTP {e.code}")
    sys.exit(1)

data   = raw[0] if isinstance(raw, list) else raw
status = data.get("desiredStatus", "?")
cost   = data.get("costPerHr", "?")
gpu    = data.get("machine", {}).get("gpuDisplayName", "?")

print(f"Pod ID : {pod_id}")
print(f"Status : {status}")
print(f"GPU    : {gpu}")
print(f"Cost   : ~${cost}/hr")
print()
if status == "RUNNING":
    print(f"JupyterLab : https://{pod_id}-8888.proxy.runpod.net")
    print(f"Inference  : https://{pod_id}-{inference_port}.proxy.runpod.net/docs")
    print(f"Health     : https://{pod_id}-{inference_port}.proxy.runpod.net/health")
elif status == "EXITED":
    print("Pod is stopped. Resume with: bash scripts/start.sh")
else:
    print(f"Pod status: {status}")
EOF
