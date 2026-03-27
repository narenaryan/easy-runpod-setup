#!/bin/bash
# Build the Docker image and push it to a registry.
# RunPod pulls from Docker Hub or any public/private registry.
#
# Usage:
#   DOCKER_REGISTRY=docker.io/youruser bash scripts/build_push.sh
#   DOCKER_REGISTRY=docker.io/youruser IMAGE_TAG=v1.2 bash scripts/build_push.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

DOCKER_REGISTRY="${DOCKER_REGISTRY:?Set DOCKER_REGISTRY (e.g. docker.io/youruser)}"
IMAGE_NAME="${IMAGE_NAME:-runpod-hf-inference}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="$DOCKER_REGISTRY/$IMAGE_NAME:$IMAGE_TAG"

echo "Building $FULL_IMAGE ..."
docker build -t "$FULL_IMAGE" "$ROOT_DIR"

echo "Pushing $FULL_IMAGE ..."
docker push "$FULL_IMAGE"

echo ""
echo "Image pushed: $FULL_IMAGE"
echo "Set DOCKER_IMAGE=$FULL_IMAGE in config.env before running provision.sh"
