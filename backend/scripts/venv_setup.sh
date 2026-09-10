#!/bin/bash
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${REPO_ROOT}/.venv"

if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    echo "Deactivate the active virtual environment first."
    exit 1
fi
command -v uv >/dev/null || { echo "Install uv: https://docs.astral.sh/uv/"; exit 1; }
uv venv "${VENV_DIR}" --python 3.12
VIRTUAL_ENV="${VENV_DIR}" uv pip install -r "${REPO_ROOT}/requirements.txt"
VIRTUAL_ENV="${VENV_DIR}" uv pip install -e "${REPO_ROOT}[dev]"
echo "Activate with: source .venv/bin/activate"
