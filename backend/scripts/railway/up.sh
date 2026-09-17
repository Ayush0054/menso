#!/bin/bash
set -e

command -v railway >/dev/null || { echo "Install and log in to the Railway CLI first."; exit 1; }
[[ -n "${OPENAI_API_KEY:-}" ]] || { echo "Export OPENAI_API_KEY or load .env.production first."; exit 1; }
[[ -n "${JWT_VERIFICATION_KEY:-}" ]] || {
    if [[ -n "${JWT_JWKS_FILE:-}" ]]; then
        echo "Railway up.sh cannot upload JWT_JWKS_FILE; export an inline JWT_VERIFICATION_KEY instead."
    else
        echo "Production JWT_VERIFICATION_KEY is required."
    fi
    exit 1
}
[[ -n "${DB_PASS:-}" ]] || { echo "Export a strong DB_PASS before provisioning Railway."; exit 1; }
[[ -n "${MENSO_SAFETY_IDENTIFIER_SALT:-}" ]] || { echo "MENSO_SAFETY_IDENTIFIER_SALT is required."; exit 1; }
[[ "${#MENSO_SAFETY_IDENTIFIER_SALT}" -ge 32 ]] || { echo "MENSO_SAFETY_IDENTIFIER_SALT must contain at least 32 characters."; exit 1; }

railway init -n menso-agentos
railway add -s pgvector -i agnohq/pgvector:18 \
    -v "POSTGRES_USER=${DB_USER:-menso}" \
    -v "POSTGRES_DB=${DB_DATABASE:-menso}"
railway variables --set "POSTGRES_PASSWORD=${DB_PASS}" --service pgvector >/dev/null 2>&1
railway service link pgvector
railway volume add -m /var/lib/postgresql
railway add -s menso-agentos \
    -v "RUNTIME_ENV=prd" \
    -v "DB_DRIVER=postgresql+psycopg" \
    -v "DB_HOST=pgvector.railway.internal" \
    -v "DB_PORT=5432" \
    -v "DB_USER=${DB_USER:-menso}" \
    -v "DB_DATABASE=${DB_DATABASE:-menso}" \
    -v "PORT=8000"
railway variables --set "DB_PASS=${DB_PASS}" --service menso-agentos >/dev/null 2>&1
railway variables --set "OPENAI_API_KEY=${OPENAI_API_KEY}" --service menso-agentos >/dev/null 2>&1
railway variables --set "MENSO_SAFETY_IDENTIFIER_SALT=${MENSO_SAFETY_IDENTIFIER_SALT}" --service menso-agentos >/dev/null 2>&1
[[ -n "${JWT_VERIFICATION_KEY:-}" ]] && railway variables --set "JWT_VERIFICATION_KEY=${JWT_VERIFICATION_KEY}" --service menso-agentos >/dev/null 2>&1

# The service metadata must know the public origin before the first process starts.
# Prefer an explicitly pinned custom origin; otherwise use Railway's domain.
DOMAIN_OUTPUT="$(railway domain --service menso-agentos 2>&1 || true)"
echo "$DOMAIN_OUTPUT"
APP_URL="$(grep -oE 'https://[A-Za-z0-9.-]+|[A-Za-z0-9-]+\.up\.railway\.app' <<< "$DOMAIN_OUTPUT" | head -1)"
[[ -n "$APP_URL" && "$APP_URL" != https://* ]] && APP_URL="https://${APP_URL}"
PUBLIC_ORIGIN="${AGENTOS_PUBLIC_URL:-${AGENTOS_URL:-$APP_URL}}"
[[ -n "$PUBLIC_ORIGIN" ]] || { echo "Could not determine the Railway public origin; aborting before deploy."; exit 1; }
[[ "$PUBLIC_ORIGIN" == https://* ]] || { echo "Production AgentOS origin must use HTTPS."; exit 1; }
railway variables --set "AGENTOS_URL=${PUBLIC_ORIGIN}" --service menso-agentos >/dev/null 2>&1
railway variables --set "AGENTOS_PUBLIC_URL=${PUBLIC_ORIGIN}" --service menso-agentos >/dev/null 2>&1
railway up --service menso-agentos -d

echo "Menso AgentOS deployed at ${PUBLIC_ORIGIN}."
