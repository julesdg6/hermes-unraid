#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/hermes"
WEBUI_DIR="/opt/hermes-webui"
HERMES_HOME="${HERMES_HOME:-/home/hermes/.hermes}"
HERMES_UID="${HERMES_UID:-${WANTED_UID:-99}}"
HERMES_GID="${HERMES_GID:-${WANTED_GID:-100}}"
WANTED_UID="${WANTED_UID:-$HERMES_UID}"
WANTED_GID="${WANTED_GID:-$HERMES_GID}"
DASHBOARD_HOST="${DASHBOARD_HOST:-0.0.0.0}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
WEBUI_HOST="${WEBUI_HOST:-${HERMES_WEBUI_HOST:-0.0.0.0}}"
WEBUI_PORT="${WEBUI_PORT:-${HERMES_WEBUI_PORT:-8787}}"
HERMES_WORKSPACE="${HERMES_WORKSPACE:-/home/hermeswebui/workspace}"
HERMES_WEBUI_DEFAULT_WORKSPACE="${HERMES_WEBUI_DEFAULT_WORKSPACE:-$HERMES_WORKSPACE}"
HERMES_WEBUI_STATE_DIR="${HERMES_WEBUI_STATE_DIR:-/home/hermeswebui/.hermes/webui}"
HERMES_GATEWAY_URL="${HERMES_GATEWAY_URL:-http://127.0.0.1:8642}"

if [[ "$HERMES_GATEWAY_URL" == */health ]]; then
  GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-$HERMES_GATEWAY_URL}"
else
  GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-${HERMES_GATEWAY_URL%/}/health}"
fi

export HERMES_HOME HERMES_UID HERMES_GID WANTED_UID WANTED_GID
export HERMES_WORKSPACE HERMES_WEBUI_DEFAULT_WORKSPACE HERMES_WEBUI_STATE_DIR
export HERMES_WEBUI_AGENT_DIR="${HERMES_WEBUI_AGENT_DIR:-$INSTALL_DIR}"
export HERMES_WEBUI_HOST="$WEBUI_HOST" HERMES_WEBUI_PORT="$WEBUI_PORT"
export WEBUI_HOST WEBUI_PORT DASHBOARD_HOST DASHBOARD_PORT
export GATEWAY_HEALTH_URL
export PATH="$INSTALL_DIR/.venv/bin:$PATH"
export PYTHONPATH="$INSTALL_DIR:$WEBUI_DIR${PYTHONPATH:+:$PYTHONPATH}"
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-true}"
export API_SERVER_HOST="${API_SERVER_HOST:-0.0.0.0}"
export API_SERVER_PORT="${API_SERVER_PORT:-8642}"

pids=()
shutdown_requested=0

log() {
  echo "[hermes-suite] $*"
}

prepare_user() {
  local user="$1"
  local uid="$2"
  local gid="$3"

  if [[ -n "$gid" ]] && [[ "$gid" != "$(id -g "$user")" ]]; then
    log "Updating $user GID to $gid"
    groupmod -o -g "$gid" "$user" 2>/dev/null || true
  fi

  if [[ -n "$uid" ]] && [[ "$uid" != "$(id -u "$user")" ]]; then
    log "Updating $user UID to $uid"
    usermod -o -u "$uid" "$user"
  fi
}

bootstrap_home() {
  gosu hermes bash -lc '
    set -Eeuo pipefail
    source /opt/hermes/.venv/bin/activate
    mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home}
    if [[ ! -f "$HERMES_HOME/.env" ]]; then cp /opt/hermes/.env.example "$HERMES_HOME/.env"; fi
    if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then cp /opt/hermes/cli-config.yaml.example "$HERMES_HOME/config.yaml"; fi
    if [[ ! -f "$HERMES_HOME/SOUL.md" ]]; then cp /opt/hermes/docker/SOUL.md "$HERMES_HOME/SOUL.md"; fi
    if [[ ! -f "$HERMES_HOME/auth.json" && -n "${HERMES_AUTH_JSON_BOOTSTRAP:-}" ]]; then
      printf "%s" "$HERMES_AUTH_JSON_BOOTSTRAP" > "$HERMES_HOME/auth.json"
      chmod 600 "$HERMES_HOME/auth.json"
    fi
    if [[ -d /opt/hermes/skills ]]; then python3 /opt/hermes/tools/skills_sync.py; fi
  '
}

upsert_dotenv() {
  local key="$1"
  local value="$2"
  local file="$HERMES_HOME/.env"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "$file" ]]; then
    grep -v "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
  chown hermes:hermes "$file" 2>/dev/null || true
  chmod 600 "$file" 2>/dev/null || true
}

ensure_api_server_key() {
  local key_file="$HERMES_HOME/api-server.key"

  if [[ -n "${API_SERVER_KEY:-}" ]]; then
    :
  elif [[ -f "$key_file" ]]; then
    API_SERVER_KEY="$(<"$key_file")"
  else
    API_SERVER_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
    umask 077
    printf '%s' "$API_SERVER_KEY" > "$key_file"
  fi

  chown hermes:hermes "$key_file" 2>/dev/null || true
  chmod 600 "$key_file" 2>/dev/null || true
  export API_SERVER_KEY
  upsert_dotenv API_SERVER_ENABLED "$API_SERVER_ENABLED"
  upsert_dotenv API_SERVER_HOST "$API_SERVER_HOST"
  upsert_dotenv API_SERVER_PORT "$API_SERVER_PORT"
  upsert_dotenv API_SERVER_KEY "$API_SERVER_KEY"
}

prepare_install_dir() {
  # When the legacy hermes_shared_volume (or any external volume/bind-mount) is mapped
  # to /opt/hermes, the image's sentinel file is absent from the mounted path.
  # In that case, rsync the current image bundle into the mount so the container runs
  # the up-to-date Hermes install rather than whatever was in the old volume.
  #
  # The sentinel file (.hermes-suite-bundled) is included in the rsync, so this seeding
  # runs exactly once per external volume: subsequent container starts find the sentinel
  # and skip the rsync. After migration is complete, remove the /opt/hermes path mapping
  # from the template so the image-internal install is used directly.
  if [[ ! -f "${INSTALL_DIR}/.hermes-suite-bundled" ]]; then
    if [[ -d /opt/hermes.image-bundle ]]; then
      log "Detected externally-mounted ${INSTALL_DIR}; seeding from image bundle for migration compatibility"
      rsync -a /opt/hermes.image-bundle/ "${INSTALL_DIR}/"
    else
      log "Warning: ${INSTALL_DIR} appears to be externally mounted but no image bundle found; continuing as-is"
    fi
  fi
}

prepare_runtime_layout() {
  mkdir -p "$HERMES_HOME" "$HERMES_WORKSPACE" /home/hermeswebui
  mkdir -p "$(dirname "$HERMES_WEBUI_STATE_DIR")"

  if [[ -e /home/hermeswebui/.hermes && ! -L /home/hermeswebui/.hermes ]]; then
    rm -rf /home/hermeswebui/.hermes
  fi
  ln -sfn "$HERMES_HOME" /home/hermeswebui/.hermes

  chown -R hermes:hermes /home/hermes /home/hermeswebui "$HERMES_HOME" "$HERMES_WORKSPACE"
  chmod 755 /home/hermes /home/hermeswebui
  if [[ -f "$HERMES_HOME/config.yaml" ]]; then
    chown hermes:hermes "$HERMES_HOME/config.yaml" 2>/dev/null || true
    chmod 640 "$HERMES_HOME/config.yaml" 2>/dev/null || true
  fi

  if [[ "$WANTED_UID" != "$HERMES_UID" || "$WANTED_GID" != "$HERMES_GID" ]]; then
    log "WANTED_UID/GID differs from HERMES_UID/GID; Hermes Suite runs all services as the Hermes user, so keep them aligned for shared-path compatibility."
  fi
}

start_service() {
  local name="$1"
  shift
  stdbuf -oL -eL "$@" 2>&1 | sed -u "s/^/[$name] /" &
  pids+=("$!")
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local timeout="${3:-120}"
  local started
  started="$(date +%s)"

  until curl -fsS --max-time 5 "$url" >/dev/null 2>&1; do
    if (( $(date +%s) - started >= timeout )); then
      log "$name did not become ready at $url within ${timeout}s"
      return 1
    fi
    for pid in "${pids[@]}"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        log "$name readiness failed because a service exited early"
        return 1
      fi
    done
    sleep 2
  done
  log "$name is ready at $url"
}

stop_services() {
  local signal="${1:-TERM}"
  for pid in "${pids[@]:-}"; do
    kill -s "$signal" "$pid" 2>/dev/null || true
  done
}

cleanup() {
  local exit_code="${1:-$?}"
  if (( shutdown_requested == 0 )); then
    shutdown_requested=1
    log "Stopping Hermes Suite services"
    stop_services TERM
    sleep 2
    stop_services KILL
    wait || true
  fi
  exit "$exit_code"
}

trap 'cleanup 0' INT TERM
trap 'cleanup $?' EXIT

if [[ "$(id -u)" != "0" ]]; then
  log "Hermes Suite entrypoint expects to start as root so it can align mounted path ownership."
  exit 1
fi

prepare_user hermes "$HERMES_UID" "$HERMES_GID"
prepare_install_dir
prepare_runtime_layout
bootstrap_home
ensure_api_server_key

log "Gateway API auth configured with a ${#API_SERVER_KEY}-character key"
log "Hermes WebUI agent source is ${HERMES_WEBUI_AGENT_DIR}"
log "Starting Hermes gateway, dashboard, and WebUI"
start_service gateway gosu hermes bash -lc 'source /opt/hermes/.venv/bin/activate && exec hermes gateway run'

dashboard_command=(gosu hermes bash -lc "source /opt/hermes/.venv/bin/activate && exec hermes dashboard --host '$DASHBOARD_HOST' --port '$DASHBOARD_PORT' --no-open")
if [[ "$DASHBOARD_HOST" != "127.0.0.1" && "$DASHBOARD_HOST" != "localhost" ]]; then
  dashboard_command=(gosu hermes bash -lc "source /opt/hermes/.venv/bin/activate && exec hermes dashboard --host '$DASHBOARD_HOST' --port '$DASHBOARD_PORT' --no-open --insecure")
fi
start_service dashboard "${dashboard_command[@]}"
start_service webui gosu hermes bash -lc "cd '$WEBUI_DIR' && export HOME=/home/hermeswebui HERMES_WEBUI_AGENT_DIR='$INSTALL_DIR' && source /opt/hermes/.venv/bin/activate && exec python server.py"

wait_for_url gateway "$GATEWAY_HEALTH_URL"
wait_for_url dashboard "http://127.0.0.1:${DASHBOARD_PORT}/"
wait_for_url webui "http://127.0.0.1:${WEBUI_PORT}/health"

log "Hermes Suite started successfully"
wait -n "${pids[@]}"
status=$?
log "A Hermes Suite service exited unexpectedly with status $status"
cleanup "$status"
