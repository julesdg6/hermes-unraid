#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="${1:-hermes-suite:smoke}"
CONTAINER_NAME="hermes-suite-smoke-$$"
HERMES_HOME_DIR="$(mktemp -d)"
WORKSPACE_DIR="$(mktemp -d)"
HOST_GATEWAY_PORT="18642"
HOST_DASHBOARD_PORT="19119"
HOST_WEBUI_PORT="18787"
BUILT_IMAGE=0

cleanup() {
  local exit_code="${1:-$?}"
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    if (( exit_code != 0 )); then
      echo '--- container logs ---'
      docker logs "$CONTAINER_NAME" || true
      echo '--- health ---'
      docker inspect --format '{{json .State.Health}}' "$CONTAINER_NAME" || true
    fi
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  docker run --rm -v "${HERMES_HOME_DIR}:/target" busybox sh -c "chown -R $(id -u):$(id -g) /target" >/dev/null 2>&1 || true
  docker run --rm -v "${WORKSPACE_DIR}:/target" busybox sh -c "chown -R $(id -u):$(id -g) /target" >/dev/null 2>&1 || true
  rm -rf "$HERMES_HOME_DIR" "$WORKSPACE_DIR"
  if (( BUILT_IMAGE == 1 )); then
    docker image rm -f "$IMAGE_TAG" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap 'cleanup $?' EXIT

wait_for_url() {
  local name="$1"
  local url="$2"
  local timeout="${3:-180}"
  local started
  started="$(date +%s)"
  until curl -fsS --max-time 5 "$url" >/dev/null 2>&1; do
    if (( $(date +%s) - started >= timeout )); then
      echo "$name did not become ready at $url within ${timeout}s" >&2
      return 1
    fi
    sleep 2
  done
}

if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  docker build -t "$IMAGE_TAG" "$ROOT_DIR"
  BUILT_IMAGE=1
fi

docker run -d --name "$CONTAINER_NAME" \
  -p "${HOST_GATEWAY_PORT}:8642" \
  -p "${HOST_DASHBOARD_PORT}:9119" \
  -p "${HOST_WEBUI_PORT}:8787" \
  -e HERMES_UID=99 \
  -e HERMES_GID=100 \
  -e WANTED_UID=99 \
  -e WANTED_GID=100 \
  -v "${HERMES_HOME_DIR}:/home/hermes/.hermes" \
  -v "${WORKSPACE_DIR}:/home/hermeswebui/workspace" \
  "$IMAGE_TAG" >/dev/null

wait_for_url gateway "http://127.0.0.1:${HOST_GATEWAY_PORT}/health"
wait_for_url dashboard "http://127.0.0.1:${HOST_DASHBOARD_PORT}/"
wait_for_url webui "http://127.0.0.1:${HOST_WEBUI_PORT}/health"

docker exec "$CONTAINER_NAME" bash -lc "python3 - <<'PY'
import socket
for port in (8642, 9119, 8787):
    with socket.create_connection(('127.0.0.1', port), timeout=5):
        pass
print('ports listening')
PY"

docker exec "$CONTAINER_NAME" bash -lc '[[ "$VIRTUAL_ENV" == "/opt/hermes/.venv" ]]'
docker exec "$CONTAINER_NAME" bash -lc 'echo "$PATH" | grep -q "/opt/hermes/.venv/bin"'
docker exec "$CONTAINER_NAME" bash -lc 'command -v hermes >/dev/null'
docker exec "$CONTAINER_NAME" bash -lc 'hermes model --help >/dev/null'
docker exec "$CONTAINER_NAME" bash -lc 'hermes doctor >/dev/null'
docker exec "$CONTAINER_NAME" bash -lc 'cd /opt/hermes && ./hermes doctor >/dev/null'

echo "Smoke test passed for ${IMAGE_TAG}"
