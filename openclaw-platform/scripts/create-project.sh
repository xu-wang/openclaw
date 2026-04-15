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

usage() {
  cat <<'EOF'
Usage: create-project.sh <project-name>

Creates a new isolated OpenClaw project under openclaw-platform/projects.
This command does not start containers.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

PROJECT_NAME="${1:-}"
validate_project_name "$PROJECT_NAME"
load_defaults_file

PROJECT_DIR="$(project_dir "$PROJECT_NAME")"
ENV_FILE="$(project_env_file "$PROJECT_NAME")"
COMPOSE_FILE="$(project_compose_file "$PROJECT_NAME")"
CONFIG_DIR="$PROJECT_DIR/data/config"
WORKSPACE_DIR="$PROJECT_DIR/data/workspace"

if [[ -e "$PROJECT_DIR" ]]; then
  fail "Project already exists: $PROJECT_NAME"
fi

mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR"
cp "$TEMPLATE_FILE" "$COMPOSE_FILE"

read -r GATEWAY_PORT BRIDGE_PORT < <(find_available_port_pair 18789)
TOKEN="$(generate_gateway_token)"

cat >"$ENV_FILE" <<EOF
OPENCLAW_IMAGE=${OPENCLAW_IMAGE:-openclaw:local}
OPENCLAW_GATEWAY_BIND=${OPENCLAW_GATEWAY_BIND:-lan}
OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}
OPENCLAW_TZ=${OPENCLAW_TZ:-UTC}

OPENCLAW_GATEWAY_PORT=$GATEWAY_PORT
OPENCLAW_BRIDGE_PORT=$BRIDGE_PORT
OPENCLAW_GATEWAY_TOKEN=$TOKEN

OPENCLAW_CONFIG_DIR=$CONFIG_DIR
OPENCLAW_WORKSPACE_DIR=$WORKSPACE_DIR

HTTP_PROXY=${HTTP_PROXY:-}
HTTPS_PROXY=${HTTPS_PROXY:-}
ALL_PROXY=${ALL_PROXY:-}
EOF

chmod 600 "$ENV_FILE"

echo "Created project: $PROJECT_NAME"
echo "Project path: $PROJECT_DIR"
echo "Compose file: $COMPOSE_FILE"
echo "Env file: $ENV_FILE"
echo "Gateway port: $GATEWAY_PORT"
echo "Bridge port: $BRIDGE_PORT"
echo "Config dir: $CONFIG_DIR"
echo "Workspace dir: $WORKSPACE_DIR"
echo "Token: $TOKEN"
echo "Dashboard URL: http://localhost:$GATEWAY_PORT"
echo ""
echo "Next step:"
echo "  ./openclaw-platform/scripts/start-project.sh $PROJECT_NAME"


