#!/bin/bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0
ruff check "${REPO_ROOT}" || failed=1
mypy "${REPO_ROOT}" --config-file "${REPO_ROOT}/pyproject.toml" || failed=1
exit "${failed}"
