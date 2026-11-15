#!/usr/bin/env bash
# Deploy GOWA to the VPS from your machine using values from .env.
#
# This mirrors .github/workflows/deploy-vps.yaml:
#   build linux binary -> upload bundle -> setup-vps.sh -> health check.
#
# The VPS is accessed as VPS_SSH_USER when it is set, otherwise as root.
# A configured VPS_SSH_USER is expected to elevate through passwordless sudo.
#
# Usage (Git Bash / WSL / macOS / Linux):
#   bash vps-scripts/deploy.sh
#
# Required in .env:
#   VPS_HOST=203.0.113.10
#   VPS_SSH_KEY_PATH=~/.ssh/gowa_vps   (or VPS_SSH_KEY with the key content)
#   PUBLIC_BASE_URL=https://api.whatsapp.ktorganicshop.com
#   DB_URI=postgres://...
#   APP_BASIC_AUTH=otp:...
#
# Optional in .env:
#   VPS_SSH_PORT=22
#   VPS_SSH_USER=root
#   VPS_ACME_EMAIL=ops@example.com
#   VPS_GOARCH=amd64
#   APP_PORT=8081                           (unique per app on a shared VPS)
#   GOWA_CADDY_SITE_ID=gowa-otp             (unique per app)
#   GOWA_CADDY_UPSTREAM=127.0.0.1:8081      (or container:port for Docker)
#   GOWA_CADDY_EXTRA_HOSTS=www.example.com
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
# shellcheck source=lib/wait-for.sh
source "${SCRIPT_DIR}/lib/wait-for.sh"

ENV_FILE="${GOWA_ENV_FILE:-${REPO_ROOT}/.env}"
[[ -f "$ENV_FILE" ]] || die "env file not found: ${ENV_FILE}"

VPS_HOST_VALUE="$(env_file_get "$ENV_FILE" VPS_HOST "")"
[[ -n "$VPS_HOST_VALUE" ]] || die "VPS_HOST is missing in ${ENV_FILE}"
VPS_PORT_VALUE="$(env_file_get "$ENV_FILE" VPS_SSH_PORT "22")"
# When VPS_SSH_USER is set we log in as that provider account; otherwise the
# default login user is root.
VPS_USER_VALUE="$(env_file_get "$ENV_FILE" VPS_SSH_USER "")"
if [[ -n "$VPS_USER_VALUE" ]]; then
  SUDO="sudo -n "
else
  VPS_USER_VALUE="root"
  SUDO=""
fi
PUBLIC_BASE_URL_VALUE="$(env_file_get "$ENV_FILE" PUBLIC_BASE_URL "")"
PUBLIC_BASE_URL_VALUE="${PUBLIC_BASE_URL_VALUE%/}"
[[ -n "$PUBLIC_BASE_URL_VALUE" ]] || die "PUBLIC_BASE_URL is missing in ${ENV_FILE} (for example https://api.whatsapp.ktorganicshop.com)"
if [[ ! "$PUBLIC_BASE_URL_VALUE" =~ ^https?://[^/]+$ ]]; then
  die "PUBLIC_BASE_URL must be an absolute http(s) origin without a path (got: ${PUBLIC_BASE_URL_VALUE})"
fi
PUBLIC_SCHEME="${PUBLIC_BASE_URL_VALUE%%://*}"
PUBLIC_HOSTPORT="${PUBLIC_BASE_URL_VALUE#*://}"
PUBLIC_HOST="${PUBLIC_HOSTPORT%%:*}"
PUBLIC_PORT="${PUBLIC_HOSTPORT##*:}"
if [[ "$PUBLIC_PORT" == "$PUBLIC_HOST" ]]; then
  if [[ "$PUBLIC_SCHEME" == "https" ]]; then
    PUBLIC_PORT=443
  else
    PUBLIC_PORT=80
  fi
fi
APP_PORT_VALUE="$(env_file_get "$ENV_FILE" APP_PORT "8081")"
[[ "$APP_PORT_VALUE" =~ ^[0-9]+$ ]] || die "APP_PORT must be a number (got: ${APP_PORT_VALUE})"
SITE_ID_VALUE="$(env_file_get "$ENV_FILE" GOWA_CADDY_SITE_ID "gowa-otp")"
UPSTREAM_VALUE="$(env_file_get "$ENV_FILE" GOWA_CADDY_UPSTREAM "127.0.0.1:${APP_PORT_VALUE}")"
EXTRA_HOSTS_VALUE="$(env_file_get "$ENV_FILE" GOWA_CADDY_EXTRA_HOSTS "")"
ACME_VALUE="$(env_file_get "$ENV_FILE" VPS_ACME_EMAIL "")"
[[ "$SITE_ID_VALUE" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
  die "GOWA_CADDY_SITE_ID must be lowercase letters, digits, '.', '_' or '-' (got: ${SITE_ID_VALUE})"
[[ "$UPSTREAM_VALUE" =~ ^[A-Za-z0-9._-]+(:[0-9]+)?$ ]] ||
  die "GOWA_CADDY_UPSTREAM must be HOST[:PORT] (got: ${UPSTREAM_VALUE})"
GOARCH_VALUE="$(env_file_get "$ENV_FILE" VPS_GOARCH "amd64")"
DB_URI_VALUE="$(env_file_get "$ENV_FILE" DB_URI "")"
[[ -n "$DB_URI_VALUE" ]] || die "DB_URI is missing in ${ENV_FILE}"
if [[ "$DB_URI_VALUE" != postgres://* ]]; then
  die "DB_URI must be a PostgreSQL URI (postgres://...)"
fi
BASIC_AUTH_VALUE="$(env_file_get "$ENV_FILE" APP_BASIC_AUTH "")"
[[ -n "$BASIC_AUTH_VALUE" ]] || die "APP_BASIC_AUTH is missing in ${ENV_FILE}"
if [[ "$BASIC_AUTH_VALUE" == *CHANGE_ME* ]]; then
  die "APP_BASIC_AUTH still contains a CHANGE_ME placeholder"
fi

case "$GOARCH_VALUE" in
  amd64 | arm64) ;;
  *) die "VPS_GOARCH must be amd64 or arm64 (got: ${GOARCH_VALUE})" ;;
esac

require_command go
require_command ssh
require_command tar
require_command curl

KEY_FILE=""
CLEANUP_KEY=0
STAGE=""
cleanup() {
  if [[ -n "$STAGE" ]]; then
    rm -rf "$STAGE"
  fi
  if [[ "$CLEANUP_KEY" == 1 && -n "$KEY_FILE" ]]; then
    rm -f "$KEY_FILE"
  fi
}
trap cleanup EXIT

KEY_CONTENT="$(env_file_get "$ENV_FILE" VPS_SSH_KEY "")"
KEY_PATH_RAW="$(env_file_get "$ENV_FILE" VPS_SSH_KEY_PATH "")"
if [[ -n "$KEY_CONTENT" ]]; then
  KEY_FILE="$(mktemp)"
  printf '%b\n' "$KEY_CONTENT" | tr -d '\r' >"$KEY_FILE"
  chmod 600 "$KEY_FILE"
  CLEANUP_KEY=1
elif [[ -n "$KEY_PATH_RAW" ]]; then
  KEY_FILE="${KEY_PATH_RAW/#\~/$HOME}"
  [[ -f "$KEY_FILE" ]] || die "SSH key not found: ${KEY_FILE}"
else
  die "set VPS_SSH_KEY or VPS_SSH_KEY_PATH in ${ENV_FILE}"
fi

SSH_OPTS=(-i "$KEY_FILE" -p "$VPS_PORT_VALUE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
SSH_TARGET="${VPS_USER_VALUE}@${VPS_HOST_VALUE}"
REMOTE_DIR="/tmp/gowa-deploy"

STAGE="$(mktemp -d)"
mkdir -p "${STAGE}/bundle"

log "Building linux/${GOARCH_VALUE} binary (pure Go SQLite, CGO disabled)..."
(
  cd "${REPO_ROOT}/src"
  CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_VALUE" \
    go build -tags purego -trimpath -ldflags="-s -w" -o "${STAGE}/bundle/gowa" .
)

cp -r "${REPO_ROOT}/vps-scripts" "${STAGE}/bundle/vps-scripts"
cp "$ENV_FILE" "${STAGE}/bundle/.env"
sed -i 's/\r$//' "${STAGE}/bundle/.env"
# Never ship VPS connection details (or a local private key) to the server.
sed -i '/^VPS_[A-Z0-9_]*=/d' "${STAGE}/bundle/.env"
# Caddy is the only public entry point; bind GOWA to loopback on its own port.
env_set "${STAGE}/bundle/.env" APP_HOST "127.0.0.1"
env_set "${STAGE}/bundle/.env" APP_PORT "$APP_PORT_VALUE"
env_set "${STAGE}/bundle/.env" APP_ALLOW_UNAUTHENTICATED "false"
# Shared-Caddy identity (unique per app on the VPS).
env_set "${STAGE}/bundle/.env" GOWA_CADDY_SITE_ID "$SITE_ID_VALUE"
env_set "${STAGE}/bundle/.env" GOWA_CADDY_UPSTREAM "$UPSTREAM_VALUE"
if [[ -n "$EXTRA_HOSTS_VALUE" ]]; then
  env_set "${STAGE}/bundle/.env" GOWA_CADDY_EXTRA_HOSTS "$EXTRA_HOSTS_VALUE"
fi
# OTP deployments keep message history in memory only.
env_set "${STAGE}/bundle/.env" CHAT_STORAGE_URI "file::memory:?cache=shared"
env_set "${STAGE}/bundle/.env" CHAT_STORAGE_MAX_OPEN_CONNS "1"
chmod +x "${STAGE}/bundle/vps-scripts/"*.sh "${STAGE}/bundle/vps-scripts/lib/"*.sh

log "Uploading bundle to ${SSH_TARGET}:${REMOTE_DIR}"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "rm -rf ${REMOTE_DIR} && mkdir -p ${REMOTE_DIR}"
tar -C "${STAGE}/bundle" -czf - . \
  | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "tar -xzf - -C ${REMOTE_DIR}"

log "Installing and restarting on the VPS..."
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  "${SUDO}env VPS_PUBLIC_IP='${VPS_HOST_VALUE}' VPS_ACME_EMAIL='${ACME_VALUE}' GOWA_CADDY_SITE_ID='${SITE_ID_VALUE}' GOWA_CADDY_UPSTREAM='${UPSTREAM_VALUE}' GOWA_CADDY_EXTRA_HOSTS='${EXTRA_HOSTS_VALUE}' GOWA_APP_PORT='${APP_PORT_VALUE}' bash ${REMOTE_DIR}/vps-scripts/setup-vps.sh --binary ${REMOTE_DIR}/gowa --env-file ${REMOTE_DIR}/.env"

log "Checking accessibility..."
# A shared Caddy may route the bare VPS IP to a different app, so only this
# app's own origin (or its loopback port) is a valid target.
if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "curl -fsS --max-time 5 http://127.0.0.1:${APP_PORT_VALUE}/health" >/dev/null; then
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "${SUDO}journalctl -u gowa -n 60 --no-pager || true" || true
  die "GOWA did not answer on 127.0.0.1:${APP_PORT_VALUE} on the VPS"
fi

PUBLIC_CURL_ARGS=()
PUBLIC_HEALTH_OK=0
if wait_for_http "${PUBLIC_BASE_URL_VALUE}/health" 45; then
  PUBLIC_HEALTH_OK=1
else
  log "Public health check via DNS failed on this machine; retrying against ${VPS_HOST_VALUE} directly..."
  PUBLIC_CURL_ARGS=(--resolve "${PUBLIC_HOST}:${PUBLIC_PORT}:${VPS_HOST_VALUE}")
  if wait_for_http "${PUBLIC_BASE_URL_VALUE}/health" 30 "${PUBLIC_CURL_ARGS[@]}"; then
    PUBLIC_HEALTH_OK=1
    log "Public route OK via direct origin check (${PUBLIC_HOST} -> ${VPS_HOST_VALUE}:${PUBLIC_PORT})"
  else
    warn "${PUBLIC_BASE_URL_VALUE}/health is not reachable yet; check DNS and ports 80/443"
    PUBLIC_CURL_ARGS=()
  fi
fi

if [[ "$PUBLIC_HEALTH_OK" -eq 1 ]]; then
  AUTH_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' "${PUBLIC_CURL_ARGS[@]}" -u "$BASIC_AUTH_VALUE" "${PUBLIC_BASE_URL_VALUE}/app/info")"
  if [[ "$AUTH_STATUS" != "200" ]]; then
    die "authenticated GET /app/info returned HTTP ${AUTH_STATUS}; check APP_BASIC_AUTH"
  fi
  log "Public URL and Basic Auth OK: ${PUBLIC_BASE_URL_VALUE}"
fi

ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "rm -rf ${REMOTE_DIR}" || true
log "Deploy complete."
