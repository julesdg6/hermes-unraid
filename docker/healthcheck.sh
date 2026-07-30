#!/usr/bin/env bash
set -Eeuo pipefail

GATEWAY_URL="${HERMES_GATEWAY_URL:-http://127.0.0.1:8642}"
if [[ "$GATEWAY_URL" == */health ]]; then
  GATEWAY_HEALTH_URL="$GATEWAY_URL"
else
  GATEWAY_HEALTH_URL="${GATEWAY_URL%/}/health"
fi

DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
WEBUI_PORT="${WEBUI_PORT:-8787}"

# Gateway: check the /health endpoint returns 200
curl -fsS --max-time 5 "$GATEWAY_HEALTH_URL" >/dev/null

# Dashboard: check the port is open (omit -f so basic auth 401 does not fail the health check)
curl -s --max-time 5 -o /dev/null "http://127.0.0.1:${DASHBOARD_PORT}/" || exit 1

# WebUI: check the /health endpoint returns 200
curl -fsS --max-time 5 "http://127.0.0.1:${WEBUI_PORT}/health" >/dev/null
