#!/usr/bin/env bash
# 31-agent-loop-receiver.sh — Deploy the agent-loop GitHub webhook receiver
#
# Usage:
#   sudo bash scripts/setup/31-agent-loop-receiver.sh [options]
#
# Options:
#   --ref <ref>      Git ref of peterekjs/agent-loop to deploy (default: main)
#   -h, --help       Show this help message
#
# What this script does:
#   1. Installs Node.js (NodeSource LTS repo) and git
#   2. Ensures a read-only deploy key for the PRIVATE hub repo exists at
#      /etc/agent-loop-receiver/deploy_key — generated on first run; you must
#      add the printed public key as a Deploy key on peterekjs/agent-loop,
#      then re-run
#   3. Clones / fast-forwards peterekjs/agent-loop into /opt/agent-loop
#   4. Creates /etc/agent-loop-receiver/env once (webhook secret generated,
#      APP_ID left for you to fill in) — never overwritten
#   5. Runs the receiver's self-tests from the checkout before touching the
#      running service
#   6. Deploys the systemd unit, enables and (re)starts it, probes /health
#
# The App private key (/etc/agent-loop-receiver/app.pem) is NOT generated
# here — download it from the GitHub App settings and copy it in (mode 600).
# Until it exists the unit cannot start and the script says so.
#
# Caddy exposes the receiver as agent-loop.peterek.net (config/caddy/Caddyfile);
# deploy that with scripts/setup/21-caddy.sh. See
# docs/runbooks/agent-loop-receiver.md for the full procedure.
#
# Safe to re-run: package install and repo setup are idempotent, the checkout
# is reset to the requested ref, env/key files are never clobbered.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------
HUB_REF="main"

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)     HUB_REF="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

HUB_REPO_SSH="git@github.com:peterekjs/agent-loop.git"
HUB_DIR="/opt/agent-loop"
STATE_DIR="/etc/agent-loop-receiver"
DEPLOY_KEY="${STATE_DIR}/deploy_key"
ENV_FILE="${STATE_DIR}/env"
APP_KEY="${STATE_DIR}/app.pem"
UNIT_NAME="agent-loop-receiver.service"
UNIT_SRC="${REPO_ROOT}/config/agent-loop-receiver/${UNIT_NAME}"
UNIT_DEST="/etc/systemd/system/${UNIT_NAME}"
NODE_MAJOR="22"
HEALTH_URL="http://127.0.0.1:8812/health"

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------
section "0. Prerequisites"
require_root
require_debian_supported
apt_install ca-certificates curl git gnupg openssl

# ---------------------------------------------------------------------------
# 1. Node.js (NodeSource LTS)
# ---------------------------------------------------------------------------
section "1. Node.js ${NODE_MAJOR}.x"
NODESOURCE_KEYRING="/etc/apt/keyrings/nodesource.gpg"
NODESOURCE_LIST="/etc/apt/sources.list.d/nodesource.list"
if [[ ! -f "${NODESOURCE_KEYRING}" ]]; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o "${NODESOURCE_KEYRING}"
  log_success "Added NodeSource signing key"
fi
NODESOURCE_LINE="deb [signed-by=${NODESOURCE_KEYRING}] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main"
if [[ ! -f "${NODESOURCE_LIST}" ]] || ! grep -qF "node_${NODE_MAJOR}.x" "${NODESOURCE_LIST}"; then
  echo "${NODESOURCE_LINE}" > "${NODESOURCE_LIST}"
  _APT_UPDATED=0
  log_success "Configured NodeSource repository for Node ${NODE_MAJOR}.x"
fi
apt_install nodejs
log_info "node $(node --version)"

# ---------------------------------------------------------------------------
# 2. Deploy key for the private hub repo
# ---------------------------------------------------------------------------
section "2. Deploy key"
install -d -m 0700 "${STATE_DIR}"
if [[ ! -f "${DEPLOY_KEY}" ]]; then
  ssh-keygen -t ed25519 -N "" -C "agent-loop-receiver@$(hostname)" -f "${DEPLOY_KEY}" >/dev/null
  chmod 600 "${DEPLOY_KEY}"
  log_warn "Generated a new deploy key. Add this PUBLIC key as a read-only Deploy key on"
  log_warn "https://github.com/peterekjs/agent-loop/settings/keys, then re-run this script:"
  echo
  cat "${DEPLOY_KEY}.pub"
  echo
  exit 1
fi
log_success "Deploy key present: ${DEPLOY_KEY}"
export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

# ---------------------------------------------------------------------------
# 3. Hub checkout
# ---------------------------------------------------------------------------
section "3. Hub checkout → ${HUB_DIR} @ ${HUB_REF}"
if [[ ! -d "${HUB_DIR}/.git" ]]; then
  git clone --quiet "${HUB_REPO_SSH}" "${HUB_DIR}"
  log_success "Cloned ${HUB_REPO_SSH}"
fi
git -C "${HUB_DIR}" fetch --quiet --tags origin
git -C "${HUB_DIR}" checkout --quiet --detach "origin/${HUB_REF}" 2>/dev/null \
  || git -C "${HUB_DIR}" checkout --quiet --detach "${HUB_REF}"
# The receiver runs as a DynamicUser: world-readable checkout, root-owned.
chmod -R a+rX "${HUB_DIR}"
log_success "Checked out $(git -C "${HUB_DIR}" rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
# 4. Environment file (created once, never overwritten)
# ---------------------------------------------------------------------------
section "4. Environment"
if [[ ! -f "${ENV_FILE}" ]]; then
  sed -e "s/^WEBHOOK_SECRET=.*/WEBHOOK_SECRET=$(openssl rand -hex 32)/" \
    "${HUB_DIR}/receiver/agent-loop-receiver.env.example" > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  log_success "Created ${ENV_FILE} with a fresh WEBHOOK_SECRET"
  log_warn "Fill in APP_ID in ${ENV_FILE} and paste WEBHOOK_SECRET into the GitHub App's webhook settings."
else
  log_info "Keeping existing ${ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# 5. Self-test the checkout before restarting anything
# ---------------------------------------------------------------------------
section "5. Self-test"
if (cd "${HUB_DIR}/receiver" && npm test --silent >/dev/null 2>&1); then
  log_success "Receiver tests pass"
else
  log_error "Receiver tests failed in ${HUB_DIR}/receiver — not deploying. Run: cd ${HUB_DIR}/receiver && npm test"
  exit 1
fi

# ---------------------------------------------------------------------------
# 6. systemd unit
# ---------------------------------------------------------------------------
section "6. Service"
backup_file "${UNIT_DEST}" >/dev/null || true
install -m 0644 "${UNIT_SRC}" "${UNIT_DEST}"
systemctl daemon-reload
log_success "Installed ${UNIT_DEST}"

if [[ ! -f "${APP_KEY}" ]]; then
  log_warn "App private key missing: ${APP_KEY}"
  log_warn "Download it from the GitHub App settings, copy it there (chmod 600), then re-run."
  log_warn "The unit is installed but not started."
  exit 1
fi
chmod 600 "${APP_KEY}"

if grep -q '^APP_ID=123456$' "${ENV_FILE}"; then
  log_warn "APP_ID in ${ENV_FILE} is still the placeholder — set it, then re-run."
  exit 1
fi

service_enable_restart "${UNIT_NAME}"
healthy=0
for _ in $(seq 1 10); do
  if curl -fsS --max-time 2 "${HEALTH_URL}" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 1
done
if [[ "${healthy}" -eq 1 ]]; then
  log_success "Receiver answers ${HEALTH_URL}"
else
  log_error "Receiver not answering on ${HEALTH_URL}. Last journal lines:"
  journalctl -u "${UNIT_NAME}" -n 20 --no-pager >&2 || true
  exit 1
fi

echo
log_info "Next: deploy the Caddy site block (sudo bash scripts/setup/21-caddy.sh) and point the"
log_info "GitHub App webhook at https://agent-loop.peterek.net/webhook — see docs/runbooks/agent-loop-receiver.md"
