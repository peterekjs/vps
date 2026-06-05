#!/usr/bin/env bash
# 21-caddy.sh — Deploy Caddy as the native (apt + systemd) edge reverse proxy
#
# Usage:
#   sudo bash scripts/setup/21-caddy.sh [options]
#
# Options:
#   --keep-traefik   Do NOT stop a running Traefik container (default: stop it
#                    so Caddy can bind ports 80/443). Traefik is only stopped,
#                    never removed, so it stays available as a rollback.
#   -h, --help       Show this help message
#
# What this script does:
#   1. Installs Caddy from its official apt repository
#   2. Deploys config/caddy/Caddyfile to /etc/caddy/Caddyfile (with backup)
#   3. Validates the Caddyfile, restoring the backup on failure
#   4. Opens 80/tcp + 443/tcp in UFW (required for HTTP-01 + HTTPS)
#   5. Stops (parks) any running Traefik container to free ports 80/443
#   6. Enables & (re)starts the caddy service, which issues certs via HTTP-01
#
# Caddy obtains Let's Encrypt certificates automatically via the HTTP-01
# challenge — no Cloudflare API token / DNS-01. The hostnames in the Caddyfile
# must already resolve (grey-cloud / DNS-only) to this VPS.
# See docs/adr/0001-native-caddy-http01-reverse-proxy.md.
#
# Safe to re-run: package install, repo setup and the UFW rules are idempotent,
# and the Caddyfile is re-deployed and re-validated each run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------
KEEP_TRAEFIK=0

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-traefik) KEEP_TRAEFIK=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

CADDYFILE_DEST="/etc/caddy/Caddyfile"
CADDYFILE_SRC="${REPO_ROOT}/config/caddy/Caddyfile"

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------
section "0. Prerequisites"
require_root
require_debian_bookworm
log_success "Running as root on Debian Bookworm"

if [[ ! -f "${CADDYFILE_SRC}" ]]; then
  log_error "Caddyfile not found at ${CADDYFILE_SRC}"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Install Caddy (from its official apt repository)
# ---------------------------------------------------------------------------
section "1. Install Caddy"

apt_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg ca-certificates

CADDY_KEYRING="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
if [[ ! -f "${CADDY_KEYRING}" ]]; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o "${CADDY_KEYRING}"
  chmod a+r "${CADDY_KEYRING}"
  log_success "Installed Caddy GPG key → ${CADDY_KEYRING}"
else
  log_info "Caddy GPG key already present"
fi

CADDY_LIST="/etc/apt/sources.list.d/caddy-stable.list"
desired_repo="deb [signed-by=${CADDY_KEYRING}] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main"
if [[ ! -f "${CADDY_LIST}" ]] || ! grep -qxF "${desired_repo}" "${CADDY_LIST}"; then
  printf '%s\n' "${desired_repo}" > "${CADDY_LIST}"
  log_success "Wrote ${CADDY_LIST}"
  # Force apt_update to re-run since we just changed sources
  _APT_UPDATED=0
else
  log_info "Caddy apt source already configured"
fi

apt_install caddy

# ---------------------------------------------------------------------------
# 2. Deploy + validate Caddyfile
# ---------------------------------------------------------------------------
section "2. Deploy Caddyfile"

caddyfile_backup=$(backup_file "${CADDYFILE_DEST}" || true)
install -D -m 644 -o root -g root "${CADDYFILE_SRC}" "${CADDYFILE_DEST}"
log_success "Deployed ${CADDYFILE_DEST}"

if caddy validate --adapter caddyfile --config "${CADDYFILE_DEST}"; then
  log_success "Caddyfile validation OK"
else
  log_error "Caddyfile validation failed — restoring backup"
  if [[ -n "${caddyfile_backup}" && -f "${caddyfile_backup}" ]]; then
    cp --preserve=all "${caddyfile_backup}" "${CADDYFILE_DEST}"
    log_info "Restored ${CADDYFILE_DEST} from ${caddyfile_backup}"
  fi
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Firewall — open 80/443 (required for HTTP-01 + HTTPS)
# ---------------------------------------------------------------------------
section "3. Firewall"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp comment "HTTP (Caddy / ACME HTTP-01)"
  ufw allow 443/tcp comment "HTTPS (Caddy)"
  log_success "UFW: allowed 80/tcp + 443/tcp"
else
  log_warn "UFW not active — open 80/tcp and 443/tcp manually, or HTTP-01 will fail"
fi

# ---------------------------------------------------------------------------
# 4. Park Traefik (free ports 80/443 for Caddy)
# ---------------------------------------------------------------------------
section "4. Park Traefik"

if [[ "${KEEP_TRAEFIK}" -eq 1 ]]; then
  log_info "--keep-traefik given — leaving Traefik untouched (you must free 80/443 yourself)"
elif command -v docker >/dev/null 2>&1; then
  # Match running containers whose name or image mentions traefik.
  mapfile -t traefik_containers < <(
    docker ps --format '{{.Names}} {{.Image}}' \
      | grep -i traefik \
      | awk '{print $1}' || true
  )
  if [[ ${#traefik_containers[@]} -gt 0 ]]; then
    for c in "${traefik_containers[@]}"; do
      docker stop "${c}" >/dev/null
      log_success "Stopped (parked) Traefik container: ${c} — restart with 'docker start ${c}' to roll back"
    done
  else
    log_info "No running Traefik container found — assuming ports 80/443 are free"
  fi
else
  log_info "Docker not installed — nothing to park"
fi

# ---------------------------------------------------------------------------
# 5. Enable + (re)start Caddy
# ---------------------------------------------------------------------------
section "5. Start Caddy"

service_enable_restart caddy

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Caddy setup complete"

cat <<EOF

  Caddy is running as the native systemd reverse proxy and will obtain
  Let's Encrypt certificates via HTTP-01 on first request to each host.

  State on disk:
    ${CADDYFILE_DEST}
    /var/lib/caddy/.local/share/caddy/        (certificates + ACME state)

  Routes:
    https://home.peterek.net   → http://192.168.60.20:8123   (Home Assistant)
    https://agent.peterek.net  → http://10.9.0.4:8811        (agent webhooks)

  Verify:
    systemctl status caddy
    journalctl -u caddy -f                     # watch cert issuance
    curl -I https://home.peterek.net
    curl -I https://agent.peterek.net

  Rollback (during the verification window):
    systemctl stop caddy && docker start <traefik-container>

  Once both routes verify, remove the parked Traefik for good:
    docker rm <traefik-container>              # and delete its compose/config

  NOTE: Home Assistant must trust this reverse proxy or logins will fail. In its
  configuration.yaml add the VPS WireGuard address to http.trusted_proxies and
  set use_x_forwarded_for: true (Home Assistant side — not managed by this repo).

EOF
