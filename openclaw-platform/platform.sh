#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  platform.sh create <project-name>
  platform.sh start <project-name>
  platform.sh stop <project-name>
  platform.sh logs <project-name> [--] [docker compose logs args]
  platform.sh list
EOF
}

COMMAND="${1:-}"
if [[ -z "$COMMAND" || "$COMMAND" == "-h" || "$COMMAND" == "--help" ]]; then
  usage
  exit 0
fi

shift || true

case "$COMMAND" in
  create)
    exec "$ROOT_DIR/scripts/create-project.sh" "$@"
    ;;
  start)
    exec "$ROOT_DIR/scripts/start-project.sh" "$@"
    ;;
  stop)
    exec "$ROOT_DIR/scripts/stop-project.sh" "$@"
    ;;
  logs)
    exec "$ROOT_DIR/scripts/logs-project.sh" "$@"
    ;;
  list)
    exec "$ROOT_DIR/scripts/list-projects.sh" "$@"
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage
    exit 1
    ;;
esac

