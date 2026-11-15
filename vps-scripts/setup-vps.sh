#!/usr/bin/env bash
# GOWA OTP VPS entry point (runs on the VPS as root).
#
# Installs Caddy, writes the runtime .env, installs the systemd service,
# publishes this app's route into a SHARED Caddy configuration, restarts
# everything, and verifies /health. PostgreSQL is never installed here:
# DB_URI must point at an existing database.
#
# Caddy layout (several apps can share one Caddy/VPS):
#   /etc/caddy/Caddyfile              base: global options + import (stable)
#   /etc/caddy/sites-enabled/*.caddy  one file per app; this deploy owns ONE
#
# Usage:
#   bash vps-scripts/setup-vps.sh \
#     --binary /tmp/gowa-deploy/gowa \
#     --env-file /tmp/gowa-deploy/.env
#
# Environment:
#   GOWA_APP_DIR        Default: /opt/gowa
#   GOWA_APP_USER       Default: gowa (unprivileged service account)
#   GOWA_APP_PORT       Default: APP_PORT from the env file, else 8081
#   PUBLIC_BASE_URL     Public origin (from --env-file), drives Caddy TLS
#   GOWA_CADDY_SITE_ID  Default: gowa-otp (unique per app on the VPS)
#   GOWA_CADDY_UPSTREAM Default: 127.0.0.1:<APP_PORT> (or container:port)
#   GOWA_CADDY_EXTRA_HOSTS  Comma-separated extra hostnames (www, etc.)
#   GOWA_CADDY_TAKEOVER true = replace a foreign base Caddyfile
#   VPS_ACME_EMAIL      Optional Let's Encrypt email
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
# shellcheck source=lib/caddy.sh
source "${SCRIPT_DIR}/lib/caddy.sh"
# shellcheck source=lib/wait-for.sh
source "${SCRIPT_DIR}/lib/wait-for.sh"

APP_DIR="${GOWA_APP_DIR:-/opt/gowa}"
APP_USER="${GOWA_APP_USER:-gowa}"
BINARY=""
ENV_FILE=""
SKIP_CADDY=false

usage() {
  cat <<'EOF'
Usage: setup-vps.sh --binary <path> --env-file <path> [options]

Options:
  --binary PATH        Prebuilt linux gowa executable
  --env-file PATH      Runtime environment file (copied to APP_DIR/.env;
                       default: reuse the existing APP_DIR/.env)
  --skip-caddy         Do not install Caddy (useful if already managed)
  -h, --help           Show this help

Environment:
  GOWA_APP_DIR         Default: /opt/gowa
  GOWA_APP_USER        Default: gowa (unprivileged service account)
  GOWA_APP_PORT        Default: APP_PORT from the env file, else 8081
  PUBLIC_BASE_URL      Public origin from the env file (for example
                       https://api.example.com); drives Caddy TLS
  GOWA_CADDY_SITE_ID   Unique Caddy site id (default: gowa-otp)
  GOWA_CADDY_UPSTREAM  Backend for reverse_proxy (default: 127.0.0.1:<port>)
  GOWA_CADDY_EXTRA_HOSTS  Extra hostnames, comma-separated
  GOWA_CADDY_TAKEOVER  true = replace a foreign base Caddyfile
  VPS_ACME_EMAIL       Optional Let's Encrypt email
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      BINARY="${2:?--binary requires a path}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:?--env-file requires a path}"
      shift 2
      ;;
    --skip-caddy)
      SKIP_CADDY=true
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

require_root
[[ -n "$BINARY" ]] || die "--binary is required"
[[ -f "$BINARY" ]] || die "binary not found: ${BINARY}"
if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || die "env file not found: ${ENV_FILE}"
fi
# Without --env-file, keep the configuration already deployed on the server.
RUNTIME_ENV="${ENV_FILE:-${APP_DIR}/.env}"
[[ -f "$RUNTIME_ENV" ]] || die "no environment file: pass --env-file or create ${APP_DIR}/.env"

# Read app/Caddy settings from the env file without sourcing it (values may
# contain shell metacharacters). Explicit environment variables win.
APP_PORT="${GOWA_APP_PORT:-$(env_file_get "$RUNTIME_ENV" APP_PORT "8081")}"
SITE_ID="${GOWA_CADDY_SITE_ID:-$(env_file_get "$RUNTIME_ENV" GOWA_CADDY_SITE_ID "gowa-otp")}"
UPSTREAM="${GOWA_CADDY_UPSTREAM:-$(env_file_get "$RUNTIME_ENV" GOWA_CADDY_UPSTREAM "127.0.0.1:${APP_PORT}")}"
EXTRA_HOSTS="${GOWA_CADDY_EXTRA_HOSTS:-$(env_file_get "$RUNTIME_ENV" GOWA_CADDY_EXTRA_HOSTS "")}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-$(env_file_get "$RUNTIME_ENV" PUBLIC_BASE_URL "")}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL%/}"
ACME_EMAIL="${VPS_ACME_EMAIL:-$(env_file_get "$RUNTIME_ENV" VPS_ACME_EMAIL "")}"

[[ "$APP_PORT" =~ ^[0-9]+$ ]] || die "APP_PORT must be a number (got: '${APP_PORT}')"
[[ "$UPSTREAM" =~ ^[A-Za-z0-9._-]+(:[0-9]+)?$ ]] ||
  die "GOWA_CADDY_UPSTREAM must be HOST[:PORT] (got: '${UPSTREAM}')"
caddy_validate_site_id "$SITE_ID"

# Fail fast with a clear message instead of a crash loop.
DB_URI_VALUE="$(env_file_get "$RUNTIME_ENV" DB_URI "")"
BASIC_AUTH_VALUE="$(env_file_get "$RUNTIME_ENV" APP_BASIC_AUTH "")"
if [[ -z "$DB_URI_VALUE" ]]; then
  die "DB_URI is missing in ${RUNTIME_ENV}"
fi
if [[ -z "$BASIC_AUTH_VALUE" ]]; then
  die "APP_BASIC_AUTH is missing in ${RUNTIME_ENV} (the API must never be public without auth)"
fi
if [[ "$BASIC_AUTH_VALUE" == *CHANGE_ME* ]]; then
  die "APP_BASIC_AUTH still contains a CHANGE_ME placeholder"
fi
if [[ "$BASIC_AUTH_VALUE" != *:* ]]; then
  die "APP_BASIC_AUTH must contain at least one user:password pair"
fi
if [[ "$DB_URI_VALUE" != postgres://* ]]; then
  die "DB_URI must be a PostgreSQL URI (postgres://...). This deployment does not support local SQLite sessions."
fi
if [[ "$DB_URI_VALUE" == *CHANGE_ME* ]]; then
  die "DB_URI still contains a CHANGE_ME placeholder"
fi

DB_KEYS_URI_VALUE="$(env_file_get "$RUNTIME_ENV" DB_KEYS_URI "")"
if [[ -n "$DB_KEYS_URI_VALUE" && "$DB_KEYS_URI_VALUE" != postgres://* ]]; then
  die "DB_KEYS_URI must be blank or a PostgreSQL URI (postgres://...)"
fi

# OTP-only deployments must not persist chat/message history on local disk.
CHAT_STORAGE_URI_VALUE="$(env_file_get "$RUNTIME_ENV" CHAT_STORAGE_URI "")"
if [[ -z "$CHAT_STORAGE_URI_VALUE" ]]; then
  CHAT_STORAGE_URI_VALUE="file::memory:?cache=shared"
  env_set "$RUNTIME_ENV" CHAT_STORAGE_URI "$CHAT_STORAGE_URI_VALUE"
fi
if [[ "$CHAT_STORAGE_URI_VALUE" != *":memory:"* && "$CHAT_STORAGE_URI_VALUE" != *"mode=memory"* ]]; then
  die "CHAT_STORAGE_URI must be an in-memory SQLite URI (for example file::memory:?cache=shared). Refusing to write message history to local disk."
fi

if [[ ! "$PUBLIC_BASE_URL" =~ ^https?://[^/]+$ ]]; then
  die "PUBLIC_BASE_URL must be an absolute http(s) origin without a path (got: '${PUBLIC_BASE_URL}')"
fi
PUBLIC_SCHEME="${PUBLIC_BASE_URL%%://*}"
PUBLIC_HOST="${PUBLIC_BASE_URL#*://}"
if [[ "$PUBLIC_SCHEME" == "https" && "$PUBLIC_HOST" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]+)?$ ]]; then
  die "PUBLIC_BASE_URL cannot use https:// with an IP address (no TLS certificate is possible); use http://${PUBLIC_HOST}"
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  apt_install curl ca-certificates tar
fi

# The pipeline knows the VPS address; fall back to auto-detection when the
# script is run by hand.
PUBLIC_IP="${VPS_PUBLIC_IP:-$(detect_public_ip)}"

# 1. Service user and application directory.
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  log "Creating service user ${APP_USER}"
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin --no-create-home "$APP_USER"
fi
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "${APP_DIR}/bin"
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "${APP_DIR}/statics" "${APP_DIR}/storages"

# 2. Database sanity check. The installer never provisions PostgreSQL itself
#    (see DEPLOYMENT.md), but a local instance is fully supported.
local_db_re='^postgres://([^@/]*@)?(localhost|127\.0\.0\.1|\[::1\])([:/]|$)'
if [[ "$DB_URI_VALUE" =~ $local_db_re ]]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet postgresql; then
    log "Using the PostgreSQL instance on this VPS (loopback, sslmode may be disable)"
  else
    warn "DB_URI points at a local database, but the postgresql service is not active."
    warn "Start PostgreSQL or point DB_URI at an external database, or /health will stay unavailable."
  fi
fi

# 3. Caddy binary (the shared base config is provisioned after the app is up,
#    so a failed deploy never interrupts routing for other apps).
if [[ "$SKIP_CADDY" != true ]]; then
  bash "${SCRIPT_DIR}/lib/install-caddy.sh"
fi

# 4. Install the binary and runtime environment.
install -m 0755 "$BINARY" "${APP_DIR}/bin/gowa"
if [[ -n "$ENV_FILE" ]]; then
  install -m 0600 "$ENV_FILE" "${APP_DIR}/.env"
fi

# Caddy is the only public entry point; bind GOWA to loopback.
env_set "${APP_DIR}/.env" APP_HOST "127.0.0.1"
env_set "${APP_DIR}/.env" APP_PORT "$APP_PORT"
env_set "${APP_DIR}/.env" APP_ALLOW_UNAUTHENTICATED "false"

# OTP-only defaults. Explicit values in .env are preserved.
env_set_default "${APP_DIR}/.env" APP_UI_ENABLED "false"
env_set_default "${APP_DIR}/.env" APP_UI_AUTO_UPDATE "false"
env_set_default "${APP_DIR}/.env" MCP_ENABLED "false"
env_set_default "${APP_DIR}/.env" WHATSAPP_AUTO_DOWNLOAD_MEDIA "false"
env_set_default "${APP_DIR}/.env" WHATSAPP_IGNORE_STATUS_MEDIA "true"
env_set_default "${APP_DIR}/.env" WHATSAPP_AUTO_REJECT_CALL "true"
env_set_default "${APP_DIR}/.env" WHATSAPP_ACCOUNT_VALIDATION "true"
env_set_default "${APP_DIR}/.env" WHATSAPP_PRESENCE_ON_CONNECT "unavailable"
env_set_default "${APP_DIR}/.env" WHATSAPP_PRESENCE_PULSE_ENABLED "false"
env_set_default "${APP_DIR}/.env" APP_TRUSTED_PROXIES "127.0.0.1/32"
env_set_default "${APP_DIR}/.env" CHAT_STORAGE_MAX_OPEN_CONNS "1"
env_set_default "${APP_DIR}/.env" APP_DEBUG "false"
env_set_default "${APP_DIR}/.env" CHATWOOT_ENABLED "false"

# Keep the advertised origin aligned with the Caddy site config, even when
# PUBLIC_BASE_URL was supplied through the environment.
env_set "${APP_DIR}/.env" PUBLIC_BASE_URL "$PUBLIC_BASE_URL"

chown "${APP_USER}:${APP_USER}" "${APP_DIR}/.env" "${APP_DIR}/bin/gowa"
chmod 0600 "${APP_DIR}/.env"

# 5. systemd service.
sed -e "s|@APP_DIR@|${APP_DIR}|g" -e "s|@APP_USER@|${APP_USER}|g" \
  "${SCRIPT_DIR}/systemd/gowa.service" >/etc/systemd/system/gowa.service
chmod 0644 /etc/systemd/system/gowa.service

systemctl daemon-reload
systemctl enable gowa >/dev/null 2>&1 || true
systemctl restart gowa

# 6. Wait for the new process before changing any routing.
if ! wait_for_http "http://127.0.0.1:${APP_PORT}/health" 120; then
  warn "GOWA did not become healthy on 127.0.0.1:${APP_PORT}"
  journalctl -u gowa -n 80 --no-pager || true
  systemctl status gowa --no-pager || true
  exit 1
fi

# 7. Publish this app's route into the shared Caddy configuration.
#    - base Caddyfile: created once, or migrated from a previous single-site
#      layout (timestamped backup kept); a PayConnect-owned base is untouched
#    - site snippet: atomic write, full-config validation, graceful reload;
#      the previous snippet is restored if anything fails
caddy_lock
base_snapshot=""
if [[ -f "$CADDY_BASE_FILE" ]]; then
  base_snapshot="$(mktemp)"
  cp -p "$CADDY_BASE_FILE" "$base_snapshot"
fi
rendered_snippet="$(mktemp)"
trap 'rm -f "${rendered_snippet:-}" "${base_snapshot:-}"' EXIT
if ! (
  ensure_caddy_base "$ACME_EMAIL"
  render_caddy_site "$rendered_snippet" "$SITE_ID" "$PUBLIC_BASE_URL" "$UPSTREAM" "$EXTRA_HOSTS"
  publish_caddy_site "$rendered_snippet" "$SITE_ID"
); then
  # If the base file was migrated in this run, put the previous one back so a
  # later Caddy restart cannot lose the route we failed to replace.
  if [[ -n "$base_snapshot" && -f "$base_snapshot" ]]; then
    cp -p "$base_snapshot" "$CADDY_BASE_FILE"
    warn "Restored the previous base Caddyfile after the failed route publish"
  fi
  exit 1
fi
caddy_unlock

ensure_firewall_ports

# 8. Verify that Caddy routes the public origin to this app. The probe connects
#    to loopback with the public Host/SNI, so it checks this app's own route
#    instead of whatever the VPS IP resolves to. HTTPS still needs public DNS
#    for the certificate: until the DNS record exists, the site fragment is
#    verified through the HTTP->HTTPS redirect instead.
if command -v caddy >/dev/null 2>&1 || [[ -n "${GOWA_CADDY_VALIDATE_CMD:-}" ]]; then
  if ! wait_for_caddy_site "$PUBLIC_BASE_URL" 90; then
    http_status="$(caddy_probe_http_status "$PUBLIC_BASE_URL" "/health")"
    if [[ "$http_status" == "301" || "$http_status" == "308" ]]; then
      warn "Caddy loaded ${SITE_ID}.caddy (HTTP ${http_status} redirect), but TLS is not ready."
      warn "Point DNS for ${PUBLIC_HOST} at ${PUBLIC_IP:-this VPS}, then rerun the deploy to obtain the certificate."
    else
      warn "Caddy is not routing ${PUBLIC_BASE_URL}/health to this app yet (HTTP ${http_status:-no response})"
      systemctl status caddy --no-pager || true
      journalctl -u caddy -n 80 --no-pager || true
      exit 1
    fi
  fi
fi

cat <<EOF

GOWA OTP API is running on the VPS.

  App directory:   ${APP_DIR}
  Service:         systemctl status gowa
  Logs:            journalctl -u gowa -f
  API listens on:  127.0.0.1:${APP_PORT} (loopback only)
  Caddy base:      ${CADDY_BASE_FILE}
  Caddy app file:  $(caddy_site_file "$SITE_ID")
  Caddy upstream:  ${UPSTREAM}
  Health (local):  http://127.0.0.1:${APP_PORT}/health
  Public URL:      ${PUBLIC_BASE_URL}/health

Next: pair the OTP WhatsApp number. See DEPLOYMENT.md ("Pair the WhatsApp
number"). On a fresh deployment, create one slot with POST /devices, request
POST /devices/<id>/login/code?phone=..., then send without X-Device-Id. The slot
registry is in memory; the WhatsApp session lives in PostgreSQL.

EOF
