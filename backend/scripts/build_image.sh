#!/bin/bash
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-menso-agentos}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
docker buildx build --platform=linux/amd64,linux/arm64 -t "${IMAGE_NAME}:${IMAGE_TAG}" -f "${REPO_ROOT}/Dockerfile" "${REPO_ROOT}" --push
