#!/usr/bin/env bash
# Install Caddy from the official Cloudsmith apt repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if command -v caddy >/dev/null 2>&1 && systemctl cat caddy.service >/dev/null 2>&1; then
  log "Caddy already installed: $(caddy version | head -n1)"
  exit 0
fi

require_command apt-get

apt_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg

log "Adding the Caddy apt repository..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  >/etc/apt/sources.list.d/caddy-stable.list

apt-get update -y
apt-get install -y caddy
systemctl enable caddy >/dev/null 2>&1 || true

log "Caddy installed: $(caddy version | head -n1)"
