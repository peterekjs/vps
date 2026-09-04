#!/usr/bin/env bash
# 01-maintenance.sh — install the vps-* maintenance toolkit
#
# Usage:
#   sudo bash scripts/setup/01-maintenance.sh
#
# What this script does:
#   1. Installs dependencies (age)
#   2. Creates the vpsbackup system group (read access to encrypted snapshots)
#   3. Validates and installs scripts/maintenance/ to /usr/local/sbin/vps-*
#      and /usr/local/lib/vps-maintenance/lib.sh
#   4. Deploys /etc/vps-maintenance.conf from the template (ONLY if absent —
#      your machine-specific values are never overwritten)
#   5. Deploys + enables the systemd timers (vps-health daily, vps-backup
#      daily, vps-audit weekly)
#
# Safe to re-run: scripts and units are re-deployed (that IS the upgrade
# path after git pull), the conf file is left untouched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

LIB_DEST="/usr/local/lib/vps-maintenance/lib.sh"
SBIN_DEST="/usr/local/sbin"
CONF_DEST="/etc/vps-maintenance.conf"
CONF_SRC="${REPO_ROOT}/config/maintenance/vps-maintenance.conf"
UNIT_SRC_DIR="${REPO_ROOT}/config/maintenance/systemd"

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------
section "0. Prerequisites"
require_root
require_debian_supported
log_success "Running as root on a supported Debian release"

# ---------------------------------------------------------------------------
# 1. Dependencies
# ---------------------------------------------------------------------------
section "1. Dependencies"
apt_install age curl openssl

# ---------------------------------------------------------------------------
# 2. vpsbackup group
# ---------------------------------------------------------------------------
section "2. Backup access group"
if getent group vpsbackup >/dev/null; then
  log_info "Group vpsbackup already exists"
else
  groupadd --system vpsbackup
  log_success "Created system group vpsbackup"
fi
log_info "Add your SSH user to it for backup pulls: usermod -aG vpsbackup <user>"

# ---------------------------------------------------------------------------
# 3. Validate + install the toolkit
# ---------------------------------------------------------------------------
section "3. Install maintenance commands"
for f in "${REPO_ROOT}/scripts/maintenance/"*.sh; do
  bash -n "${f}"
done
log_success "All maintenance scripts parse cleanly (bash -n)"

install -D -m 644 -o root -g root "${REPO_ROOT}/scripts/maintenance/lib.sh" "${LIB_DEST}"
log_success "Installed ${LIB_DEST}"

for f in "${REPO_ROOT}/scripts/maintenance/"vps-*.sh; do
  name="$(basename "${f}" .sh)"
  install -D -m 755 -o root -g root "${f}" "${SBIN_DEST}/${name}"
  log_success "Installed ${SBIN_DEST}/${name}"
done

# ---------------------------------------------------------------------------
# 4. Configuration file (deploy once, never clobber)
# ---------------------------------------------------------------------------
section "4. Configuration"
if [[ -f "${CONF_DEST}" ]]; then
  log_info "${CONF_DEST} already exists — left untouched"
else
  install -D -m 600 -o root -g root "${CONF_SRC}" "${CONF_DEST}"
  # Point the drift audit at this clone
  sed -i "s|^REPO_DIR=.*|REPO_DIR=\"${REPO_ROOT}\"|" "${CONF_DEST}"
  log_success "Deployed ${CONF_DEST} (REPO_DIR=${REPO_ROOT})"
  log_warn "EDIT ${CONF_DEST}: set MAIL_TO/SMTP_USER/SMTP_PASS and AGE_RECIPIENT before relying on backups/alerts"
fi

# ---------------------------------------------------------------------------
# 5. systemd timers
# ---------------------------------------------------------------------------
section "5. systemd timers"
for u in "${UNIT_SRC_DIR}"/*; do
  dest="/etc/systemd/system/$(basename "${u}")"
  backup_file "${dest}" >/dev/null || true
  install -D -m 644 -o root -g root "${u}" "${dest}"
done
systemctl daemon-reload
for t in vps-health vps-backup vps-audit; do
  systemctl enable --now "${t}.timer"
  log_success "Enabled ${t}.timer"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Maintenance toolkit installed"
cat <<EOF

  Commands:  vps-health  vps-backup  vps-restore  vps-audit  vps-update  vps-notify
  Timers:
$(systemctl list-timers 'vps-*' --no-pager | sed 's/^/    /')

  Next steps (first install only):
    1. At HOME, generate the backup key:   age-keygen -o vps-backup.key
       → paste the public key into ${CONF_DEST} (AGE_RECIPIENT)
       → keep the key file at home; NEVER copy it to this VPS
    2. Create a Google app password for the alert mailbox
       (docs/runbooks/health-monitoring.md) and set MAIL_TO, SMTP_USER, SMTP_PASS
    3. Test the channel:                   vps-notify --title Test "hello from \$(hostname)"
    4. First snapshot + health pass:       vps-backup && vps-health
    5. Allow your SSH user to pull backups: usermod -aG vpsbackup <user>
       then from home: scripts/home/pull-backups.sh <user>@<vps>

EOF
