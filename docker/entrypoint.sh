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
HERMES_RUNTIME_DIR="${HERMES_RUNTIME_DIR:-$HERMES_HOME/runtime}"
HERMES_USER_BIN_DIR="${HERMES_USER_BIN_DIR:-$HERMES_HOME/bin}"
HERMES_USER_SSH_DIR="${HERMES_USER_SSH_DIR:-$HERMES_HOME/ssh}"
HERMES_ROOT_SSH_DIR="${HERMES_ROOT_SSH_DIR:-$HERMES_HOME/root-ssh}"
HERMES_LEGACY_USER_SSH_DIR="${HERMES_HOME}/.ssh"

if [[ "$HERMES_GATEWAY_URL" == */health ]]; then
  GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-$HERMES_GATEWAY_URL}"
else
  GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-${HERMES_GATEWAY_URL%/}/health}"
fi

export HERMES_HOME HERMES_UID HERMES_GID WANTED_UID WANTED_GID
export HERMES_WORKSPACE HERMES_WEBUI_DEFAULT_WORKSPACE HERMES_WEBUI_STATE_DIR
export HERMES_RUNTIME_DIR HERMES_USER_BIN_DIR HERMES_USER_SSH_DIR HERMES_ROOT_SSH_DIR
export HERMES_WEBUI_AGENT_DIR="${HERMES_WEBUI_AGENT_DIR:-$INSTALL_DIR}"
export HERMES_WEBUI_HOST="$WEBUI_HOST" HERMES_WEBUI_PORT="$WEBUI_PORT"
export WEBUI_HOST WEBUI_PORT DASHBOARD_HOST DASHBOARD_PORT
export GATEWAY_HEALTH_URL
export VIRTUAL_ENV="${VIRTUAL_ENV:-$INSTALL_DIR/.venv}"
export PATH="$HERMES_USER_BIN_DIR:$VIRTUAL_ENV/bin:$INSTALL_DIR:$PATH"
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
    mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home,runtime,bin,ssh}
    if [[ ! -f "$HERMES_HOME/.env" ]]; then cp /opt/hermes/.env.example "$HERMES_HOME/.env"; fi
    if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then cp /opt/hermes/cli-config.yaml.example "$HERMES_HOME/config.yaml"; fi
    if [[ ! -f "$HERMES_HOME/SOUL.md" ]]; then cp /opt/hermes/docker/SOUL.md "$HERMES_HOME/SOUL.md"; fi
    if [[ ! -f "$HERMES_HOME/auth.json" && -n "${HERMES_AUTH_JSON_BOOTSTRAP:-}" ]]; then
      printf "%s" "$HERMES_AUTH_JSON_BOOTSTRAP" > "$HERMES_HOME/auth.json"
      chmod 600 "$HERMES_HOME/auth.json"
    fi
    if [[ -d /opt/hermes/skills ]]; then "$VIRTUAL_ENV/bin/python" /opt/hermes/tools/skills_sync.py; fi
  '
}

sync_profile_launchers() {
  local profile_dir="$HERMES_HOME/profiles"
  local launcher
  local launcher_path
  local persisted_path
  local source_path

  [[ -d "$profile_dir" ]] || return 0
  while IFS= read -r launcher; do
    [[ -n "$launcher" ]] || continue
    launcher_path="/usr/local/bin/$launcher"
    persisted_path="$HERMES_USER_BIN_DIR/$launcher"

    if [[ ! -f "$persisted_path" && ( -f "$launcher_path" || -L "$launcher_path" ) ]]; then
      source_path="$launcher_path"
      if [[ -L "$launcher_path" ]]; then
        source_path="$(readlink -f "$launcher_path" 2>/dev/null || true)"
      fi
      if [[ -n "$source_path" && "$source_path" != "$persisted_path" && -f "$source_path" ]]; then
        cp -a "$source_path" "$persisted_path"
      fi
    fi
    if [[ -f "$persisted_path" ]]; then
      chmod 755 "$persisted_path" || echo "[hermes-suite] Warning: could not set execute permissions on persisted launcher $persisted_path"
    fi
    ln -sfn "$persisted_path" "$launcher_path"
  done < <(find "$profile_dir" -mindepth 1 -maxdepth 1 -exec basename "{}" \; 2>/dev/null | sort -u)
}

upsert_env_file() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "$file" ]]; then
    grep -v "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
}

upsert_dotenv() {
  local key="$1"
  local value="$2"
  local file="$HERMES_HOME/.env"
  upsert_env_file "$file" "$key" "$value"
  chown hermes:hermes "$file" 2>/dev/null || true
  chmod 600 "$file" 2>/dev/null || true
}

migrate_profile_ssh_keys() {
  local profile_dir="$HERMES_HOME/profiles"
  local env_file
  local terminal_ssh_key
  local persisted_key

  [[ -d "$profile_dir" ]] || return 0
  while IFS= read -r env_file; do
    terminal_ssh_key="$(grep -E '^TERMINAL_SSH_KEY=' "$env_file" | tail -n 1 | cut -d= -f2- || true)"
    [[ -n "$terminal_ssh_key" ]] || continue
    if [[ "$terminal_ssh_key" == /root/.ssh/* || "$terminal_ssh_key" == /home/hermes/.ssh/* ]]; then
      persisted_key="$HERMES_USER_SSH_DIR/${terminal_ssh_key##*/}"
      if [[ -f "$terminal_ssh_key" && ! -f "$persisted_key" ]]; then
        cp -a "$terminal_ssh_key" "$persisted_key"
      fi
      upsert_env_file "$env_file" TERMINAL_SSH_KEY "$persisted_key"
      chown hermes:hermes "$env_file" 2>/dev/null || true
      chmod 600 "$env_file" 2>/dev/null || true
      log "Updated TERMINAL_SSH_KEY in ${env_file} to persisted path ${persisted_key}"
    fi
  done < <(find "$profile_dir" -mindepth 2 -maxdepth 2 -name .env -type f 2>/dev/null | sort)
}

warn_non_persistent_profile_paths() {
  local profile_dir="$HERMES_HOME/profiles"
  local env_file
  local root_matches
  local usr_local_matches
  local home_ssh_matches
  local home_ssh_persisted=0

  [[ -d "$profile_dir" ]] || return 0
  if [[ -L /home/hermes/.ssh ]] && [[ "$(readlink -f /home/hermes/.ssh 2>/dev/null || true)" == "$HERMES_USER_SSH_DIR" ]]; then
    home_ssh_persisted=1
  fi

  while IFS= read -r env_file; do
    root_matches="$(grep -E '=/root/' "$env_file" || true)"
    usr_local_matches="$(grep -E '=/usr/local/' "$env_file" || true)"
    home_ssh_matches="$(grep -E '=/home/hermes/\.ssh/' "$env_file" || true)"
    if [[ -n "$root_matches" || -n "$usr_local_matches" || ( $home_ssh_persisted -eq 0 && -n "$home_ssh_matches" ) ]]; then
      log "Warning: ${env_file} contains profile paths that may not persist across container recreation"
      [[ -n "$root_matches" ]] && log "Warning: ${env_file} references /root/ paths"
      [[ -n "$usr_local_matches" ]] && log "Warning: ${env_file} references /usr/local/ paths"
      [[ $home_ssh_persisted -eq 0 && -n "$home_ssh_matches" ]] && log "Warning: ${env_file} references /home/hermes/.ssh without persistent symlink protection"
    fi
  done < <(find "$profile_dir" -mindepth 2 -maxdepth 2 -name .env -type f 2>/dev/null | sort)
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

ensure_telegram_deps() {
  # Ensure python-telegram-bot is available whenever Telegram appears configured
  # via environment, .env, or config.yaml. If the import is already available, do
  # nothing. If Telegram isn't configured, skip runtime installation.
  local python="$VIRTUAL_ENV/bin/python"
  local dotenv_file="$HERMES_HOME/.env"
  local config_file="$HERMES_HOME/config.yaml"
  if "$python" -c "import telegram" 2>/dev/null; then
    return 0
  fi

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    if [[ -f "$dotenv_file" ]] && grep -Eq '^[[:space:]]*TELEGRAM_[A-Z0-9_]+=' "$dotenv_file"; then
      :
    elif [[ -f "$config_file" ]] && grep -Eiq '(^|[^[:alnum:]_])telegram([^[:alnum:]_]|$)' "$config_file"; then
      :
    else
      return 0
    fi
  fi

  log "Telegram configured but python-telegram-bot missing from /opt/hermes/.venv"
  if [[ -x "$VIRTUAL_ENV/bin/pip" ]]; then
    log "Installing python-telegram-bot into the virtual environment..."
    if gosu hermes "$VIRTUAL_ENV/bin/pip" install --quiet python-telegram-bot 2>&1 | sed -u 's/^/[telegram-install] /'; then
      log "python-telegram-bot installed successfully."
    else
      log "Warning: Failed to install python-telegram-bot. Telegram gateway adapter will be unavailable."
      log "  To install manually: docker exec <container> /opt/hermes/.venv/bin/pip install python-telegram-bot"
    fi
  else
    log "Warning: pip is not available in the virtual environment. Telegram gateway adapter will be unavailable."
    log "  To resolve, run: docker exec <container> /opt/hermes/.venv/bin/python -m ensurepip --upgrade"
    log "  Then:            docker exec <container> /opt/hermes/.venv/bin/pip install python-telegram-bot"
  fi
}

configure_gateway_defaults() {
  # Default to allowing all gateway users when no platform-specific allowlists
  # (e.g. TELEGRAM_ALLOWED_USERS) are configured, suppressing the
  # "No user allowlists configured" startup warning.
  # Override by setting GATEWAY_ALLOW_ALL_USERS=false and configuring
  # platform allowlists such as TELEGRAM_ALLOWED_USERS.
  export GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS:-true}"
  upsert_dotenv GATEWAY_ALLOW_ALL_USERS "$GATEWAY_ALLOW_ALL_USERS"

  # Remove stale SQLite WAL/journal files so the gateway does not encounter a
  # "database is locked" error on startup after an unclean container shutdown.
  local db="$HERMES_HOME/state.db"
  rm -f "${db}-wal" "${db}-shm" "${db}-journal" 2>/dev/null || true
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

setup_root_ssh() {
  mkdir -p "$HERMES_ROOT_SSH_DIR"

  # Migrate any existing /root/.ssh contents into the persistent directory
  if [[ -e /root/.ssh && ! -L /root/.ssh ]]; then
    if [[ -d /root/.ssh ]]; then
      cp -an /root/.ssh/. "$HERMES_ROOT_SSH_DIR"/
      rm -rf /root/.ssh
    fi
  fi

  # Replace /root/.ssh with a symlink to the persistent directory
  ln -sfn "$HERMES_ROOT_SSH_DIR" /root/.ssh

  # Create a default SSH config pointing at the persisted Hermes key if one
  # exists and no config has been written yet
  local key_file="$HERMES_USER_SSH_DIR/id_ed25519"
  local config_file="$HERMES_ROOT_SSH_DIR/config"
  if [[ -f "$key_file" && ! -f "$config_file" ]]; then
    cat > "$config_file" <<EOF
Host hermeslab 192.168.1.215
  HostName 192.168.1.215
  User hermes
  IdentityFile $key_file
  IdentitiesOnly yes
  PreferredAuthentications publickey
  PasswordAuthentication no
  StrictHostKeyChecking accept-new
EOF
    log "Created default root SSH config at ${config_file}"
  fi

  # Ensure root owns its SSH directory so the ssh client accepts the config
  chown root:root "$HERMES_ROOT_SSH_DIR" 2>/dev/null || true
  find "$HERMES_ROOT_SSH_DIR" -maxdepth 1 \( -type f -o -type l \) \
    -exec chown root:root {} \; 2>/dev/null || true
  chmod 700 "$HERMES_ROOT_SSH_DIR"
  if [[ -f "$config_file" ]]; then
    chmod 600 "$config_file"
  fi
}

prepare_runtime_layout() {
  mkdir -p "$HERMES_HOME" "$HERMES_WORKSPACE" /home/hermeswebui "$HERMES_RUNTIME_DIR" "$HERMES_USER_BIN_DIR" "$HERMES_USER_SSH_DIR"
  mkdir -p "$(dirname "$HERMES_WEBUI_STATE_DIR")"

  if [[ -e /home/hermeswebui/.hermes && ! -L /home/hermeswebui/.hermes ]]; then
    rm -rf /home/hermeswebui/.hermes
  fi
  if [[ "$HERMES_LEGACY_USER_SSH_DIR" != "$HERMES_USER_SSH_DIR" && -d "$HERMES_LEGACY_USER_SSH_DIR" ]]; then
    cp -an "$HERMES_LEGACY_USER_SSH_DIR"/. "$HERMES_USER_SSH_DIR"/
    rm -rf "$HERMES_LEGACY_USER_SSH_DIR"
    log "Migrated legacy SSH dir ${HERMES_LEGACY_USER_SSH_DIR} to ${HERMES_USER_SSH_DIR}"
  fi
  if [[ -e /root/.ssh && ! -L /root/.ssh ]]; then
    if [[ -d /root/.ssh ]]; then
      cp -an /root/.ssh/. "$HERMES_USER_SSH_DIR"/
    fi
  fi
  if [[ -e /home/hermes/.ssh && ! -L /home/hermes/.ssh ]]; then
    if [[ -d /home/hermes/.ssh ]]; then
      cp -an /home/hermes/.ssh/. "$HERMES_USER_SSH_DIR"/
    fi
    rm -rf /home/hermes/.ssh
  fi
  ln -sfn "$HERMES_HOME" /home/hermeswebui/.hermes
  ln -sfn "$HERMES_USER_SSH_DIR" /home/hermes/.ssh
  sync_profile_launchers
  migrate_profile_ssh_keys
  warn_non_persistent_profile_paths

  chown -R hermes:hermes /home/hermes /home/hermeswebui "$HERMES_HOME" "$HERMES_WORKSPACE" "$HERMES_RUNTIME_DIR" "$HERMES_USER_BIN_DIR" "$HERMES_USER_SSH_DIR"
  chmod 755 /home/hermes /home/hermeswebui
  chmod 700 "$HERMES_USER_SSH_DIR"
  if [[ -f "$HERMES_HOME/config.yaml" ]]; then
    if ! chown hermes:hermes "$HERMES_HOME/config.yaml" 2>/dev/null; then
      log "Warning: Could not set ownership on $HERMES_HOME/config.yaml — gateway may fall back to .env values"
    fi
    chmod 640 "$HERMES_HOME/config.yaml" 2>/dev/null || true
  fi

  # Set up persistent root SSH directory and symlink after the hermes chown
  # so that root ownership can be applied correctly
  setup_root_ssh

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
configure_gateway_defaults
ensure_telegram_deps

log "Gateway API auth configured with a ${#API_SERVER_KEY}-character key"
log "Hermes WebUI agent source is ${HERMES_WEBUI_AGENT_DIR}"
log "Starting Hermes gateway, dashboard, and WebUI"
start_service gateway gosu hermes "$VIRTUAL_ENV/bin/hermes" gateway run

dashboard_command=(gosu hermes "$VIRTUAL_ENV/bin/hermes" dashboard --host "$DASHBOARD_HOST" --port "$DASHBOARD_PORT" --no-open)
if [[ "$DASHBOARD_HOST" != "127.0.0.1" && "$DASHBOARD_HOST" != "localhost" ]]; then
  dashboard_command=(gosu hermes "$VIRTUAL_ENV/bin/hermes" dashboard --host "$DASHBOARD_HOST" --port "$DASHBOARD_PORT" --no-open --insecure)
fi

# Wait for gateway to finish initializing its SQLite database before launching
# dashboard, which also opens the shared state.db — concurrent opens cause a
# "database is locked" warning in the gateway log.
wait_for_url gateway "$GATEWAY_HEALTH_URL"
start_service dashboard "${dashboard_command[@]}"
start_service webui gosu hermes bash -lc "cd '$WEBUI_DIR' && export HOME=/home/hermeswebui HERMES_WEBUI_AGENT_DIR='$INSTALL_DIR' && exec /opt/hermes/.venv/bin/python server.py"

wait_for_url dashboard "http://127.0.0.1:${DASHBOARD_PORT}/"
wait_for_url webui "http://127.0.0.1:${WEBUI_PORT}/health"

log "Hermes Suite started successfully"
wait -n "${pids[@]}"
status=$?
log "A Hermes Suite service exited unexpectedly with status $status"
cleanup "$status"
