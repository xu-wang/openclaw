#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

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
