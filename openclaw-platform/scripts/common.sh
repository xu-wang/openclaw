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


