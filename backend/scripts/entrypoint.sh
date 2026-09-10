#!/bin/bash
set -e

if [[ "${WAIT_FOR_DB:-False}" = "true" || "${WAIT_FOR_DB:-False}" = "True" ]]; then
    echo "Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}..."
    dockerize -wait "tcp://${DB_HOST}:${DB_PORT}" -timeout 300s
fi

exec "$@"
