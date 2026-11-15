#!/usr/bin/env bash
# Publish GOWA's Caddy route to a shared Caddy on a VPS.
#
# This is the small, repo-agnostic entry point you can mirror into another app
# repository. It only ever writes <sites-dir>/<site-id>.caddy, validates the
# full Caddy config, and reloads gracefully. A failed validation restores the
# previous snippet, so other apps keep running.
#
# Examples:
#   # Provision the shared base once (root):
#   sudo bash vps-scripts/caddy/install-base.sh --email ops@example.com
#
#   # Deploy (root, or a deploy user that owns sites-enabled):
#   bash vps-scripts/caddy/apply-site.sh \
#     --site-id myapp \
#     --public-url https://app.example.com \
#     --upstream 127.0.0.1:3001
#
#   # Remove this app's routes
#   bash vps-scripts/caddy/apply-site.sh --site-id myapp --remove
#
# Values can also come from the environment:
#   GOWA_CADDY_SITE_ID, PUBLIC_BASE_URL, GOWA_CADDY_UPSTREAM,
#   GOWA_CADDY_EXTRA_HOSTS, VPS_ACME_EMAIL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/caddy.sh
source "${SCRIPT_DIR}/../lib/caddy.sh"

SITE_ID="${GOWA_CADDY_SITE_ID:-}"
PUBLIC_URL="${PUBLIC_BASE_URL:-}"
UPSTREAM="${GOWA_CADDY_UPSTREAM:-127.0.0.1:8081}"
EXTRA_HOSTS="${GOWA_CADDY_EXTRA_HOSTS:-}"
ACME_EMAIL="${VPS_ACME_EMAIL:-}"
ENSURE_BASE=false
OWNER=""
DRY_RUN=false
REMOVE=false

usage() {
  cat <<'EOF'
Usage: apply-site.sh --site-id ID --public-url URL [options]

Options:
  --site-id ID          Unique per app; becomes <sites-dir>/<ID>.caddy
  --public-url URL      Public origin, e.g. https://app.example.com
  --upstream HOST:PORT  Backend, e.g. 127.0.0.1:8081 or container:8080
  --extra-host HOST     Additional hostname (repeatable), e.g. www.example.com
  --acme-email EMAIL    Only used together with --ensure-base
  --ensure-base         Create/repair the shared base Caddyfile (needs root)
  --owner USER:GROUP    Only with --ensure-base: grant write access to sites dir
  --dry-run             Print the snippet and exit without touching Caddy
  --remove              Remove this app's snippet, validate, and reload
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-id)
      SITE_ID="${2:?--site-id requires a value}"
      shift 2
      ;;
    --public-url)
      PUBLIC_URL="${2:?--public-url requires a value}"
      shift 2
      ;;
    --upstream)
      UPSTREAM="${2:?--upstream requires a value}"
      shift 2
      ;;
    --extra-host)
      [[ -n "${2:-}" ]] || die "--extra-host requires a value"
      EXTRA_HOSTS="${EXTRA_HOSTS:+${EXTRA_HOSTS},}$2"
      shift 2
      ;;
    --acme-email)
      ACME_EMAIL="${2:?--acme-email requires a value}"
      shift 2
      ;;
    --ensure-base)
      ENSURE_BASE=true
      shift
      ;;
    --owner)
      OWNER="${2:?--owner requires USER:GROUP}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --remove)
      REMOVE=true
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

[[ -n "$SITE_ID" ]] || die "--site-id (or GOWA_CADDY_SITE_ID) is required"
caddy_validate_site_id "$SITE_ID"

if [[ "$REMOVE" == true ]]; then
  caddy_lock
  remove_caddy_site "$SITE_ID"
  caddy_unlock
  exit 0
fi

[[ -n "$PUBLIC_URL" ]] || die "--public-url (or PUBLIC_BASE_URL) is required"
PUBLIC_URL="${PUBLIC_URL%/}"
[[ "$PUBLIC_URL" =~ ^https?://[^/]+$ ]] ||
  die "--public-url must be an absolute http(s) origin without a path (got: ${PUBLIC_URL})"

[[ "$UPSTREAM" =~ ^[A-Za-z0-9._-]+(:[0-9]+)?$ ]] ||
  die "--upstream must be HOST[:PORT] (got: ${UPSTREAM})"

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
render_caddy_site "$rendered" "$SITE_ID" "$PUBLIC_URL" "$UPSTREAM" "$EXTRA_HOSTS"

if [[ "$DRY_RUN" == true ]]; then
  cat "$rendered"
  exit 0
fi

caddy_lock

base_snapshot=""
if [[ "$ENSURE_BASE" == true && -f "$CADDY_BASE_FILE" ]]; then
  base_snapshot="$(mktemp)"
  cp -p "$CADDY_BASE_FILE" "$base_snapshot"
  trap 'rm -f "$rendered" "${base_snapshot:-}"' EXIT
fi

if ! (
  if [[ "$ENSURE_BASE" == true ]]; then
    ensure_caddy_base "$ACME_EMAIL"
    if [[ -n "$OWNER" ]]; then
      chown -R "$OWNER" "$CADDY_SITES_DIR" "$CADDY_BACKUP_DIR"
      chmod 0775 "$CADDY_SITES_DIR" "$CADDY_BACKUP_DIR"
    fi
  fi

  grep -Fq "$(caddy_import_line)" "$CADDY_BASE_FILE" 2>/dev/null || die "${CADDY_BASE_FILE} does not import ${CADDY_SITES_DIR}/*.caddy
Run: sudo bash vps-scripts/caddy/install-base.sh"

  publish_caddy_site "$rendered" "$SITE_ID"
); then
  if [[ -n "$base_snapshot" && -f "$base_snapshot" ]]; then
    cp -p "$base_snapshot" "$CADDY_BASE_FILE"
    warn "Restored the previous base Caddyfile after the failed route publish"
  fi
  exit 1
fi
caddy_unlock

log "App '${SITE_ID}' is routed: ${PUBLIC_URL} -> ${UPSTREAM}"
