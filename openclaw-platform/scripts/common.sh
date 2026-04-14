#!/usr/bin/env bash
set -euo pipefail

PLATFORM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS_ROOT="$PLATFORM_ROOT/projects"
TEMPLATE_FILE="$PLATFORM_ROOT/templates/docker-compose.project.yml"
DEFAULTS_FILE="$PLATFORM_ROOT/.env.defaults"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing dependency: $1"
  fi
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
  local name="$1"
  printf '%s' "$PROJECTS_ROOT/$name"
}

project_env_file() {
  local name="$1"
  printf '%s/.env' "$(project_dir "$name")"
}

project_compose_file() {
  local name="$1"
  printf '%s/docker-compose.yml' "$(project_dir "$name")"
}

compose_project_name() {
  local name="$1"
  printf 'ocp-%s' "$name"
}

load_defaults_file() {
  if [[ -f "$DEFAULTS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$DEFAULTS_FILE"
  fi
}

read_env_value() {
  local env_file="$1"
  local key="$2"
  if [[ ! -f "$env_file" ]]; then
    return 1
  fi
  local line
  line="$(grep -E "^${key}=" "$env_file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi
  printf '%s' "${line#*=}"
}

is_port_listening() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if command -v netstat >/dev/null 2>&1; then
    if netstat -an 2>/dev/null | grep -E "[\.:]${port}[[:space:]].*LISTEN" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

is_port_reserved_in_projects() {
  local port="$1"
  local env_file

  for env_file in "$PROJECTS_ROOT"/*/.env; do
    [[ -f "$env_file" ]] || continue
    local gateway_port
    local bridge_port
    gateway_port="$(read_env_value "$env_file" OPENCLAW_GATEWAY_PORT || true)"
    bridge_port="$(read_env_value "$env_file" OPENCLAW_BRIDGE_PORT || true)"
    if [[ "$gateway_port" == "$port" || "$bridge_port" == "$port" ]]; then
      return 0
    fi
  done

  return 1
}

is_port_available() {
  local port="$1"
  if is_port_reserved_in_projects "$port"; then
    return 1
  fi
  if is_port_listening "$port"; then
    return 1
  fi
  return 0
}

find_available_port_pair() {
  local start_gateway="${1:-18789}"
  local gateway_port="$start_gateway"
  local bridge_port

  if (( gateway_port % 2 == 0 )); then
    gateway_port=$((gateway_port + 1))
  fi

  while :; do
    bridge_port=$((gateway_port + 1))
    if is_port_available "$gateway_port" && is_port_available "$bridge_port"; then
      printf '%s %s\n' "$gateway_port" "$bridge_port"
      return 0
    fi
    gateway_port=$((gateway_port + 2))
  done
}

generate_gateway_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
    return 0
  fi

  if command -v node >/dev/null 2>&1; then
    node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
    return 0
  fi

  fail "Unable to generate token (need openssl, python3, or node)."
}

run_project_compose() {
  local project_name="$1"
  shift

  local project_path
  local env_file
  local compose_file
  project_path="$(project_dir "$project_name")"
  env_file="$(project_env_file "$project_name")"
  compose_file="$(project_compose_file "$project_name")"

  [[ -d "$project_path" ]] || fail "Project not found: $project_name"
  [[ -f "$env_file" ]] || fail "Missing env file: $env_file"
  [[ -f "$compose_file" ]] || fail "Missing compose file: $compose_file"

  docker compose \
    -p "$(compose_project_name "$project_name")" \
    --env-file "$env_file" \
    -f "$compose_file" \
    "$@"
}

project_required_env_value() {
  local project_name="$1"
  local key="$2"
  local env_file
  env_file="$(project_env_file "$project_name")"
  local value
  value="$(read_env_value "$env_file" "$key" || true)"
  if [[ -z "$value" ]]; then
    fail "Missing $key in $(project_env_file "$project_name")"
  fi
  printf '%s' "$value"
}

project_config_dir() {
  local project_name="$1"
  project_required_env_value "$project_name" OPENCLAW_CONFIG_DIR
}

project_workspace_dir() {
  local project_name="$1"
  project_required_env_value "$project_name" OPENCLAW_WORKSPACE_DIR
}

ensure_project_data_dirs() {
  local project_name="$1"
  local config_dir
  local workspace_dir
  config_dir="$(project_config_dir "$project_name")"
  workspace_dir="$(project_workspace_dir "$project_name")"

  mkdir -p "$config_dir" "$workspace_dir"
  mkdir -p "$config_dir/identity" "$config_dir/agents/main/agent" "$config_dir/agents/main/sessions"
}

run_project_prestart_gateway() {
  local project_name="$1"
  shift
  run_project_compose "$project_name" run --rm --no-deps "$@"
}

fix_project_data_permissions() {
  local project_name="$1"
  run_project_prestart_gateway "$project_name" --user root --entrypoint sh openclaw-gateway -c \
    'find /home/node/.openclaw -xdev -exec chown node:node {} +; \
     [ -d /home/node/.openclaw/workspace/.openclaw ] && chown -R node:node /home/node/.openclaw/workspace/.openclaw || true'
}

run_project_prestart_cli() {
  local project_name="$1"
  shift
  run_project_prestart_gateway "$project_name" --entrypoint node openclaw-gateway dist/index.js "$@"
}

run_project_prestart_cli_checked() {
  local project_name="$1"
  shift
  local output
  if ! output="$(run_project_prestart_cli "$project_name" "$@" 2>&1)"; then
    fail "Prestart command failed for project '$project_name'.\nCommand: $*\n\n$output"
  fi
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
}

project_is_initialized() {
  local project_name="$1"
  local config_file
  config_file="$(project_config_dir "$project_name")/openclaw.json"
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
  local project_name="$1"
  printf '%s/.onboarded' "$(project_config_dir "$project_name")"
}

run_project_onboarding_once() {
  local project_name="$1"
  local marker_file
  marker_file="$(project_onboarding_marker_file "$project_name")"

  if [[ -f "$marker_file" ]]; then
    echo "Project '$project_name' is already onboarded; skipping onboarding."
    return 0
  fi

  if project_is_initialized "$project_name"; then
    echo "Project '$project_name' is already initialized; recording onboarding marker."
    : >"$marker_file"
    return 0
  fi

  echo "Project '$project_name' is not initialized; running first-time onboarding..."
  run_project_prestart_cli_checked "$project_name" onboard --mode local --no-install-daemon
  : >"$marker_file"
}

sync_project_gateway_config() {
  local project_name="$1"
  local gateway_bind
  local gateway_port
  local allowed_origin_json=""
  local current_allowed_origins=""
  local batch_json

  gateway_bind="$(read_env_value "$(project_env_file "$project_name")" OPENCLAW_GATEWAY_BIND || true)"
  gateway_bind="${gateway_bind:-lan}"
  gateway_port="$(read_env_value "$(project_env_file "$project_name")" OPENCLAW_GATEWAY_PORT || true)"
  gateway_port="${gateway_port:-18789}"

  if [[ "$gateway_bind" != "loopback" ]]; then
    allowed_origin_json="$(printf '["http://localhost:%s","http://127.0.0.1:%s"]' "$gateway_port" "$gateway_port")"
    current_allowed_origins="$(run_project_prestart_cli "$project_name" config get gateway.controlUi.allowedOrigins 2>/dev/null || true)"
    current_allowed_origins="${current_allowed_origins//$'\r'/}"
  fi

  batch_json="$(printf '[{"path":"gateway.mode","value":"local"},{"path":"gateway.bind","value":"%s"}' "$gateway_bind")"
  if [[ -n "$allowed_origin_json" ]]; then
    if [[ -n "$current_allowed_origins" && "$current_allowed_origins" != "null" && "$current_allowed_origins" != "[]" ]]; then
      echo "Control UI allowlist already configured; leaving gateway.controlUi.allowedOrigins unchanged."
    else
      batch_json+=",{\"path\":\"gateway.controlUi.allowedOrigins\",\"value\":$allowed_origin_json}"
    fi
  fi
  batch_json+="]"

  run_project_prestart_cli_checked "$project_name" config set --batch-json "$batch_json" >/dev/null
  echo "Pinned gateway.mode=local and gateway.bind=$gateway_bind for project '$project_name'."
  if [[ -n "$allowed_origin_json" ]]; then
    if [[ -z "$current_allowed_origins" || "$current_allowed_origins" == "null" || "$current_allowed_origins" == "[]" ]]; then
      echo "Set gateway.controlUi.allowedOrigins to $allowed_origin_json"
    fi
  fi
}


