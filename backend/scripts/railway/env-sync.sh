#!/bin/bash
set -e

ENV_FILE="${1:-.env.production}"
[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE}"; exit 1; }
command -v railway >/dev/null || { echo "Railway CLI is not installed."; exit 1; }
railway status >/dev/null || { echo "No linked Railway project."; exit 1; }

count=0
current_key=""
current_value=""

while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${current_key}" ]]; then
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" == *=* ]] || { echo "Invalid environment line (missing '='): ${line}"; exit 1; }
        current_key="${line%%=*}"
        current_value="${line#*=}"
        [[ "${current_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
            echo "Invalid environment variable name: ${current_key}"
            exit 1
        }
    else
        current_value="${current_value}
${line}"
    fi

    if [[ "${current_value}" == *"-----BEGIN"* && "${current_value}" != *"-----END"* ]]; then
        continue
    fi

    current_value="${current_value#\"}"
    current_value="${current_value%\"}"
    current_value="${current_value#\'}"
    current_value="${current_value%\'}"

    echo "Setting ${current_key}"
    railway variables --set "${current_key}=${current_value}" --service menso-agentos >/dev/null 2>&1
    count=$((count + 1))
    current_key=""
    current_value=""
done < "${ENV_FILE}"

[[ -z "${current_key}" ]] || { echo "Unterminated multiline value for ${current_key}"; exit 1; }
echo "Synced ${count} variable(s) to menso-agentos."
