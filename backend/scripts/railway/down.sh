#!/bin/bash
set -e

railway status >/dev/null || { echo "No linked Railway project."; exit 1; }
if [[ "${1:-}" != "--yes" ]]; then
    echo "This deletes the linked Menso API, Postgres database, volume, and all persisted data."
    read -r -p "Type DELETE-MENSO to continue: " confirmation
    [[ "${confirmation}" = "DELETE-MENSO" ]] || { echo "Aborted."; exit 1; }
fi
railway delete --yes
