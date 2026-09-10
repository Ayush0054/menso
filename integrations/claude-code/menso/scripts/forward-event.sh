#!/bin/sh

# Lifecycle hooks cannot all use Claude Code's HTTP hook transport. Forward
# their JSON stdin without ever blocking the Claude session when Menso is off.
if [ -z "${MENSO_HOOK_TOKEN:-}" ]; then
  exit 0
fi

/usr/bin/curl \
  --silent \
  --show-error \
  --fail \
  --max-time 2 \
  --request POST \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer ${MENSO_HOOK_TOKEN}" \
  --data-binary @- \
  "http://127.0.0.1:49743/hook" \
  >/dev/null 2>&1 || true

exit 0
