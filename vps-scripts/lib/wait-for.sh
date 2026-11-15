#!/usr/bin/env bash
# Small HTTP readiness helper shared by local and remote deploy scripts.
set -euo pipefail

wait_for_http() {
  local url="$1"
  local timeout="${2:-120}"
  shift 2 || true
  local elapsed=0

  while (( elapsed < timeout )); do
    if curl -fsS --max-time 5 "$@" "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done

  return 1
}
