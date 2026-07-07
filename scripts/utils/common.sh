#!/usr/bin/env bash
# common.sh — Shared helper functions for VPS maintenance scripts
# Source this file at the top of every script:
#   source "$(dirname "$0")/../utils/common.sh"

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

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()    { echo -e "${_CYAN}${_BOLD}[INFO ]${_RESET}  $*"; }
log_success() { echo -e "${_GREEN}${_BOLD}[OK   ]${_RESET}  $*"; }
log_warn()    { echo -e "${_YELLOW}${_BOLD}[WARN ]${_RESET}  $*" >&2; }
log_error()   { echo -e "${_RED}${_BOLD}[ERROR]${_RESET}  $*" >&2; }

# Print a prominent section header
section() {
  local title="$1"
  echo
  echo -e "${_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_RESET}"
  echo -e "${_BOLD}  ${title}${_RESET}"
  echo -e "${_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_RESET}"
}

# ---------------------------------------------------------------------------
# Precondition checks
# ---------------------------------------------------------------------------

# Abort if not running as root
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)."
    exit 1
  fi
}

# Debian releases these scripts are validated against. After completing the
# debian-release-upgrade runbook on a new release, add its codename here.
SUPPORTED_CODENAMES=(bookworm)

# Abort unless the OS is Debian with a codename in SUPPORTED_CODENAMES
require_debian_supported() {
  if [[ ! -f /etc/os-release ]]; then
    log_error "Cannot detect OS — /etc/os-release not found."
    exit 1
  fi
  # Read in a subshell so vars like NAME/VERSION/ID don't leak into callers.
  local id codename pretty
  # shellcheck source=/dev/null
  id=$(. /etc/os-release && printf '%s' "${ID-}")
  # shellcheck source=/dev/null
  codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME-}")
  # shellcheck source=/dev/null
  pretty=$(. /etc/os-release && printf '%s' "${PRETTY_NAME-}")
  local supported
  for supported in "${SUPPORTED_CODENAMES[@]}"; do
    if [[ "${id}" == "debian" && "${codename}" == "${supported}" ]]; then
      return 0
    fi
  done
  log_error "This script targets Debian (${SUPPORTED_CODENAMES[*]}). Detected: ${pretty:-unknown}."
  exit 1
}

# ---------------------------------------------------------------------------
# File helpers
# ---------------------------------------------------------------------------

# Create a timestamped backup of a file before modifying it.
# Prints the backup path to stdout so callers can capture it for later restore.
# Usage: backup_path=$(backup_file /etc/ssh/sshd_config)
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
# Package management
# ---------------------------------------------------------------------------

# Update apt package lists (once per script invocation)
_APT_UPDATED=0
apt_update() {
  if [[ "${_APT_UPDATED}" -eq 0 ]]; then
    log_info "Updating apt package lists …"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    _APT_UPDATED=1
  fi
}

# Install one or more packages if not already installed
apt_install() {
  local pkgs=("$@")
  local to_install=()
  for pkg in "${pkgs[@]}"; do
    if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"; then
      to_install+=("${pkg}")
    fi
  done
  if [[ ${#to_install[@]} -gt 0 ]]; then
    apt_update
    log_info "Installing: ${to_install[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}"
    log_success "Installed: ${to_install[*]}"
  else
    log_info "Already installed: ${pkgs[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Systemd helpers
# ---------------------------------------------------------------------------

# Enable and start (or restart) a systemd service.
# Verifies the service is actually active afterward — a service can exit
# non-zero from its post-start check (e.g. crash-looping) while `systemctl
# start`/`restart` itself still returns 0, so that alone can't be trusted.
service_enable_restart() {
  local svc="$1"
  systemctl enable "${svc}"
  if systemctl is-active --quiet "${svc}"; then
    systemctl restart "${svc}"
  else
    systemctl start "${svc}"
  fi
  if ! systemctl is-active --quiet "${svc}"; then
    log_error "${svc} did not stay active after start — check: systemctl status ${svc}; journalctl -u ${svc}"
    return 1
  fi
  log_success "${svc} is active"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

# Confirm an action interactively (defaults to "no" when not a TTY)
confirm() {
  local prompt="${1:-Continue?} [y/N] "
  if [[ ! -t 0 ]]; then
    # Non-interactive — proceed automatically
    return 0
  fi
  read -r -p "${prompt}" answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}
