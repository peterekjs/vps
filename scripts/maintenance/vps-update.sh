#!/usr/bin/env bash
# vps-update — deliberate full-system patch routine.
#
# Usage:
#   vps-update [--reboot] [--yes] [--notify]
#
# unattended-upgrades already applies security patches daily; run this
# roughly monthly for everything else. Flow: pre-flight health + disk check
# → fresh vps-backup → apt full-upgrade → reboot handling → post-flight
# health → summary notification. --reboot actually reboots when required;
# --yes proceeds despite critical pre-flight findings.
# See docs/runbooks/updates-and-patching.md.

set -euo pipefail
# shellcheck source=scripts/maintenance/lib.sh
source "${VPS_MAINT_LIB:-/usr/local/lib/vps-maintenance/lib.sh}"

DO_REBOOT=0
ASSUME_YES=0
NOTIFY=0
usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reboot)  DO_REBOOT=1; shift ;;
    --yes)     ASSUME_YES=1; shift ;;
    --notify)  NOTIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

require_root
load_conf

# --- 1. Pre-flight -----------------------------------------------------------
section "1. Pre-flight checks"

set +e
vps-health --quiet
health_rc=$?
set -e
if [[ "${health_rc}" -eq 2 && "${ASSUME_YES}" -ne 1 ]]; then
  log_error "Pre-flight health reported CRITICAL findings — fix them first or re-run with --yes."
  exit 2
fi
if [[ "${health_rc}" -eq 0 ]]; then
  log_success "Pre-flight health OK"
else
  log_warn "Proceeding with health exit code ${health_rc}"
fi

avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
if [[ "${avail_mb}" -lt 1024 ]]; then
  log_error "Only ${avail_mb} MB free on / — need at least 1024 MB for a full upgrade."
  exit 2
fi
log_success "${avail_mb} MB free on /"

# --- 2. Fresh backup -----------------------------------------------------------
section "2. Snapshot before upgrading"
vps-backup   # aborts the update if the backup fails (set -e)

# --- 3. Upgrade ------------------------------------------------------------------
section "3. apt full-upgrade"
upgrade_log=$(mktemp)
trap 'rm -f "${upgrade_log}"' EXIT
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y | tee "${upgrade_log}"
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq
DEBIAN_FRONTEND=noninteractive apt-get autoclean -qq
upgraded=$(grep -Eo '^[0-9]+ upgraded' "${upgrade_log}" | awk '{print $1}' | tail -1)
upgraded="${upgraded:-0}"
log_success "${upgraded} package(s) upgraded"

# --- 4. Reboot handling ---------------------------------------------------------------
section "4. Reboot check"
reboot_needed=no
if [[ -f /var/run/reboot-required ]]; then
  reboot_needed=yes
  if [[ "${DO_REBOOT}" -eq 1 ]]; then
    log_warn "Reboot required — rebooting in 1 minute (cancel with 'shutdown -c')."
  else
    log_warn "Reboot required — re-run with --reboot, or reboot manually."
  fi
else
  log_success "No reboot required"
fi

# --- 5. Post-flight + summary ------------------------------------------------------------
section "5. Post-flight health"
set +e
vps-health --quiet
post_rc=$?
set -e

summary="vps-update: ${upgraded} upgraded, reboot required: ${reboot_needed}, post-health exit ${post_rc}"
log_info "${summary}"
if [[ "${NOTIFY}" -eq 1 ]]; then
  sev=ok
  [[ "${post_rc}" -ne 0 || "${reboot_needed}" == "yes" ]] && sev=warning
  notify "${sev}" "vps-update finished" "${summary}"
fi

if [[ "${reboot_needed}" == "yes" && "${DO_REBOOT}" -eq 1 ]]; then
  shutdown -r +1 "vps-update: rebooting to apply kernel/libc updates"
fi
log_success "vps-update complete"
