#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: start-project.sh <project-name>

Starts openclaw-gateway for the specified project.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

PROJECT_NAME="${1:-}"
validate_project_name "$PROJECT_NAME"
require_cmd docker

ensure_project_data_dirs "$PROJECT_NAME"
fix_project_data_permissions "$PROJECT_NAME"
run_project_onboarding_once "$PROJECT_NAME"
sync_project_gateway_config "$PROJECT_NAME"

run_project_compose "$PROJECT_NAME" up -d openclaw-gateway

echo "Started project: $PROJECT_NAME"
gateway_port="$(read_env_value "$(project_env_file "$PROJECT_NAME")" OPENCLAW_GATEWAY_PORT || true)"
gateway_port="${gateway_port:-18789}"
echo "Dashboard URL: http://localhost:${gateway_port}"

