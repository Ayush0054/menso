#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

if [[ "${1:-}" = "upgrade" ]]; then
    UV_CUSTOM_COMPILE_COMMAND="./scripts/generate_requirements.sh upgrade" \
        uv pip compile "${REPO_ROOT}/pyproject.toml" --no-cache --upgrade -o "${REPO_ROOT}/requirements.txt"
else
    UV_CUSTOM_COMPILE_COMMAND="./scripts/generate_requirements.sh" \
        uv pip compile "${REPO_ROOT}/pyproject.toml" --no-cache -o "${REPO_ROOT}/requirements.txt"
fi
