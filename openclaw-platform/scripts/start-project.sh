#!/usr/bin/env bash
set -euo pipefail

PLATFORM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS_ROOT="$PLATFORM_ROOT/projects"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing dependency: $1"
  fi
}

is_truthy_value() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

is_debug_enabled() {
  is_truthy_value "${OPENCLAW_PLATFORM_DEBUG:-}"
}

debug_log() {
  if is_debug_enabled; then
    echo "[debug] $*" >&2
  fi
}

debug_log_cmd() {
  if ! is_debug_enabled; then
    return 0
  fi
  local rendered=""
  local arg
  for arg in "$@"; do
    printf -v rendered '%s %q' "$rendered" "$arg"
  done
  echo "[debug]${rendered}" >&2
}

validate_project_name() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    fail "Project name is required."
  fi
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    fail "Project name must match ^[a-z0-9][a-z0-9-]*$."
  fi
}

project_dir() {
  printf '%s' "$PROJECTS_ROOT/$1"
}

project_env_file() {
  printf '%s/.env' "$(project_dir "$1")"
}

project_compose_file() {
  printf '%s/docker-compose.yml' "$(project_dir "$1")"
}

project_sandbox_compose_file() {
  printf '%s/docker-compose.sandbox.yml' "$(project_dir "$1")"
}

compose_project_name() {
  printf 'ocp-%s' "$1"
}

read_env_value() {
  local env_file="$1"
  local key="$2"
  if [[ ! -f "$env_file" ]]; then
    return 1
  fi

  local line=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == "$key="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"$env_file"

  return 1
}

project_required_env_value() {
  local key="$1"
  local value=""
  value="$(read_env_value "$PROJECT_ENV_FILE" "$key" || true)"
  if [[ -z "$value" ]]; then
    fail "Missing $key in $PROJECT_ENV_FILE"
  fi
  printf '%s' "$value"
}

project_config_dir() {
  project_required_env_value OPENCLAW_CONFIG_DIR
}

project_workspace_dir() {
  project_required_env_value OPENCLAW_WORKSPACE_DIR
}

ensure_project_data_dirs() {
  local config_dir
  local workspace_dir
  config_dir="$(project_config_dir)"
  workspace_dir="$(project_workspace_dir)"

  mkdir -p "$config_dir" "$workspace_dir"
  mkdir -p "$config_dir/identity" "$config_dir/agents/main/agent" "$config_dir/agents/main/sessions"
}

run_project_compose() {
  local compose_scope="${1:-current}"
  shift

  local -a cmd=(
    docker compose
    -p "$COMPOSE_PROJECT_NAME"
    --env-file "$PROJECT_ENV_FILE"
    -f "$PROJECT_COMPOSE_FILE"
  )

  if [[ "$compose_scope" == "current" ]] && [[ -n "${SANDBOX_COMPOSE_FILE:-}" ]] && [[ -f "$SANDBOX_COMPOSE_FILE" ]]; then
    cmd+=( -f "$SANDBOX_COMPOSE_FILE" )
  fi

  cmd+=("$@")
  debug_log_cmd "${cmd[@]}"
  "${cmd[@]}"
}

run_project_prestart_gateway() {
  run_project_compose current run --rm --no-deps "$@"
}

run_project_prestart_cli() {
  # During setup/start, avoid the shared-network openclaw-cli service because
  # it depends on an already-existing gateway network namespace.
  run_project_prestart_gateway --entrypoint node openclaw-gateway dist/index.js "$@"
}

run_project_prestart_cli_checked() {
  local output
  if ! output="$(run_project_prestart_cli "$@" 2>&1)"; then
    fail "Prestart command failed for project '$PROJECT_NAME'.\nCommand: $*\n\n$output"
  fi
  if is_debug_enabled && [[ -n "$output" ]]; then
    echo "[debug] prestart output begin" >&2
    printf '%s\n' "$output" >&2
    echo "[debug] prestart output end" >&2
  fi
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
}

run_runtime_cli() {
  local compose_scope="${1:-current}"
  local deps_mode="${2:-with-deps}"
  shift 2

  local -a run_args=(run --rm)
  case "$deps_mode" in
    with-deps) ;;
    no-deps) run_args+=(--no-deps) ;;
    *) fail "Unknown runtime CLI deps mode: $deps_mode" ;;
  esac

  run_project_compose "$compose_scope" "${run_args[@]}" openclaw-cli "$@"
}

project_is_initialized() {
  local config_file
  config_file="$(project_config_dir)/openclaw.json"
  if [[ ! -f "$config_file" ]]; then
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$config_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    raise SystemExit(1)

gateway = cfg.get("gateway")
if not isinstance(gateway, dict):
    raise SystemExit(1)

mode = gateway.get("mode")
if isinstance(mode, str) and mode.strip():
    raise SystemExit(0)

raise SystemExit(1)
PY
    return $?
  fi

  if command -v node >/dev/null 2>&1; then
    node - "$config_file" <<'NODE'
const fs = require("node:fs");
const configPath = process.argv[2];
try {
  const cfg = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const mode = cfg?.gateway?.mode;
  process.exit(typeof mode === "string" && mode.trim().length > 0 ? 0 : 1);
} catch {
  process.exit(1);
}
NODE
    return $?
  fi

  grep -q '"gateway"' "$config_file" && grep -q '"mode"' "$config_file"
}

project_onboarding_marker_file() {
  printf '%s/.onboarded' "$(project_config_dir)"
}

run_project_onboarding_once() {
  local marker_file
  marker_file="$(project_onboarding_marker_file)"

  if [[ -f "$marker_file" ]]; then
    echo "Project '$PROJECT_NAME' is already onboarded; skipping onboarding."
    return 0
  fi

  if project_is_initialized; then
    echo "Project '$PROJECT_NAME' is already initialized; recording onboarding marker."
    : >"$marker_file"
    return 0
  fi

  echo "Project '$PROJECT_NAME' is not initialized; running first-time onboarding..."
  echo ""
  echo "==> Onboarding (interactive)"
  echo "Docker setup pins Gateway mode to local."
  echo "Gateway runtime bind comes from OPENCLAW_GATEWAY_BIND (default: lan)."
  echo "Current runtime bind: $OPENCLAW_GATEWAY_BIND"
  echo "Gateway token: ${OPENCLAW_GATEWAY_TOKEN:-<empty>}"
  echo "Tailscale exposure: Off (use host-level tailnet/Tailscale setup separately)."
  echo "Install Gateway daemon: No (managed by Docker Compose)"
  echo ""
  if ! run_project_prestart_cli onboard --mode local --no-install-daemon; then
    fail "Onboarding failed for project '$PROJECT_NAME'."
  fi
  : >"$marker_file"
}

sync_project_gateway_config() {
  local allowed_origin_json=""
  local current_allowed_origins=""
  local batch_json=""

  if [[ "$OPENCLAW_GATEWAY_BIND" != "loopback" ]]; then
    allowed_origin_json="$(printf '["http://localhost:%s","http://127.0.0.1:%s"]' "$OPENCLAW_GATEWAY_PORT" "$OPENCLAW_GATEWAY_PORT")"
    current_allowed_origins="$(run_project_prestart_cli config get gateway.controlUi.allowedOrigins 2>/dev/null || true)"
    current_allowed_origins="${current_allowed_origins//$'\r'/}"
  fi

  batch_json="$(printf '[{"path":"gateway.mode","value":"local"},{"path":"gateway.bind","value":"%s"}' "$OPENCLAW_GATEWAY_BIND")"
  if [[ -n "$allowed_origin_json" ]]; then
    if [[ -n "$current_allowed_origins" && "$current_allowed_origins" != "null" && "$current_allowed_origins" != "[]" ]]; then
      echo "Control UI allowlist already configured; leaving gateway.controlUi.allowedOrigins unchanged."
    else
      batch_json+=",{\"path\":\"gateway.controlUi.allowedOrigins\",\"value\":$allowed_origin_json}"
    fi
  fi
  batch_json+="]"

  run_project_prestart_cli_checked config set --batch-json "$batch_json" >/dev/null
  echo "Pinned gateway.mode=local and gateway.bind=$OPENCLAW_GATEWAY_BIND for project '$PROJECT_NAME'."
  if [[ -n "$allowed_origin_json" ]]; then
    if [[ -z "$current_allowed_origins" || "$current_allowed_origins" == "null" || "$current_allowed_origins" == "[]" ]]; then
      echo "Set gateway.controlUi.allowedOrigins to $allowed_origin_json for non-loopback bind."
    fi
  fi
}

usage() {
  cat <<'EOF'
Usage: start-project.sh <project-name> [--debug]

Starts openclaw-gateway for the specified project.
This script inlines the setup flow for easier debugging.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

PROJECT_NAME="${1:-}"
validate_project_name "$PROJECT_NAME"
shift || true

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --debug)
      export OPENCLAW_PLATFORM_DEBUG=1
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
  shift
done

require_cmd docker
if ! docker compose version >/dev/null 2>&1; then
  fail "Docker Compose not available (try: docker compose version)"
fi

PROJECT_DIR="$(project_dir "$PROJECT_NAME")"
PROJECT_ENV_FILE="$(project_env_file "$PROJECT_NAME")"
PROJECT_COMPOSE_FILE="$(project_compose_file "$PROJECT_NAME")"
COMPOSE_PROJECT_NAME="$(compose_project_name "$PROJECT_NAME")"
SANDBOX_COMPOSE_FILE=""

[[ -d "$PROJECT_DIR" ]] || fail "Project not found: $PROJECT_NAME"
[[ -f "$PROJECT_ENV_FILE" ]] || fail "Missing env file: $PROJECT_ENV_FILE"
[[ -f "$PROJECT_COMPOSE_FILE" ]] || fail "Missing compose file: $PROJECT_COMPOSE_FILE"

OPENCLAW_GATEWAY_PORT="$(read_env_value "$PROJECT_ENV_FILE" OPENCLAW_GATEWAY_PORT || true)"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_GATEWAY_BIND="$(read_env_value "$PROJECT_ENV_FILE" OPENCLAW_GATEWAY_BIND || true)"
OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
OPENCLAW_GATEWAY_TOKEN="$(read_env_value "$PROJECT_ENV_FILE" OPENCLAW_GATEWAY_TOKEN || true)"

RAW_SANDBOX_SETTING="$(read_env_value "$PROJECT_ENV_FILE" OPENCLAW_SANDBOX || true)"
SANDBOX_ENABLED=""
if is_truthy_value "$RAW_SANDBOX_SETTING"; then
  SANDBOX_ENABLED="1"
fi

DOCKER_SOCKET_PATH="$(read_env_value "$PROJECT_ENV_FILE" OPENCLAW_DOCKER_SOCKET || true)"
if [[ -z "$DOCKER_SOCKET_PATH" && "${DOCKER_HOST:-}" == unix://* ]]; then
  DOCKER_SOCKET_PATH="${DOCKER_HOST#unix://}"
fi
if [[ -z "$DOCKER_SOCKET_PATH" ]]; then
  DOCKER_SOCKET_PATH="/var/run/docker.sock"
fi

DOCKER_GID=""
if [[ -n "$SANDBOX_ENABLED" && -S "$DOCKER_SOCKET_PATH" ]]; then
  DOCKER_GID="$(stat -c '%g' "$DOCKER_SOCKET_PATH" 2>/dev/null || stat -f '%g' "$DOCKER_SOCKET_PATH" 2>/dev/null || echo "")"
fi

debug_log "Starting project '$PROJECT_NAME' with setup-grade flow."

ensure_project_data_dirs

echo ""
echo "==> Fixing data-directory permissions"
run_project_prestart_gateway --user root --entrypoint sh openclaw-gateway -c \
  'find /home/node/.openclaw -xdev -exec chown node:node {} +; \
   [ -d /home/node/.openclaw/workspace/.openclaw ] && chown -R node:node /home/node/.openclaw/workspace/.openclaw || true'

echo ""
run_project_onboarding_once

echo ""
echo "==> Docker gateway defaults"
sync_project_gateway_config

echo ""
echo "==> Starting gateway"
run_project_compose current up -d openclaw-gateway

if [[ -n "$SANDBOX_ENABLED" ]]; then
  echo ""
  echo "==> Sandbox setup"

  if ! run_project_compose current run --rm --entrypoint docker openclaw-gateway --version >/dev/null 2>&1; then
    echo "WARNING: Docker CLI not found inside the container image." >&2
    echo "  Sandbox requires Docker CLI. Skipping sandbox setup." >&2
    SANDBOX_ENABLED=""
  fi
fi

if [[ -n "$SANDBOX_ENABLED" ]]; then
  if [[ -S "$DOCKER_SOCKET_PATH" ]]; then
    SANDBOX_COMPOSE_FILE="$(project_sandbox_compose_file "$PROJECT_NAME")"
    cat >"$SANDBOX_COMPOSE_FILE" <<YAML
services:
  openclaw-gateway:
    volumes:
      - ${DOCKER_SOCKET_PATH}:/var/run/docker.sock
YAML
    if [[ -n "$DOCKER_GID" ]]; then
      cat >>"$SANDBOX_COMPOSE_FILE" <<YAML
    group_add:
      - "${DOCKER_GID}"
YAML
    fi
    echo "==> Sandbox: added Docker socket mount"
  else
    echo "WARNING: OPENCLAW_SANDBOX enabled but Docker socket not found at $DOCKER_SOCKET_PATH." >&2
    echo "  Sandbox requires Docker socket access. Skipping sandbox setup." >&2
    SANDBOX_ENABLED=""
  fi
fi

if [[ -n "$SANDBOX_ENABLED" ]]; then
  sandbox_config_ok=true
  if ! run_runtime_cli current no-deps config set agents.defaults.sandbox.mode "non-main" >/dev/null; then
    echo "WARNING: Failed to set agents.defaults.sandbox.mode" >&2
    sandbox_config_ok=false
  fi
  if ! run_runtime_cli current no-deps config set agents.defaults.sandbox.scope "agent" >/dev/null; then
    echo "WARNING: Failed to set agents.defaults.sandbox.scope" >&2
    sandbox_config_ok=false
  fi
  if ! run_runtime_cli current no-deps config set agents.defaults.sandbox.workspaceAccess "none" >/dev/null; then
    echo "WARNING: Failed to set agents.defaults.sandbox.workspaceAccess" >&2
    sandbox_config_ok=false
  fi

  if [[ "$sandbox_config_ok" == true ]]; then
    echo "Sandbox enabled: mode=non-main, scope=agent, workspaceAccess=none"
    echo "Docs: https://docs.openclaw.ai/gateway/sandboxing"
    run_project_compose current up -d openclaw-gateway
  else
    echo "WARNING: Sandbox config was partially applied. Check errors above." >&2
    echo "  Rolling back sandbox mode to off and recreating gateway without sandbox overlay." >&2
    if ! run_runtime_cli base no-deps config set agents.defaults.sandbox.mode "off" >/dev/null; then
      echo "WARNING: Failed to roll back agents.defaults.sandbox.mode to off" >&2
    fi
    if [[ -n "$SANDBOX_COMPOSE_FILE" ]]; then
      rm -f "$SANDBOX_COMPOSE_FILE"
      SANDBOX_COMPOSE_FILE=""
    fi
    run_project_compose base up -d --force-recreate openclaw-gateway
  fi
else
  if ! run_runtime_cli current with-deps config set agents.defaults.sandbox.mode "off" >/dev/null; then
    echo "WARNING: Failed to reset agents.defaults.sandbox.mode to off" >&2
  fi
  if [[ -f "$(project_sandbox_compose_file "$PROJECT_NAME")" ]]; then
    rm -f "$(project_sandbox_compose_file "$PROJECT_NAME")"
  fi
fi

echo ""
echo "Started project: $PROJECT_NAME"
echo "Dashboard URL: http://localhost:${OPENCLAW_GATEWAY_PORT}"
echo "Token: ${OPENCLAW_GATEWAY_TOKEN:-<empty>}"

