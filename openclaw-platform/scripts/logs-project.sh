#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"
usage() {
  cat <<'USAGE'
Usage: logs-project.sh <project-name> [--] [docker compose logs args]
Examples:
  logs-project.sh project-a
  logs-project.sh project-a -- --tail=200
USAGE
}
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
PROJECT_NAME="${1:-}"
validate_project_name "$PROJECT_NAME"
require_cmd docker
shift || true
if [[ "${1:-}" == "--" ]]; then
  shift
fi
if [[ "$#" -eq 0 ]]; then
  run_project_compose "$PROJECT_NAME" logs -f openclaw-gateway
else
  run_project_compose "$PROJECT_NAME" logs "$@"
fi
