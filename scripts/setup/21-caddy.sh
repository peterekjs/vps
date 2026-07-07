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
#   2. Bootstraps the LLM endpoint prerequisites: generates /etc/caddy/caddy.env
#      (per-client API keys — created once, never overwritten), installs the
#      systemd drop-in that loads it, and prepares /var/log/caddy
#   3. Deploys config/caddy/Caddyfile to /etc/caddy/Caddyfile (with backup)
#   4. Validates the Caddyfile, restoring the backup on failure
#   5. Opens 80/tcp + 443/tcp in UFW (required for HTTP-01 + HTTPS)
#   6. Stops (parks) any running Traefik container to free ports 80/443
#   7. Enables & (re)starts the caddy service, which issues certs via HTTP-01
#   8. Deploys the caddy-llm fail2ban filter + jail (skipped if fail2ban is
#      not installed — run 00-security-hardening.sh first)
#
# Caddy obtains Let's Encrypt certificates automatically via the HTTP-01
# challenge — no Cloudflare API token / DNS-01. The hostnames in the Caddyfile
# must already resolve (grey-cloud / DNS-only) to this VPS.
# See docs/adr/0001-native-caddy-http01-reverse-proxy.md and
# docs/adr/0002-authenticated-llm-endpoint.md (llm.peterek.net edge auth).
#
# Safe to re-run: package install, repo setup and the UFW rules are idempotent,
# the Caddyfile is re-deployed and re-validated each run, and existing API keys
# in /etc/caddy/caddy.env are never touched.

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
CADDY_ENV_DEST="/etc/caddy/caddy.env"
CADDY_DROPIN_DEST="/etc/systemd/system/caddy.service.d/env.conf"
CADDY_DROPIN_SRC="${REPO_ROOT}/config/systemd/caddy.service.d/env.conf"
CADDY_LOG_DIR="/var/log/caddy"
LLM_ACCESS_LOG="${CADDY_LOG_DIR}/llm-access.log"
F2B_FILTER_DEST="/etc/fail2ban/filter.d/caddy-llm.conf"
F2B_FILTER_SRC="${REPO_ROOT}/config/fail2ban/filter.d/caddy-llm.conf"
F2B_JAIL_DEST="/etc/fail2ban/jail.d/caddy-llm.local"
F2B_JAIL_SRC="${REPO_ROOT}/config/fail2ban/jail.d/caddy-llm.local"

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------
section "0. Prerequisites"
require_root
require_debian_supported
log_success "Running as root on Debian Bookworm"

if [[ ! -f "${CADDYFILE_SRC}" ]]; then
  log_error "Caddyfile not found at ${CADDYFILE_SRC}"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Install Caddy (from its official apt repository)
# ---------------------------------------------------------------------------
section "1. Install Caddy"

apt_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg ca-certificates openssl

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
# 2. LLM endpoint prerequisites (API keys, systemd drop-in, log dir)
# ---------------------------------------------------------------------------
section "2. LLM endpoint prerequisites"

# API key env file — created once with a generated admin key, never overwritten
# on re-runs (rotation and per-client onboarding are manual edits; see the
# comments written into the file itself, and ADR 0002).
if [[ ! -f "${CADDY_ENV_DEST}" ]]; then
  admin_key="$(openssl rand -hex 32)"
  (
    umask 077
    cat > "${CADDY_ENV_DEST}" <<'EOF'
# /etc/caddy/caddy.env — secrets for the {$VAR} placeholders in the Caddyfile.
# Loaded by systemd via caddy.service.d/env.conf. Root-only; NEVER commit.
#
# One key per client (ADR 0002 in the vps repo). To onboard a client:
#   1. append:  LLM_KEY_<CLIENT>=$(openssl rand -hex 32)
#   2. add a matching line to the @no_key matcher in config/caddy/Caddyfile
#      (in the repo) and redeploy:  header Authorization "Bearer {$LLM_KEY_<CLIENT>}"
#   3. systemctl reload caddy   — systemd re-reads this file for the reload;
#      running "caddy reload" by hand does NOT pick up new values.
# To revoke a client: delete its line here and its matcher line, then reload.
EOF
    printf 'LLM_KEY_ADMIN=%s\n' "${admin_key}" >> "${CADDY_ENV_DEST}"
  )
  chown root:root "${CADDY_ENV_DEST}"
  log_success "Generated ${CADDY_ENV_DEST} (mode 600)"
  log_warn "Initial API key LLM_KEY_ADMIN (also stored in ${CADDY_ENV_DEST}):"
  log_warn "  ${admin_key}"
else
  log_info "${CADDY_ENV_DEST} already exists — keys left untouched"
fi

if ! grep -q '^LLM_KEY_[A-Z0-9_]*=..*' "${CADDY_ENV_DEST}"; then
  log_error "${CADDY_ENV_DEST} contains no LLM_KEY_* entry — an empty key would leave the endpoint nearly open. Add one and re-run."
  exit 1
fi

# systemd drop-in that loads the env file (required — Caddy must fail to start
# without its keys rather than start with empty ones).
if [[ ! -f "${CADDY_DROPIN_DEST}" ]] || ! cmp -s "${CADDY_DROPIN_SRC}" "${CADDY_DROPIN_DEST}"; then
  install -D -m 644 -o root -g root "${CADDY_DROPIN_SRC}" "${CADDY_DROPIN_DEST}"
  systemctl daemon-reload
  log_success "Deployed systemd drop-in ${CADDY_DROPIN_DEST}"
else
  log_info "systemd drop-in already up to date"
fi

# Log directory + file for the llm access log (Caddy runs as user caddy; the
# caddy-llm fail2ban jail needs the file to exist before it starts).
install -d -m 755 -o caddy -g caddy "${CADDY_LOG_DIR}"
if [[ ! -f "${LLM_ACCESS_LOG}" ]]; then
  touch "${LLM_ACCESS_LOG}"
  chown caddy:caddy "${LLM_ACCESS_LOG}"
  chmod 640 "${LLM_ACCESS_LOG}"
fi
log_success "Prepared ${LLM_ACCESS_LOG}"

# ---------------------------------------------------------------------------
# 3. Deploy + validate Caddyfile
# ---------------------------------------------------------------------------
section "3. Deploy Caddyfile"

caddyfile_backup=$(backup_file "${CADDYFILE_DEST}" || true)
install -D -m 644 -o root -g root "${CADDYFILE_SRC}" "${CADDYFILE_DEST}"
log_success "Deployed ${CADDYFILE_DEST}"

if caddy validate --adapter caddyfile --config "${CADDYFILE_DEST}" --envfile "${CADDY_ENV_DEST}"; then
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
# 4. Firewall — open 80/443 (required for HTTP-01 + HTTPS)
# ---------------------------------------------------------------------------
section "4. Firewall"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp comment "HTTP (Caddy / ACME HTTP-01)"
  ufw allow 443/tcp comment "HTTPS (Caddy)"
  log_success "UFW: allowed 80/tcp + 443/tcp"
else
  log_warn "UFW not active — open 80/tcp and 443/tcp manually, or HTTP-01 will fail"
fi

# ---------------------------------------------------------------------------
# 5. Park Traefik (free ports 80/443 for Caddy)
# ---------------------------------------------------------------------------
section "5. Park Traefik"

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
# 6. Enable + (re)start Caddy
# ---------------------------------------------------------------------------
section "6. Start Caddy"

service_enable_restart caddy

# ---------------------------------------------------------------------------
# 7. fail2ban jail for the LLM endpoint
# ---------------------------------------------------------------------------
section "7. fail2ban jail (llm endpoint)"

if [[ -d /etc/fail2ban ]]; then
  backup_file "${F2B_FILTER_DEST}" >/dev/null || true
  install -D -m 644 -o root -g root "${F2B_FILTER_SRC}" "${F2B_FILTER_DEST}"
  backup_file "${F2B_JAIL_DEST}" >/dev/null || true
  install -D -m 644 -o root -g root "${F2B_JAIL_SRC}" "${F2B_JAIL_DEST}"
  log_success "Deployed caddy-llm fail2ban filter + jail"
  service_enable_restart fail2ban
else
  log_warn "fail2ban not installed — skipping caddy-llm jail (run 00-security-hardening.sh, then re-run this script)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Caddy setup complete"

cat <<EOF

  Caddy is running as the native systemd reverse proxy and will obtain
  Let's Encrypt certificates via HTTP-01 on first request to each host.

  State on disk:
    ${CADDYFILE_DEST}
    ${CADDY_ENV_DEST}                       (LLM API keys — root-only, not in git)
    /var/lib/caddy/.local/share/caddy/        (certificates + ACME state)

  Routes:
    https://home.peterek.net   → http://192.168.60.20:8123    (Home Assistant)
    https://agent.peterek.net  → http://192.168.40.10:8811    (agent webhooks)
    https://llm.peterek.net    → http://192.168.40.10:11434   (Ollama, edge auth)

  Verify:
    systemctl status caddy
    journalctl -u caddy -f                     # watch cert issuance
    curl -I https://home.peterek.net
    curl -I https://agent.peterek.net
    curl -i https://llm.peterek.net/v1/models  # expect 401 without a key
    curl -i https://llm.peterek.net/v1/models \\
      -H "Authorization: Bearer <LLM_KEY_ADMIN value from ${CADDY_ENV_DEST}>"

  LLM endpoint (see docs/adr/0002-authenticated-llm-endpoint.md):
    - Keys: one per client in ${CADDY_ENV_DEST}; onboarding/rotation steps are
      documented in that file. After key changes: systemctl reload caddy.
    - Browser clients also need their origin pinned in the @cors_origin
      matcher in config/caddy/Caddyfile (replace the .invalid placeholder).
    - Mac Studio side (not managed by this repo): enable "Expose Ollama to
      the network" in Ollama.app settings (or OLLAMA_HOST=0.0.0.0), allow it
      through the macOS firewall, and keep the Mac from sleeping.
    - DNS: llm.peterek.net must be a grey-cloud (DNS-only) A record pointing
      at this VPS, or HTTP-01 issuance will fail.

  Rollback (during the verification window):
    systemctl stop caddy && docker start <traefik-container>

  Once both routes verify, remove the parked Traefik for good:
    docker rm <traefik-container>              # and delete its compose/config

  NOTE: Home Assistant must trust this reverse proxy or logins will fail. In its
  configuration.yaml add the VPS WireGuard address to http.trusted_proxies and
  set use_x_forwarded_for: true (Home Assistant side — not managed by this repo).

EOF
