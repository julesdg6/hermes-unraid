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

mkdir -p "${HERMES_HOME_DIR}/profiles/ollama-primary"
mkdir -p "${HERMES_HOME_DIR}/.ssh"
ssh-keygen -t ed25519 -N '' -f "${HERMES_HOME_DIR}/.ssh/id_ed25519" >/dev/null
cat > "${HERMES_HOME_DIR}/profiles/ollama-primary/.env" <<'EOF'
TERMINAL_SSH_KEY=/home/hermes/.ssh/id_ed25519
EOF

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
docker exec "$CONTAINER_NAME" bash -lc 'echo "$PATH" | grep -q "/home/hermes/.hermes/bin"'
docker exec "$CONTAINER_NAME" bash -lc 'command -v hermes >/dev/null'
docker exec "$CONTAINER_NAME" bash -lc '/opt/hermes/.venv/bin/python -c "import telegram"'
docker exec "$CONTAINER_NAME" bash -lc 'hermes model --help >/dev/null'
docker exec "$CONTAINER_NAME" bash -lc 'hermes doctor >/dev/null'
docker exec "$CONTAINER_NAME" bash -lc 'cd /opt/hermes && ./hermes doctor >/dev/null'
# Verify that 'hermes gateway --help' works when invoked as root (auto-drop wrapper)
docker exec "$CONTAINER_NAME" bash -lc 'hermes gateway --help >/dev/null'
# Verify that the hermes-real binary exists (wrapper is in place)
docker exec "$CONTAINER_NAME" bash -lc 'test -f /opt/hermes/.venv/bin/hermes-real'
docker exec "$CONTAINER_NAME" bash -lc "cat > /usr/local/bin/ollama-primary <<'EOF'
#!/usr/bin/env bash
echo ollama-primary
EOF
chmod 755 /usr/local/bin/ollama-primary"

docker rm -f "$CONTAINER_NAME" >/dev/null

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

docker exec "$CONTAINER_NAME" bash -lc 'test -f /home/hermes/.hermes/ssh/id_ed25519'
docker exec "$CONTAINER_NAME" bash -lc 'test -f /home/hermes/.hermes/bin/ollama-primary'
docker exec "$CONTAINER_NAME" bash -lc 'test "$(readlink -f /home/hermes/.ssh)" = "/home/hermes/.hermes/ssh"'
docker exec "$CONTAINER_NAME" bash -lc 'test "$(readlink -f /usr/local/bin/ollama-primary)" = "/home/hermes/.hermes/bin/ollama-primary"'
docker exec "$CONTAINER_NAME" bash -lc 'grep -q "^TERMINAL_SSH_KEY=/home/hermes/.hermes/ssh/id_ed25519$" /home/hermes/.hermes/profiles/ollama-primary/.env'
docker exec "$CONTAINER_NAME" bash -lc 'ssh-keygen -y -f /home/hermes/.hermes/ssh/id_ed25519 >/dev/null'
docker exec "$CONTAINER_NAME" bash -lc 'echo "$PATH" | grep -q "/home/hermes/.hermes/bin"'
# Verify the persisted launcher is reachable via PATH (HERMES_USER_BIN_DIR)
docker exec "$CONTAINER_NAME" bash -lc 'ollama-primary'
# The legacy .ssh dir inside HERMES_HOME ($HERMES_HOME/.ssh) must be removed after migration
docker exec "$CONTAINER_NAME" bash -lc 'test ! -d /home/hermes/.hermes/.ssh'
# Verify root SSH persistence: /root/.ssh must be a symlink to the persistent root-ssh directory
docker exec "$CONTAINER_NAME" bash -lc 'test "$(readlink -f /root/.ssh)" = "/home/hermes/.hermes/root-ssh"'
# Verify root SSH config resolves the persisted Hermes key for 192.168.1.215
docker exec "$CONTAINER_NAME" bash -lc 'ssh -G 192.168.1.215 | grep -q "/home/hermes/.hermes/ssh/id_ed25519"'

echo "Smoke test passed for ${IMAGE_TAG}"
