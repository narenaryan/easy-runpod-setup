#!/bin/bash
# Stop and terminate the RunPod pod.
#
# Usage:
#   bash scripts/teardown.sh           # stop + permanently delete pod (default)
#   bash scripts/teardown.sh --stop    # stop only, preserves pod (resume with start.sh)
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
    echo "ERROR: No pod ID found. Run scripts/provision.sh first."
    exit 1
fi

if [[ "${1:-}" == "--stop" ]]; then
    echo "Stopping pod $POD_ID (pod preserved, resume with: bash scripts/start.sh)..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$RUNPOD_API/pods/$POD_ID/stop" \
        -H "$AUTH_HEADER")
    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "Pod $POD_ID stopped."
    else
        echo "ERROR: STOP returned HTTP $HTTP_CODE"
        exit 1
    fi
else
    echo "Terminating pod $POD_ID (stop + delete, irreversible)..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$RUNPOD_API/pods/$POD_ID" \
        -H "$AUTH_HEADER")
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
        echo "Pod $POD_ID terminated."
        rm -f "$POD_ID_FILE"
    else
        echo "ERROR: DELETE returned HTTP $HTTP_CODE"
        exit 1
    fi
fi
