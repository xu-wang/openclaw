#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"
usage() {
  cat <<'USAGE'
Usage: stop-project.sh <project-name>
Stops and removes containers for the specified project.
USAGE
}
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
PROJECT_NAME="${1:-}"
validate_project_name "$PROJECT_NAME"
require_cmd docker
run_project_compose "$PROJECT_NAME" down
echo "Stopped project: $PROJECT_NAME"
