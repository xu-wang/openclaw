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

require_cmd docker

printf '%-16s %-7s %-7s %-12s %s\n' "PROJECT" "GW" "BR" "STATUS" "DASHBOARD"

for dir in "$PROJECTS_ROOT"/*; do
  [[ -d "$dir" ]] || continue
  project_name="$(basename "$dir")"

  env_file="$dir/.env"
  if [[ ! -f "$env_file" ]]; then
    printf '%-16s %-7s %-7s %-12s %s\n' "$project_name" "-" "-" "missing-env" "-"
    continue
  fi

  gateway_port="$(read_env_value "$env_file" OPENCLAW_GATEWAY_PORT || true)"
  bridge_port="$(read_env_value "$env_file" OPENCLAW_BRIDGE_PORT || true)"
  gateway_port="${gateway_port:-?}"
  bridge_port="${bridge_port:-?}"

  status="stopped"
  if run_project_compose "$project_name" ps --services --filter status=running 2>/dev/null | grep -q "openclaw-gateway"; then
    status="running"
  fi

  printf '%-16s %-7s %-7s %-12s %s\n' \
    "$project_name" \
    "$gateway_port" \
    "$bridge_port" \
    "$status" \
    "http://localhost:${gateway_port}"
done
