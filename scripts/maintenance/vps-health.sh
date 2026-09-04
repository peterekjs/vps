#!/usr/bin/env bash
# vps-health — one-shot VPS health report.
#
# Usage:
#   vps-health [--notify] [--quiet]
#
# Checks: core services, wg-quick interfaces + their UFW port, disk/memory/load, TLS cert
# expiry for every Caddyfile hostname, WireGuard handshakes for critical
# peers, notification channel configured, pending updates + reboot-required,
# fail2ban jails, backup freshness.
# Exit codes: 0 ok, 1 warnings, 2 critical. --notify pushes findings to Home
# Assistant (used by vps-health.timer); --quiet suppresses OK lines.
# See docs/runbooks/health-monitoring.md.

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

# --- 1. Services -----------------------------------------------------------
for svc in ssh caddy fail2ban; do
  if systemctl is-active --quiet "${svc}"; then
    check_ok "service ${svc} active"
  else
    check_crit "service ${svc} NOT active"
  fi
done

# auditd needs CAP_AUDIT_CONTROL, which containers (LXC, OpenVZ) never get
# delegated from the host — 00-security-hardening.sh skips enabling it there,
# so this check must agree instead of permanently reporting a false CRIT.
container_type="$(systemd-detect-virt --container 2>/dev/null || echo none)"
if [[ "${container_type}" == "none" ]]; then
  if systemctl is-active --quiet auditd; then
    check_ok "service auditd active"
  else
    check_crit "service auditd NOT active"
  fi
else
  check_ok "service auditd skipped (${container_type} container — unsupported here)"
fi

# `systemctl list-unit-files --state=enabled` does not match enabled
# *instances* of a template unit like wg-quick@.service — systemd reports
# the template itself as "indirect", not "enabled", so that filter always
# returns zero rows regardless of real state. Derive expected instances from
# the configs on disk instead and check each one's enabled state directly.
mapfile -t wg_confs < <(find /etc/wireguard -maxdepth 1 -name '*.conf' -printf '%f\n' 2>/dev/null | sed 's/\.conf$//')
wg_units=()
for c in "${wg_confs[@]}"; do
  if systemctl is-enabled --quiet "wg-quick@${c}" 2>/dev/null; then
    wg_units+=("wg-quick@${c}.service")
  fi
done
if [[ ${#wg_units[@]} -eq 0 ]]; then
  check_warn "no wg-quick@ units enabled"
else
  for u in "${wg_units[@]}"; do
    if systemctl is-active --quiet "${u}"; then
      check_ok "service ${u} active"
    else
      check_crit "service ${u} NOT active"
    fi
  done
fi

# An interface that is up but firewalled is indistinguishable from a healthy
# one until every peer's handshake goes stale — 00-security-hardening.sh
# resets UFW, and a re-run on 2026-07-07 silently dropped the WireGuard port
# for two months. Check the listen port has an allow rule while UFW is active.
if ufw status 2>/dev/null | grep -q "Status: active"; then
  mapfile -t ufw_udp_allows < <(ufw status 2>/dev/null | awk '$2 != "(v6)" && /ALLOW/ && $1 ~ /\/udp$/ {print $1}' | sort -u)
  for c in "${wg_confs[@]}"; do
    wg_port=$(awk -F'=' '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "/etc/wireguard/${c}.conf")
    if [[ ! "${wg_port}" =~ ^[0-9]+$ ]]; then
      check_warn "wg ${c}: no ListenPort in /etc/wireguard/${c}.conf — cannot verify firewall"
      continue
    fi
    if printf '%s\n' "${ufw_udp_allows[@]}" | grep -qxF "${wg_port}/udp"; then
      check_ok "ufw allows ${wg_port}/udp (wg ${c})"
    else
      check_crit "ufw has NO allow rule for ${wg_port}/udp (wg ${c}) — peers cannot handshake; fix: ufw allow ${wg_port}/udp comment 'WireGuard ${c}'"
    fi
  done
fi

# --- Notification channel -----------------------------------------------------
# Every finding below is only useful if it can reach you. This was silently
# broken for months (HA_WEBHOOK_URL never set) — make it a visible finding.
if [[ -n "${MAIL_TO}" && -n "${SMTP_URL}" && -n "${SMTP_USER}" && -n "${SMTP_PASS}" ]]; then
  check_ok "notification channel: email to ${MAIL_TO}"
elif [[ -n "${HA_WEBHOOK_URL}" ]]; then
  check_warn "notification channel: webhook only — it rides over WireGuard, so tunnel failures go unreported; set MAIL_TO/SMTP_* too"
else
  check_warn "no notification channel configured — set MAIL_TO/SMTP_* in ${VPS_MAINT_CONF}; --notify runs cannot reach you"
fi

# --- 2. Disk / memory / load -------------------------------------------------
disk_pct=$(df -P / | awk 'NR==2 {gsub(/%/,""); print $5}')
if [[ "${disk_pct}" -ge "${DISK_CRIT_PCT}" ]]; then
  check_crit "root filesystem ${disk_pct}% full (critical ≥ ${DISK_CRIT_PCT}%)"
elif [[ "${disk_pct}" -ge "${DISK_WARN_PCT}" ]]; then
  check_warn "root filesystem ${disk_pct}% full (warn ≥ ${DISK_WARN_PCT}%)"
else
  check_ok "root filesystem ${disk_pct}% full"
fi

mem_avail_mb=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
if [[ "${mem_avail_mb}" -lt "${MEM_AVAILABLE_MIN_MB}" ]]; then
  check_warn "only ${mem_avail_mb} MB memory available (min ${MEM_AVAILABLE_MIN_MB} MB)"
else
  check_ok "${mem_avail_mb} MB memory available"
fi

cores=$(nproc)
load15=$(awk '{print $3}' /proc/loadavg)
if awk -v l="${load15}" -v c="${cores}" 'BEGIN {exit !(l > 2*c)}'; then
  check_warn "15-min load ${load15} exceeds 2x${cores} cores"
else
  check_ok "15-min load ${load15} (${cores} cores)"
fi

# --- 3. TLS certificate expiry ------------------------------------------------
now_epoch=$(date +%s)
if [[ -f /etc/caddy/Caddyfile ]]; then
  mapfile -t hosts < <(grep -E '^[a-z0-9.-]+\.[a-z0-9-]+ \{' /etc/caddy/Caddyfile | awk '{print $1}')
  for h in "${hosts[@]}"; do
    enddate=$(echo \
      | timeout 10 openssl s_client -servername "${h}" -connect 127.0.0.1:443 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    if [[ -z "${enddate}" ]]; then
      check_crit "cert ${h}: could not fetch certificate from local Caddy"
      continue
    fi
    end_epoch=$(date -d "${enddate}" +%s)
    days=$(( (end_epoch - now_epoch) / 86400 ))
    if [[ "${days}" -lt 3 ]]; then
      check_crit "cert ${h}: expires in ${days} day(s)"
    elif [[ "${days}" -lt "${CERT_WARN_DAYS}" ]]; then
      check_warn "cert ${h}: expires in ${days} day(s) — LE renewal may be failing"
    else
      check_ok "cert ${h}: ${days} days until expiry"
    fi
  done
else
  check_warn "/etc/caddy/Caddyfile not found — skipping cert checks"
fi

# --- 4. WireGuard critical peers ---------------------------------------------
for peer in ${WG_CRITICAL_PEERS}; do
  # Exclude *.d.bak.<timestamp> snapshots (left behind by init.sh re-runs and
  # key rotations) — they match the same */peers/<peer>/public.key glob as
  # the live state dir, and picking one at random via `head -1` compares
  # against a rotated-out key instead of the one actually on the interface.
  keyfile=$(find /etc/wireguard -path "*/peers/${peer}/public.key" -not -path '*.bak.*' 2>/dev/null | head -1)
  if [[ -z "${keyfile}" ]]; then
    check_warn "wg peer ${peer}: no public.key found under /etc/wireguard/*/peers/"
    continue
  fi
  pub=$(cat "${keyfile}")
  last=$(wg show all latest-handshakes 2>/dev/null | awk -v k="${pub}" '$2==k {print $3}' | head -1)
  if [[ -z "${last}" ]]; then
    check_crit "wg peer ${peer}: not present on any interface"
  elif [[ "${last}" -eq 0 ]]; then
    check_crit "wg peer ${peer}: never completed a handshake"
  else
    age=$(( now_epoch - last ))
    if [[ "${age}" -gt "${WG_HANDSHAKE_MAX_AGE}" ]]; then
      check_crit "wg peer ${peer}: last handshake ${age}s ago (max ${WG_HANDSHAKE_MAX_AGE}s)"
    else
      check_ok "wg peer ${peer}: handshake ${age}s ago"
    fi
  fi
done

# --- 5. Updates / reboot -------------------------------------------------------
pending=$(DEBIAN_FRONTEND=noninteractive apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null \
  | grep -c '^Inst' || true)
check_ok "${pending} package update(s) pending (unattended-upgrades handles security)"
if [[ -f /var/run/reboot-required ]]; then
  check_warn "reboot required (pending kernel/libc update) — see vps-update --reboot"
else
  check_ok "no reboot required"
fi

# --- 6. fail2ban jails ----------------------------------------------------------
jails=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')
if [[ -z "${jails// /}" ]]; then
  check_crit "fail2ban: no active jails"
else
  for j in ${jails}; do
    banned=$(fail2ban-client status "${j}" 2>/dev/null \
      | sed -n 's/.*Currently banned:[[:space:]]*//p' | head -1)
    check_ok "fail2ban jail ${j}: ${banned:-?} currently banned"
  done
fi

# --- 7. Backup freshness ---------------------------------------------------------
newest=$(find "${BACKUP_DIR}" -maxdepth 1 -name 'vps-backup-*.tar.gz.age' \
  -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 || true)
if [[ -z "${newest}" ]]; then
  check_warn "no snapshots found in ${BACKUP_DIR} — run vps-backup"
else
  newest_epoch=${newest%%.*}
  age_hours=$(( (now_epoch - newest_epoch) / 3600 ))
  if [[ "${age_hours}" -gt "${BACKUP_MAX_AGE_HOURS}" ]]; then
    check_warn "newest snapshot is ${age_hours}h old (max ${BACKUP_MAX_AGE_HOURS}h): ${newest#* }"
  else
    check_ok "newest snapshot is ${age_hours}h old"
  fi
fi

finish_checks "vps-health" "${NOTIFY}"
