#!/usr/bin/env bash
# Shared helpers for the GOWA VPS scripts.

log() {
  printf '[gowa] %s\n' "$*"
}

warn() {
  printf '[gowa] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[gowa] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: ${cmd}"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "this script must run as root (use sudo)"
}

# Debian architecture name used by Go and Caddy downloads.
detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    armv7l) printf 'armv7' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

detect_public_ip() {
  if [[ -n "${VPS_PUBLIC_IP:-}" ]]; then
    printf '%s' "$VPS_PUBLIC_IP"
    return 0
  fi

  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  printf '%s' "$ip"
}

ensure_firewall_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    log "Ensured UFW allows TCP 80 and 443"
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}
