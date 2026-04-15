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
