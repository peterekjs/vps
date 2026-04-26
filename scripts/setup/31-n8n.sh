#!/usr/bin/env bash
# 31-n8n.sh — Deploy self-hosted n8n as a Docker Compose systemd service
#
# Usage:
#   sudo bash scripts/setup/31-n8n.sh [options]
#
# Options:
#   --user <name>        Basic-auth username (default: prompt, default "admin")
#   --host <addr>        Bind host (default: prompt, default "0.0.0.0")
#   --password-stdin     Read basic-auth password from stdin (no confirmation prompt)
#   --ufw-allow          Open 5678/tcp in UFW (default: leave closed)
#   -h, --help           Show this help message
#
# What this script does:
#   1. Installs Docker Engine + Compose v2 from Docker's official Debian repo
#   2. Prompts for basic-auth username, password, and bind host
#   3. Deploys config/n8n/docker-compose.yml to /opt/n8n/
#   4. Generates /opt/n8n/.env (mode 600) with the credentials
#   5. Validates the compose project, restoring backups on failure
#   6. Installs config/systemd/n8n.service and starts the n8n service
#   7. Optionally opens 5678/tcp in UFW
#
# Safe to re-run. If /opt/n8n/.env already exists, the script asks before
# overwriting credentials; declining keeps the existing .env and only refreshes
# Docker, the compose file, and the systemd unit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------
ARG_USER=""
ARG_HOST=""
PASSWORD_STDIN=0
UFW_ALLOW=0

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)            ARG_USER="$2"; shift 2 ;;
    --host)            ARG_HOST="$2"; shift 2 ;;
    --password-stdin)  PASSWORD_STDIN=1; shift ;;
    --ufw-allow)       UFW_ALLOW=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

N8N_DIR="/opt/n8n"
ENV_FILE="${N8N_DIR}/.env"
COMPOSE_DEST="${N8N_DIR}/docker-compose.yml"
COMPOSE_SRC="${REPO_ROOT}/config/n8n/docker-compose.yml"
UNIT_DEST="/etc/systemd/system/n8n.service"
UNIT_SRC="${REPO_ROOT}/config/systemd/n8n.service"

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------
section "0. Prerequisites"
require_root
require_debian_bookworm
log_success "Running as root on Debian Bookworm"

# ---------------------------------------------------------------------------
# 1. Install Docker Engine + Compose v2 (from Docker's official Debian repo)
# ---------------------------------------------------------------------------
section "1. Docker Engine + Compose v2"

apt_install ca-certificates curl gnupg

DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
if [[ ! -f "${DOCKER_KEYRING}" ]]; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o "${DOCKER_KEYRING}"
  chmod a+r "${DOCKER_KEYRING}"
  log_success "Installed Docker GPG key → ${DOCKER_KEYRING}"
else
  log_info "Docker GPG key already present"
fi

DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
# shellcheck source=/dev/null
codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME}")
arch=$(dpkg --print-architecture)
desired_repo="deb [arch=${arch} signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/debian ${codename} stable"
if [[ ! -f "${DOCKER_LIST}" ]] || ! grep -qxF "${desired_repo}" "${DOCKER_LIST}"; then
  printf '%s\n' "${desired_repo}" > "${DOCKER_LIST}"
  log_success "Wrote ${DOCKER_LIST}"
  # Force apt_update to re-run since we just changed sources
  _APT_UPDATED=0
else
  log_info "Docker apt source already configured"
fi

apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

service_enable_restart docker

# ---------------------------------------------------------------------------
# 2. Collect basic-auth credentials
# ---------------------------------------------------------------------------
section "2. Basic-auth credentials"

SKIP_ENV=0
if [[ -f "${ENV_FILE}" ]]; then
  log_info "Existing ${ENV_FILE} detected"
  if confirm "Overwrite n8n credentials?"; then
    SKIP_ENV=0
  else
    SKIP_ENV=1
    log_info "Keeping existing credentials in ${ENV_FILE}"
  fi
fi

if [[ "${SKIP_ENV}" -eq 0 ]]; then
  if [[ -n "${ARG_USER}" ]]; then
    AUTH_USER="${ARG_USER}"
  else
    read -r -p "Basic auth username [admin]: " input
    AUTH_USER="${input:-admin}"
  fi

  if [[ -n "${ARG_HOST}" ]]; then
    BIND_HOST="${ARG_HOST}"
  else
    read -r -p "Bind host [0.0.0.0]: " input
    BIND_HOST="${input:-0.0.0.0}"
  fi

  if [[ "${PASSWORD_STDIN}" -eq 1 ]]; then
    IFS= read -r AUTH_PASSWORD || true
    if [[ -z "${AUTH_PASSWORD:-}" ]]; then
      log_error "No password received on stdin"
      exit 1
    fi
  else
    while :; do
      read -r -s -p "Basic auth password: " PW1; echo
      if [[ -z "${PW1}" ]]; then
        log_warn "Password cannot be empty"
        continue
      fi
      read -r -s -p "Confirm password:    " PW2; echo
      if [[ "${PW1}" == "${PW2}" ]]; then
        AUTH_PASSWORD="${PW1}"
        break
      fi
      log_warn "Passwords did not match — try again"
    done
  fi
fi

# ---------------------------------------------------------------------------
# 3. Deploy compose file + .env
# ---------------------------------------------------------------------------
section "3. Deploy compose + .env"

mkdir -p "${N8N_DIR}"
chown root:root "${N8N_DIR}"
chmod 750 "${N8N_DIR}"

compose_backup=$(backup_file "${COMPOSE_DEST}" || true)
cp "${COMPOSE_SRC}" "${COMPOSE_DEST}"
chown root:root "${COMPOSE_DEST}"
chmod 644 "${COMPOSE_DEST}"
log_success "Deployed ${COMPOSE_DEST}"

env_backup=""
if [[ "${SKIP_ENV}" -eq 0 ]]; then
  env_backup=$(backup_file "${ENV_FILE}" || true)
  old_umask=$(umask)
  umask 077
  cat > "${ENV_FILE}" <<EOF
N8N_BASIC_AUTH_USER=${AUTH_USER}
N8N_BASIC_AUTH_PASSWORD=${AUTH_PASSWORD}
N8N_HOST=${BIND_HOST}
EOF
  umask "${old_umask}"
  chown root:root "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  log_success "Wrote ${ENV_FILE} (mode 600)"
fi

# ---------------------------------------------------------------------------
# 4. Validate compose project
# ---------------------------------------------------------------------------
section "4. Validate compose project"

if docker compose -f "${COMPOSE_DEST}" --env-file "${ENV_FILE}" config -q; then
  log_success "docker compose config OK"
else
  log_error "docker compose validation failed — restoring backups"
  if [[ -n "${compose_backup}" && -f "${compose_backup}" ]]; then
    cp --preserve=all "${compose_backup}" "${COMPOSE_DEST}"
    log_info "Restored ${COMPOSE_DEST} from ${compose_backup}"
  fi
  if [[ "${SKIP_ENV}" -eq 0 && -n "${env_backup}" && -f "${env_backup}" ]]; then
    cp --preserve=all "${env_backup}" "${ENV_FILE}"
    log_info "Restored ${ENV_FILE} from ${env_backup}"
  fi
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Install systemd unit
# ---------------------------------------------------------------------------
section "5. systemd unit"

backup_file "${UNIT_DEST}" >/dev/null || true
cp "${UNIT_SRC}" "${UNIT_DEST}"
chown root:root "${UNIT_DEST}"
chmod 644 "${UNIT_DEST}"
systemctl daemon-reload
service_enable_restart n8n

# ---------------------------------------------------------------------------
# 6. Firewall
# ---------------------------------------------------------------------------
section "6. Firewall"

if [[ "${UFW_ALLOW}" -eq 1 ]]; then
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 5678/tcp comment "n8n"
    log_success "UFW: allowed 5678/tcp"
  else
    log_warn "UFW not active — open 5678/tcp manually if needed"
  fi
else
  log_info "UFW unchanged — 5678/tcp is NOT exposed (use --ufw-allow to open it)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "n8n setup complete"

cat <<EOF

  n8n is running as a systemd service backed by docker compose.

  State on disk:
    ${COMPOSE_DEST}
    ${ENV_FILE}                (mode 600 — contains basic-auth password)
    ${N8N_DIR}/n8n_data/                  (created by the n8n container on first run)
    ${UNIT_DEST}

  Useful commands:
    systemctl status n8n
    systemctl restart n8n
    docker compose -f ${COMPOSE_DEST} logs -f
    docker compose -f ${COMPOSE_DEST} pull && \\
      docker compose -f ${COMPOSE_DEST} up -d        # upgrade to latest image

  Reach the UI at http://<host>:5678/ (basic auth: prompted username + password).
  By default the firewall does NOT expose 5678/tcp publicly — access is expected
  via WireGuard or a reverse proxy. Re-run with --ufw-allow to open it.

EOF
