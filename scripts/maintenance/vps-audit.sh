#!/usr/bin/env bash
# vps-audit — hardening drift audit.
#
# Usage:
#   vps-audit [--notify] [--quiet]
#
# Verifies the hardening still holds: repo-managed configs vs deployed files
# (CONFIG_MAP below is the one place to extend for new services), installed
# vps-* copies vs the repo, sshd effective settings, UFW rule set, live
# sysctl values, caddy.env fail-closed guards, fail2ban jails, services
# enabled at boot. Exit codes: 0 ok, 1 warnings, 2 critical.
# See docs/runbooks/drift-audit.md.

set -euo pipefail
# shellcheck source=scripts/maintenance/lib.sh
source "${VPS_MAINT_LIB:-/usr/local/lib/vps-maintenance/lib.sh}"

NOTIFY=0
usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notify)  NOTIFY=1; shift ;;
    --quiet)   QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

require_root
load_conf

# Repo path → deployed path. Extend here when a new service deploys a config.
CONFIG_MAP=(
  "config/ssh/sshd_config:/etc/ssh/sshd_config"
  "config/fail2ban/jail.local:/etc/fail2ban/jail.local"
  "config/fail2ban/filter.d/caddy-llm.conf:/etc/fail2ban/filter.d/caddy-llm.conf"
  "config/fail2ban/jail.d/caddy-llm.local:/etc/fail2ban/jail.d/caddy-llm.local"
  "config/sysctl/hardening.conf:/etc/sysctl.d/99-hardening.conf"
  "config/caddy/Caddyfile:/etc/caddy/Caddyfile"
  "config/unattended-upgrades/50unattended-upgrades:/etc/apt/apt.conf.d/50unattended-upgrades"
  "config/systemd/caddy.service.d/env.conf:/etc/systemd/system/caddy.service.d/env.conf"
  "config/maintenance/systemd/vps-health.service:/etc/systemd/system/vps-health.service"
  "config/maintenance/systemd/vps-health.timer:/etc/systemd/system/vps-health.timer"
  "config/maintenance/systemd/vps-backup.service:/etc/systemd/system/vps-backup.service"
  "config/maintenance/systemd/vps-backup.timer:/etc/systemd/system/vps-backup.timer"
  "config/maintenance/systemd/vps-audit.service:/etc/systemd/system/vps-audit.service"
  "config/maintenance/systemd/vps-audit.timer:/etc/systemd/system/vps-audit.timer"
)

# --- 1. Repo-managed config drift -------------------------------------------
if [[ -d "${REPO_DIR}" ]]; then
  for entry in "${CONFIG_MAP[@]}"; do
    src="${REPO_DIR}/${entry%%:*}"
    dst="${entry##*:}"
    if [[ ! -f "${src}" ]]; then
      check_warn "repo file missing: ${src} (stale CONFIG_MAP entry?)"
    elif [[ ! -f "${dst}" ]]; then
      check_crit "deployed file missing: ${dst}"
    elif diff -q "${src}" "${dst}" >/dev/null; then
      check_ok "in sync: ${dst}"
    else
      check_warn "DRIFT: ${dst} differs from ${entry%%:*} — see drift-audit runbook"
    fi
  done

  # Installed toolkit copies vs repo sources
  for f in "${REPO_DIR}/scripts/maintenance/"*.sh; do
    base=$(basename "${f}" .sh)
    if [[ "${base}" == "lib" ]]; then
      inst="/usr/local/lib/vps-maintenance/lib.sh"
    else
      inst="/usr/local/sbin/${base}"
    fi
    if [[ ! -f "${inst}" ]]; then
      check_crit "not installed: ${inst} — run scripts/setup/01-maintenance.sh"
    elif cmp -s "${f}" "${inst}"; then
      check_ok "toolkit in sync: ${inst}"
    else
      check_warn "DRIFT: ${inst} differs from repo — re-run scripts/setup/01-maintenance.sh"
    fi
  done
else
  check_warn "REPO_DIR ${REPO_DIR} not found — config-diff checks skipped (set REPO_DIR in ${VPS_MAINT_CONF})"
fi

# --- 2. sshd effective settings ------------------------------------------------
if sshd_t=$(sshd -T 2>/dev/null); then
  if grep -q '^permitrootlogin no$' <<<"${sshd_t}"; then
    check_ok "sshd: root login disabled"
  else
    check_crit "sshd: PermitRootLogin is NOT 'no'"
  fi
  if grep -q '^passwordauthentication no$' <<<"${sshd_t}"; then
    check_ok "sshd: password auth disabled"
  else
    check_crit "sshd: PasswordAuthentication is NOT 'no'"
  fi
  ssh_port=$(awk '$1 == "port" {print $2; exit}' <<<"${sshd_t}")
else
  check_crit "sshd -T failed — cannot audit SSH settings"
  ssh_port=22
fi

# --- 3. UFW ----------------------------------------------------------------------
if ufw status | grep -q "Status: active"; then
  check_ok "ufw active"
  expected=("${ssh_port}/tcp" "80/tcp" "443/tcp")
  while IFS= read -r port; do
    [[ -n "${port}" ]] && expected+=("${port}/udp")
  done < <(awk -F'= *' '/^ListenPort/ {print $2}' /etc/wireguard/*.conf 2>/dev/null)
  mapfile -t allowed < <(ufw status | awk '$2 != "(v6)" && /ALLOW/ {print $1}' | sort -u)
  for rule in "${expected[@]}"; do
    if printf '%s\n' "${allowed[@]}" | grep -qxF "${rule}"; then
      check_ok "ufw allows ${rule}"
    else
      check_crit "ufw: expected allow rule missing: ${rule}"
    fi
  done
  for rule in "${allowed[@]}"; do
    if ! printf '%s\n' "${expected[@]}" | grep -qxF "${rule}"; then
      check_warn "ufw: unexpected allow rule: ${rule} (drift?)"
    fi
  done
else
  check_crit "ufw is NOT active"
fi

# --- 4. Live sysctl values --------------------------------------------------------
# Inside a container, kernel.* / fs.* keys are owned by the host kernel and
# cannot be changed from here; a mismatch is reported but is not drift.
sysctl_src="${REPO_DIR}/config/sysctl/hardening.conf"
in_container=0
[[ "$(systemd-detect-virt --container 2>/dev/null || true)" != "none" ]] && in_container=1
if [[ -f "${sysctl_src}" ]]; then
  while IFS='=' read -r key val; do
    key=$(echo "${key}" | tr -d '[:space:]')
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    want=$(echo "${val}" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
    if ! live=$(sysctl -n "${key}" 2>/dev/null); then
      check_warn "sysctl ${key}: not readable on this kernel"
      continue
    fi
    live=$(echo "${live}" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
    if [[ "${live}" == "${want}" ]]; then
      check_ok "sysctl ${key} = ${live}"
    elif [[ "${in_container}" -eq 1 ]] && ! sysctl -q -w "${key}=${live}" 2>/dev/null; then
      # Re-writing the current value is a no-op probe: permission denied means
      # the host kernel owns this key and nothing on this VPS can drift it.
      check_ok "sysctl ${key} = ${live} (repo wants ${want}; host-owned in container, not settable here)"
    else
      check_warn "sysctl ${key} = ${live} (repo wants ${want})"
    fi
  done < <(grep -v '^\s*$' "${sysctl_src}")
fi

# --- 5. caddy.env fail-closed guards (ADR 0002) --------------------------------------
caddy_env="/etc/caddy/caddy.env"
if [[ ! -f "${caddy_env}" ]]; then
  check_crit "${caddy_env} missing — Caddy will fail to start (fail-closed); run 21-caddy.sh"
else
  perms=$(stat -c '%a %U:%G' "${caddy_env}")
  if [[ "${perms}" == "600 root:root" ]]; then
    check_ok "caddy.env permissions 600 root:root"
  else
    check_crit "caddy.env permissions are ${perms} (expected 600 root:root)"
  fi
  if grep -q '^LLM_KEY_[A-Z0-9_]*=..*' "${caddy_env}"; then
    check_ok "caddy.env contains at least one LLM_KEY_*"
  else
    check_crit "caddy.env has no LLM_KEY_* entry — LLM endpoint auth would be broken"
  fi
fi

# --- 6. Boot enablement + unattended-upgrades ------------------------------------------
for svc in ssh caddy fail2ban auditd; do
  if systemctl is-enabled --quiet "${svc}"; then
    check_ok "${svc} enabled at boot"
  else
    check_warn "${svc} NOT enabled at boot"
  fi
done
if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] \
   && grep -q 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  check_ok "unattended-upgrades periodic run enabled"
else
  check_crit "unattended-upgrades periodic run NOT enabled"
fi

# --- 7. fail2ban jails ---------------------------------------------------------------
jails=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ',')
for j in sshd caddy-llm; do
  if grep -qw "${j}" <<<"${jails}"; then
    check_ok "fail2ban jail ${j} active"
  else
    check_crit "fail2ban jail ${j} NOT active"
  fi
done

finish_checks "vps-audit" "${NOTIFY}"
