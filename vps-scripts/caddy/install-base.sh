#!/usr/bin/env bash
# Provision or verify the shared base Caddyfile on a VPS.
#
# Safe to run repeatedly. It creates /etc/caddy/sites-enabled and, when needed,
# replaces the base Caddyfile with the shared version (a timestamped backup is
# kept). It never touches existing app snippets, including PayConnect's.
#
# Usage:
#   bash vps-scripts/caddy/install-base.sh [--email ops@example.com]
#                                          [--owner deploy:caddy]
#                                          [--takeover]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/caddy.sh
source "${SCRIPT_DIR}/../lib/caddy.sh"

ACME_EMAIL=""
OWNER=""
TAKEOVER=false

usage() {
  cat <<'EOF'
Usage: install-base.sh [options]

Options:
  --email EMAIL     Let's Encrypt account email written to the global block
  --owner USER:GRP  Give this account write access to sites-enabled (for CI)
  --takeover        Replace a foreign /etc/caddy/Caddyfile (backup is kept)
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)
      ACME_EMAIL="${2:?--email requires a value}"
      shift 2
      ;;
    --owner)
      OWNER="${2:?--owner requires USER:GROUP}"
      shift 2
      ;;
    --takeover)
      TAKEOVER=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ "$TAKEOVER" == true ]]; then
  export GOWA_CADDY_TAKEOVER=true
fi

caddy_lock

base_snapshot=""
if [[ -f "$CADDY_BASE_FILE" ]]; then
  base_snapshot="$(mktemp)"
  cp -p "$CADDY_BASE_FILE" "$base_snapshot"
  trap 'rm -f "${base_snapshot:-}"' EXIT
fi

ensure_caddy_base "$ACME_EMAIL"

if [[ -n "$OWNER" ]]; then
  chown -R "$OWNER" "$CADDY_SITES_DIR" "$CADDY_BACKUP_DIR"
  chmod 0775 "$CADDY_SITES_DIR" "$CADDY_BACKUP_DIR"
  (umask 000 && : >>"$CADDY_LOCK_FILE") 2>/dev/null || true
  chown "$OWNER" "$CADDY_LOCK_FILE" 2>/dev/null || true
  chmod 0664 "$CADDY_LOCK_FILE" 2>/dev/null || true
  log "Granted ${OWNER} write access to ${CADDY_SITES_DIR}"
fi

caddy_restore_base_snapshot() {
  if [[ -n "$base_snapshot" && -f "$base_snapshot" ]]; then
    cp -p "$base_snapshot" "$CADDY_BASE_FILE"
    warn "Restored the previous ${CADDY_BASE_FILE}"
  fi
}

if command -v caddy >/dev/null 2>&1 || [[ -n "${GOWA_CADDY_VALIDATE_CMD:-}" ]]; then
  if ! caddy_validate; then
    caddy_restore_base_snapshot
    die "the Caddy configuration is invalid; fix it before deploying apps"
  fi
  log "Caddy configuration is valid"
  if ! caddy_reload; then
    caddy_restore_base_snapshot
    die "Caddy could not be reloaded; restored the previous configuration"
  fi
  caddy_unlock
  log "Base Caddy configuration is ready: ${CADDY_BASE_FILE}"
  exit 0
fi

caddy_unlock
warn "caddy is not installed yet; the base file will be validated after installation"
log "Base Caddy configuration is ready: ${CADDY_BASE_FILE}"
