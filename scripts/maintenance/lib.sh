#!/usr/bin/env bash
# lib.sh — shared helpers for the installed vps-* maintenance commands.
# Deployed to /usr/local/lib/vps-maintenance/lib.sh by scripts/setup/01-maintenance.sh.
# Self-contained on purpose: installed commands must keep working even if the
# repo clone disappears, so this mirrors (not sources) scripts/utils/common.sh.

set -euo pipefail

# ---------------------------------------------------------------------------
# Terminal colours (disabled when stdout is not a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  _RESET='\033[0m'
  _BOLD='\033[1m'
  _RED='\033[0;31m'
  _YELLOW='\033[0;33m'
  _GREEN='\033[0;32m'
  _CYAN='\033[0;36m'
else
  _RESET='' _BOLD='' _RED='' _YELLOW='' _GREEN='' _CYAN=''
fi

log_info()    { echo -e "${_CYAN}${_BOLD}[INFO ]${_RESET}  $*"; }
log_success() { echo -e "${_GREEN}${_BOLD}[OK   ]${_RESET}  $*"; }
log_warn()    { echo -e "${_YELLOW}${_BOLD}[WARN ]${_RESET}  $*" >&2; }
log_error()   { echo -e "${_RED}${_BOLD}[ERROR]${_RESET}  $*" >&2; }

section() {
  local title="$1"
  echo
  echo -e "${_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_RESET}"
  echo -e "${_BOLD}  ${title}${_RESET}"
  echo -e "${_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_RESET}"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "This command must be run as root (use sudo)."
    exit 1
  fi
}

# Timestamped backup before modifying a file; prints the backup path.
backup_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    local backup
    backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
    cp --preserve=all "${file}" "${backup}"
    log_info "Backed up ${file} → ${backup}"
    echo "${backup}"
  fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VPS_MAINT_CONF="${VPS_MAINT_CONF:-/etc/vps-maintenance.conf}"

load_conf() {
  if [[ -f "${VPS_MAINT_CONF}" ]]; then
    # shellcheck source=/dev/null
    source "${VPS_MAINT_CONF}"
  else
    log_warn "${VPS_MAINT_CONF} not found — using built-in defaults"
  fi
  MAIL_TO="${MAIL_TO:-}"
  MAIL_FROM="${MAIL_FROM:-}"
  SMTP_URL="${SMTP_URL:-smtps://smtp.gmail.com:465}"
  SMTP_USER="${SMTP_USER:-}"
  SMTP_PASS="${SMTP_PASS:-}"
  HA_WEBHOOK_URL="${HA_WEBHOOK_URL:-}"
  AGE_RECIPIENT="${AGE_RECIPIENT:-}"
  REPO_DIR="${REPO_DIR:-/opt/vps}"
  BACKUP_DIR="${BACKUP_DIR:-/var/backups/vps}"
  BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
  BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-48}"
  WG_CRITICAL_PEERS="${WG_CRITICAL_PEERS:-HOME}"
  WG_HANDSHAKE_MAX_AGE="${WG_HANDSHAKE_MAX_AGE:-300}"
  DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
  DISK_CRIT_PCT="${DISK_CRIT_PCT:-90}"
  MEM_AVAILABLE_MIN_MB="${MEM_AVAILABLE_MIN_MB:-200}"
  CERT_WARN_DAYS="${CERT_WARN_DAYS:-14}"
  if [[ -z "${BACKUP_PATHS+x}" ]]; then
    BACKUP_PATHS=(
      /etc/wireguard
      /etc/ssh/ssh_host_*
      /var/lib/caddy
      /etc/caddy/caddy.env
      /etc/vps-maintenance.conf
      /root/.ssh/authorized_keys
    )
  fi
}

# ---------------------------------------------------------------------------
# Check accumulation (used by vps-health / vps-audit)
# Exit-code convention: 0 = ok, 1 = warnings, 2 = critical.
# ---------------------------------------------------------------------------
QUIET="${QUIET:-0}"
CHECKS_OK=0
CHECKS_WARN=0
CHECKS_CRIT=0
FINDINGS=()

check_ok() {
  CHECKS_OK=$((CHECKS_OK + 1))
  [[ "${QUIET}" -eq 1 ]] || log_success "$*"
}

check_warn() {
  CHECKS_WARN=$((CHECKS_WARN + 1))
  FINDINGS+=("WARN: $*")
  log_warn "$*"
}

check_crit() {
  CHECKS_CRIT=$((CHECKS_CRIT + 1))
  FINDINGS+=("CRIT: $*")
  log_error "$*"
}

# finish_checks "<title>" <notify 0|1> — summary, optional notification, exit.
finish_checks() {
  local title="$1" notify_flag="$2"
  echo
  log_info "${title}: ${CHECKS_OK} ok, ${CHECKS_WARN} warning(s), ${CHECKS_CRIT} critical"
  if [[ ${#FINDINGS[@]} -gt 0 && "${notify_flag}" -eq 1 ]]; then
    local severity="warning"
    [[ "${CHECKS_CRIT}" -gt 0 ]] && severity="critical"
    notify "${severity}" "${title} on $(hostname)" "$(printf '%s\n' "${FINDINGS[@]}")"
  fi
  [[ "${CHECKS_CRIT}" -gt 0 ]] && exit 2
  [[ "${CHECKS_WARN}" -gt 0 ]] && exit 1
  exit 0
}

# notify <severity> <title> <message> — send via vps-notify; a notification
# failure must never fail the calling script (spec requirement).
notify() {
  if ! command -v vps-notify >/dev/null 2>&1; then
    log_warn "vps-notify not installed — skipping notification"
    return 0
  fi
  vps-notify --severity "$1" --title "$2" "$3" || log_warn "Notification failed — continuing"
}
