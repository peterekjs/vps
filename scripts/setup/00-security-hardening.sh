#!/usr/bin/env bash
# 00-security-hardening.sh — Initial security hardening for Debian Bookworm
#
# Usage:
#   sudo bash scripts/setup/00-security-hardening.sh [--ssh-port <port>]
#
# What this script does:
#   1.  Verifies prerequisites (root, Debian Bookworm)
#   2.  Updates the system
#   3.  Installs hardening-related packages
#   4.  Hardens SSH (deploys config/ssh/sshd_config)
#   5.  Configures UFW firewall
#   6.  Configures Fail2ban (deploys config/fail2ban/jail.local)
#   7.  Enables automatic security updates
#   8.  Applies kernel parameter hardening (config/sysctl/hardening.conf)
#   9.  Hardens user-account settings (password policy, umask)
#   10. Enables & configures auditd
#
# The script is idempotent — safe to run more than once.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------
SSH_PORT=22

usage() {
  cat <<EOF
Usage: sudo bash $0 [options]

Options:
  --ssh-port <port>   SSH port to open in the firewall (default: 22)
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-port)
      SSH_PORT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      log_error "Unknown option: $1"
      usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------
section "0. Prerequisites"

require_root
require_debian_supported

log_success "Running as root on Debian Bookworm"

# ---------------------------------------------------------------------------
# 1. System update
# ---------------------------------------------------------------------------
section "1. System update"

log_info "Running full system upgrade …"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq
DEBIAN_FRONTEND=noninteractive apt-get autoclean -qq

log_success "System is up to date"

# ---------------------------------------------------------------------------
# 2. Install required packages
# ---------------------------------------------------------------------------
section "2. Installing packages"

apt_install \
  ufw \
  fail2ban \
  unattended-upgrades \
  apt-listchanges \
  auditd \
  audispd-plugins \
  libpam-pwquality \
  acl \
  curl \
  gnupg \
  lsb-release

# ---------------------------------------------------------------------------
# 3. SSH hardening
# ---------------------------------------------------------------------------
section "3. SSH hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_SRC="${REPO_ROOT}/config/ssh/sshd_config"

sshd_backup=$(backup_file "${SSHD_CONFIG}")
cp "${SSHD_CONFIG_SRC}" "${SSHD_CONFIG}"
chmod 600 "${SSHD_CONFIG}"

# Ensure the configured port is actually used (honour --ssh-port flag)
if [[ "${SSH_PORT}" -ne 22 ]]; then
  sed -i "s/^Port 22$/Port ${SSH_PORT}/" "${SSHD_CONFIG}"
  log_info "SSH port set to ${SSH_PORT}"
fi

# Validate configuration before restarting
if sshd -t -f "${SSHD_CONFIG}"; then
  log_success "sshd_config syntax OK"
  service_enable_restart ssh
else
  log_error "sshd_config validation failed — restoring backup"
  if [[ -n "${sshd_backup}" && -f "${sshd_backup}" ]]; then
    cp --preserve=all "${sshd_backup}" "${SSHD_CONFIG}"
    log_info "Restored ${SSHD_CONFIG} from ${sshd_backup}"
  fi
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Firewall (UFW)
# ---------------------------------------------------------------------------
section "4. Firewall (UFW)"

# Reset to defaults and set deny-all baseline
ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# Allow SSH before enabling to avoid locking ourselves out
ufw allow "${SSH_PORT}/tcp" comment "SSH"

# Enable UFW
ufw --force enable

log_success "UFW enabled — default deny incoming, SSH (port ${SSH_PORT}) allowed"
ufw status verbose

# ---------------------------------------------------------------------------
# 5. Fail2ban
# ---------------------------------------------------------------------------
section "5. Fail2ban"

FAIL2BAN_JAIL="/etc/fail2ban/jail.local"
FAIL2BAN_JAIL_SRC="${REPO_ROOT}/config/fail2ban/jail.local"

backup_file "${FAIL2BAN_JAIL}"
cp "${FAIL2BAN_JAIL_SRC}" "${FAIL2BAN_JAIL}"
chmod 640 "${FAIL2BAN_JAIL}"

# If a non-default SSH port is used, update the jail config
if [[ "${SSH_PORT}" -ne 22 ]]; then
  sed -i "s/^port.*= ssh$/port     = ${SSH_PORT}/" "${FAIL2BAN_JAIL}"
fi

service_enable_restart fail2ban
log_success "Fail2ban configured and running"

# ---------------------------------------------------------------------------
# 6. Automatic security updates (unattended-upgrades)
# ---------------------------------------------------------------------------
section "6. Automatic security updates"

UA_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
UA_CONF_SRC="${REPO_ROOT}/config/unattended-upgrades/50unattended-upgrades"

backup_file "${UA_CONF}"
cp "${UA_CONF_SRC}" "${UA_CONF}"
chmod 644 "${UA_CONF}"

# Enable the periodic apt hook that triggers unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

service_enable_restart unattended-upgrades
log_success "Unattended security upgrades enabled"

# ---------------------------------------------------------------------------
# 7. Kernel hardening (sysctl)
# ---------------------------------------------------------------------------
section "7. Kernel hardening (sysctl)"

SYSCTL_CONF="/etc/sysctl.d/99-hardening.conf"
SYSCTL_CONF_SRC="${REPO_ROOT}/config/sysctl/hardening.conf"

backup_file "${SYSCTL_CONF}"
cp "${SYSCTL_CONF_SRC}" "${SYSCTL_CONF}"
chmod 644 "${SYSCTL_CONF}"
chown root:root "${SYSCTL_CONF}"

sysctl --system > /dev/null
log_success "Kernel parameters applied"

# ---------------------------------------------------------------------------
# 8. Password & account policy
# ---------------------------------------------------------------------------
section "8. Password & account policy"

# Configure PAM password quality via /etc/security/pwquality.conf
# Only write the file if it doesn't already exist or differs from our desired state
PWQUALITY_CONF="/etc/security/pwquality.conf"
backup_file "${PWQUALITY_CONF}"
cat > "${PWQUALITY_CONF}" <<'EOF'
# Minimum password length
minlen = 12
# Require at least one digit
dcredit = -1
# Require at least one uppercase letter
ucredit = -1
# Require at least one lowercase letter
lcredit = -1
# Require at least one special character
ocredit = -1
# Disallow passwords that look like dictionary words
dictcheck = 1
EOF
log_success "Password quality policy configured"

# Enforce account inactivity lockout: lock accounts 30 days after password expires
sed -i 's/^#\?\s*INACTIVE=.*/INACTIVE=30/' /etc/default/useradd 2>/dev/null || true

# Set a secure default umask for new users
LOGIN_DEFS="/etc/login.defs"
backup_file "${LOGIN_DEFS}"
# Set umask to 027 (owner rwx, group r-x, others ---)
sed -i 's/^UMASK\s\+.*/UMASK\t\t027/' "${LOGIN_DEFS}"
# Limit password age
sed -i 's/^PASS_MAX_DAYS\s\+.*/PASS_MAX_DAYS\t90/'  "${LOGIN_DEFS}"
sed -i 's/^PASS_MIN_DAYS\s\+.*/PASS_MIN_DAYS\t1/'   "${LOGIN_DEFS}"
sed -i 's/^PASS_WARN_AGE\s\+.*/PASS_WARN_AGE\t14/'  "${LOGIN_DEFS}"
log_success "Login defaults updated (umask 027, 90-day max password age)"

# ---------------------------------------------------------------------------
# 9. Audit daemon (auditd)
# ---------------------------------------------------------------------------
section "9. Audit daemon (auditd)"

service_enable_restart auditd
log_success "auditd enabled and running"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Security hardening complete"

cat <<EOF

  The following measures have been applied:

  ✔  System fully upgraded
  ✔  SSH hardened (root login disabled, password auth disabled, strong ciphers)
  ✔  UFW firewall enabled (default deny incoming; SSH port ${SSH_PORT} open)
  ✔  Fail2ban installed and protecting SSH (ban 24 h after 3 failures)
  ✔  Automatic security updates via unattended-upgrades
  ✔  Kernel parameters hardened (sysctl)
  ✔  Password policy enforced via pam_pwquality (min 12 chars, complexity)
  ✔  90-day password rotation, 027 umask for new users
  ✔  auditd enabled

  ⚠  IMPORTANT — before logging out:
     • Make sure your SSH public key is in ~/.ssh/authorized_keys
     • Password authentication is now DISABLED — key-based auth required
     • Test SSH access in a separate session before closing this one

EOF
