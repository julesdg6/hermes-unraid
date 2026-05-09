#!/usr/bin/env bash
set -Eeuo pipefail

GATEWAY_URL="${HERMES_GATEWAY_URL:-http://127.0.0.1:8642}"
if [[ "$GATEWAY_URL" == */health ]]; then
  GATEWAY_HEALTH_URL="$GATEWAY_URL"
else
  GATEWAY_HEALTH_URL="${GATEWAY_URL%/}/health"
fi

DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
WEBUI_PORT="${WEBUI_PORT:-${HERMES_WEBUI_PORT:-8787}}"

curl -fsS --max-time 5 "$GATEWAY_HEALTH_URL" >/dev/null
curl -fsS --max-time 5 "http://127.0.0.1:${DASHBOARD_PORT}/" >/dev/null
curl -fsS --max-time 5 "http://127.0.0.1:${WEBUI_PORT}/health" >/dev/null
