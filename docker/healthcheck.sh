#!/usr/bin/env bash
set -Eeuo pipefail

GATEWAY_URL="${HERMES_GATEWAY_URL:-http://127.0.0.1:8642}"
if [[ "$GATEWAY_URL" == */health ]]; then
  GATEWAY_HEALTH_URL="$GATEWAY_URL"
else
  GATEWAY_HEALTH_URL="${GATEWAY_URL%/}/health"
fi

curl -fsS --max-time 5 "$GATEWAY_HEALTH_URL" >/dev/null
