#!/bin/bash
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ruff format "${REPO_ROOT}"
ruff check --select I --fix "${REPO_ROOT}"
