#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

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


