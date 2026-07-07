# VPS Maintenance Toolkit & Runbooks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Installed `vps-*` maintenance commands (health, backup, restore, audit, update, notify) with systemd timers, age-encrypted pull-from-home backups, Home Assistant notifications, and ten runbooks — per the approved spec `docs/superpowers/specs/2026-07-07-vps-maintenance-design.md`.

**Architecture:** Canonical sources live in `scripts/maintenance/` + `config/maintenance/`; the numbered setup script `scripts/setup/01-maintenance.sh` deploys them to `/usr/local/sbin/vps-*`, `/usr/local/lib/vps-maintenance/lib.sh`, `/etc/systemd/system/`, and `/etc/vps-maintenance.conf` (template, never clobbered). Installed commands are self-contained (no repo dependency at runtime); `vps-audit` closes the loop by diffing deployed copies against the repo.

**Tech Stack:** Bash (Debian Bookworm), systemd timers, `age` (public-key encryption), `openssl`, `curl`, UFW, fail2ban, WireGuard, Caddy.

## Global Constraints

- Target OS: **Debian Bookworm (12)**, scripts run **as root on the VPS** (`require_root` + OS guard). Dev machine runs only `shellcheck`/`bash -n`.
- Every script: `set -euo pipefail`; use logging helpers (`log_info`/`log_success`/`log_warn`/`log_error`/`section`), never bare `echo` for status.
- `backup_file` (or the same timestamped-backup pattern) before overwriting any system file.
- Reference repo configs via `${REPO_ROOT}/config/...`; add `# shellcheck source=...` directives when sourcing.
- Exit-code convention for check commands: **0 = ok, 1 = warnings, 2 = critical**.
- New apt dependency allowed: `age` only (plus already-present `curl`, `openssl`).
- Maintenance commands source `"${VPS_MAINT_LIB:-/usr/local/lib/vps-maintenance/lib.sh}"` — env override enables repo-checkout testing.
- Config contract: `/etc/vps-maintenance.conf`, bash-sourceable; variable names exactly as defined in Task 2.
- Backups: `vps-backup-<YYYYmmdd-HHMMSS>.tar.gz.age` + `.sha256` in `BACKUP_DIR`, dir `750 root:vpsbackup`, files `640 root:vpsbackup` (age encryption protects content; the group enables non-root rsync pull).
- Validation = `shellcheck scripts/setup/*.sh scripts/utils/*.sh scripts/maintenance/*.sh scripts/home/*.sh` + `bash -n` (no test framework; do not invent one). If shellcheck is missing on the dev machine: `brew install shellcheck`.
- Runbooks follow the skeleton **When to use → Prerequisites → Steps → Verify → Rollback/Recovery**.
- Commit after every task; message style matches repo history (imperative, no prefix tags).

---

### Task 1: Generalize the OS guard for future Debian releases

**Files:**
- Modify: `scripts/utils/common.sh:51-69` (replace `require_debian_bookworm`)
- Modify: `scripts/setup/00-security-hardening.sh:61`, `scripts/setup/21-caddy.sh:81`, `scripts/wireguard/init.sh:57`, `scripts/wireguard/add-peer.sh:44`, `scripts/wireguard/edit-peer.sh:62` (call sites)

**Interfaces:**
- Produces: `require_debian_supported` in `common.sh` — no args, aborts unless `ID=debian` and `VERSION_CODENAME` is in `SUPPORTED_CODENAMES`. `SUPPORTED_CODENAMES=(bookworm)` is the single line future upgrades touch.
- The old name `require_debian_bookworm` is **removed** (all call sites migrate in this task).

- [ ] **Step 1: Replace the function in common.sh**

Replace the whole `require_debian_bookworm()` block (lines 51–69) with:

```bash
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
```

- [ ] **Step 2: Update all five call sites**

```bash
cd /Users/jiri/projects/peterekjs/vps
grep -rl 'require_debian_bookworm' scripts/ | while read -r f; do
  sed -i '' 's/require_debian_bookworm/require_debian_supported/g' "$f"
done
grep -rn 'require_debian_bookworm' scripts/   # expect: no matches
```

(Note: BSD sed on macOS needs `-i ''`.)

- [ ] **Step 3: Lint**

Run: `shellcheck scripts/setup/*.sh scripts/utils/*.sh scripts/wireguard/*.sh && bash -n scripts/utils/common.sh`
Expected: no new warnings (pre-existing warnings in untouched files, if any, are out of scope).

- [ ] **Step 4: Commit**

```bash
git add scripts/
git commit -m "Generalize OS guard to a supported-codenames list"
```

---

### Task 2: Configuration template + shared maintenance library

**Files:**
- Create: `config/maintenance/vps-maintenance.conf`
- Create: `scripts/maintenance/lib.sh`

**Interfaces:**
- Produces (conf variables, all with lib defaults): `HA_WEBHOOK_URL` (string, empty = notifications disabled), `AGE_RECIPIENT` (string), `REPO_DIR` (path), `BACKUP_DIR` (path), `BACKUP_RETENTION_DAYS` (int), `BACKUP_MAX_AGE_HOURS` (int), `BACKUP_PATHS` (bash array), `WG_CRITICAL_PEERS` (space-separated names), `WG_HANDSHAKE_MAX_AGE` (seconds), `DISK_WARN_PCT`/`DISK_CRIT_PCT` (int), `MEM_AVAILABLE_MIN_MB` (int), `CERT_WARN_DAYS` (int).
- Produces (lib functions): `log_info/log_success/log_warn/log_error/section`, `require_root`, `load_conf`, `check_ok "msg"`, `check_warn "msg"`, `check_crit "msg"`, `finish_checks "<title>" <notify 0|1>` (prints summary, notifies if findings and flag set, exits 0/1/2), `notify <severity> <title> <message>` (never fails the caller), `backup_file <path>` (same contract as common.sh). Globals: `QUIET` (0/1, suppresses `check_ok` output), `CHECKS_OK/CHECKS_WARN/CHECKS_CRIT`, `FINDINGS` array, `VPS_MAINT_CONF` (conf path, env-overridable).

- [ ] **Step 1: Write the conf template**

`config/maintenance/vps-maintenance.conf`:

```bash
# /etc/vps-maintenance.conf — machine-specific settings for the vps-* commands.
# Deployed once by scripts/setup/01-maintenance.sh; NEVER overwritten on re-run.
# Bash-sourced (KEY="value", arrays allowed). Mode 600 root:root — never commit
# real values to the repo (the repo copy is a placeholder template).

# --- Notifications ---------------------------------------------------------
# Home Assistant webhook URL, reached over WireGuard. Create an automation
# with a webhook trigger in HA (docs/runbooks/health-monitoring.md), then put
# its URL here. Empty = vps-notify errors out; timer runs still log to journald.
HA_WEBHOOK_URL=""

# --- Backups ----------------------------------------------------------------
# age PUBLIC key snapshots are encrypted to. Generate the pair AT HOME:
#   age-keygen -o vps-backup.key
# Keep vps-backup.key at home (password manager + one offline copy); paste the
# printed "public key: age1..." value here. The private key must NEVER be
# stored on the VPS.
AGE_RECIPIENT=""
# Where snapshots are written (dir 750 root:vpsbackup, files 640).
BACKUP_DIR="/var/backups/vps"
BACKUP_RETENTION_DAYS=14
# vps-health warns when the newest snapshot is older than this many hours.
BACKUP_MAX_AGE_HOURS=48
# State captured by vps-backup: identity & secrets NOT reproducible from the
# repo (configuration comes from the repo; see the design spec). Extend when a
# new service adds machine-specific state.
BACKUP_PATHS=(
  /etc/wireguard
  /etc/ssh/ssh_host_*
  /var/lib/caddy
  /etc/caddy/caddy.env
  /etc/vps-maintenance.conf
  /root/.ssh/authorized_keys
)

# --- Drift audit -------------------------------------------------------------
# Clone of https://github.com/peterekjs/vps on this VPS. vps-audit diffs
# deployed configs against it; 01-maintenance.sh fills in the real path on
# first deploy.
REPO_DIR="/opt/vps"

# --- Health thresholds --------------------------------------------------------
# WireGuard peers (names under /etc/wireguard/<iface>.d/peers/) that must stay
# connected; the HOME peer carries all proxied backends.
WG_CRITICAL_PEERS="HOME"
WG_HANDSHAKE_MAX_AGE=300      # seconds since last handshake before critical
DISK_WARN_PCT=80              # root filesystem usage %
DISK_CRIT_PCT=90
MEM_AVAILABLE_MIN_MB=200
CERT_WARN_DAYS=14             # LE renews at 30 days; below 14 means renewal is broken
```

- [ ] **Step 2: Write lib.sh**

`scripts/maintenance/lib.sh`:

```bash
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
```

- [ ] **Step 3: Lint**

Run: `shellcheck scripts/maintenance/lib.sh && bash -n scripts/maintenance/lib.sh && bash -n config/maintenance/vps-maintenance.conf`
Expected: clean. (SC2034 "appears unused" hints for conf variables are acceptable only in the conf template — silence with a leading `# shellcheck disable=SC2034` line in the conf if flagged; lib.sh itself must be clean.)

- [ ] **Step 4: Smoke-test the lib on the dev machine**

```bash
bash -c 'VPS_MAINT_CONF=config/maintenance/vps-maintenance.conf \
  source scripts/maintenance/lib.sh; load_conf; check_ok "lib loads"; \
  echo "BACKUP_DIR=${BACKUP_DIR} retention=${BACKUP_RETENTION_DAYS}"'
```
Expected: `[OK   ]  lib loads` and `BACKUP_DIR=/var/backups/vps retention=14`.

- [ ] **Step 5: Commit**

```bash
git add config/maintenance/vps-maintenance.conf scripts/maintenance/lib.sh
git commit -m "Add maintenance config template and shared library"
```

---

### Task 3: vps-notify

**Files:**
- Create: `scripts/maintenance/vps-notify.sh` (installed as `/usr/local/sbin/vps-notify`)

**Interfaces:**
- Consumes: `lib.sh` (`load_conf`, logging), conf `HA_WEBHOOK_URL`.
- Produces CLI: `vps-notify [--severity info|ok|warning|critical] [--title <t>] <message>`. POSTs JSON `{"title","message","severity","host"}`; exit 0 on delivery, 1 on missing config/args, 2 on send failure. (Callers that must not fail go through lib `notify`, which swallows errors.)

- [ ] **Step 1: Write the script**

`scripts/maintenance/vps-notify.sh`:

```bash
#!/usr/bin/env bash
# vps-notify — send a JSON notification to the Home Assistant webhook.
#
# Usage:
#   vps-notify [--severity info|ok|warning|critical] [--title <title>] <message>
#
# Reads HA_WEBHOOK_URL from /etc/vps-maintenance.conf. The webhook is reached
# over WireGuard; the HA-side automation is documented in
# docs/runbooks/health-monitoring.md. Exit codes: 0 sent, 1 usage/config
# error, 2 delivery failure.

set -euo pipefail
# shellcheck source=scripts/maintenance/lib.sh
source "${VPS_MAINT_LIB:-/usr/local/lib/vps-maintenance/lib.sh}"

SEVERITY="info"
TITLE="VPS notification"
MESSAGE=""

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --severity) SEVERITY="$2"; shift 2 ;;
    --title)    TITLE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          MESSAGE="$1"; shift ;;
  esac
done

if [[ -z "${MESSAGE}" ]]; then
  log_error "No message given."
  usage
  exit 1
fi

load_conf
if [[ -z "${HA_WEBHOOK_URL}" ]]; then
  log_error "HA_WEBHOOK_URL is not set in ${VPS_MAINT_CONF} — cannot notify."
  exit 1
fi

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  printf '%s' "${s}"
}

payload=$(printf '{"title":"%s","message":"%s","severity":"%s","host":"%s"}' \
  "$(json_escape "${TITLE}")" \
  "$(json_escape "${MESSAGE}")" \
  "$(json_escape "${SEVERITY}")" \
  "$(json_escape "$(hostname)")")

if curl -fsS -m 10 -H 'Content-Type: application/json' \
     -d "${payload}" "${HA_WEBHOOK_URL}" >/dev/null; then
  log_success "Notification sent (${SEVERITY}): ${TITLE}"
else
  log_error "Failed to deliver notification to ${HA_WEBHOOK_URL}"
  exit 2
fi
```

- [ ] **Step 2: Lint + local dry exercise**

Run: `shellcheck scripts/maintenance/vps-notify.sh && bash -n scripts/maintenance/vps-notify.sh`
Expected: clean.

Run (dev machine — exercises arg parsing and the missing-URL path):
```bash
VPS_MAINT_LIB=scripts/maintenance/lib.sh \
VPS_MAINT_CONF=config/maintenance/vps-maintenance.conf \
bash scripts/maintenance/vps-notify.sh --severity warning --title Test "hello"; echo "rc=$?"
```
Expected: `[ERROR]  HA_WEBHOOK_URL is not set ...` and `rc=1`.

- [ ] **Step 3: Commit**

```bash
git add scripts/maintenance/vps-notify.sh
git commit -m "Add vps-notify Home Assistant webhook notifier"
```

---

### Task 4: vps-health

**Files:**
- Create: `scripts/maintenance/vps-health.sh` (installed as `/usr/local/sbin/vps-health`)

**Interfaces:**
- Consumes: lib (`load_conf`, `check_*`, `finish_checks`, `require_root`), conf thresholds, `vps-notify` via lib `notify`.
- Produces CLI: `vps-health [--notify] [--quiet]`; exit 0/1/2. Timer runs use both flags.

- [ ] **Step 1: Write the script**

`scripts/maintenance/vps-health.sh`:

```bash
#!/usr/bin/env bash
# vps-health — one-shot VPS health report.
#
# Usage:
#   vps-health [--notify] [--quiet]
#
# Checks: core services, wg-quick interfaces, disk/memory/load, TLS cert
# expiry for every Caddyfile hostname, WireGuard handshakes for critical
# peers, pending updates + reboot-required, fail2ban jails, backup freshness.
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
for svc in ssh caddy fail2ban auditd; do
  if systemctl is-active --quiet "${svc}"; then
    check_ok "service ${svc} active"
  else
    check_crit "service ${svc} NOT active"
  fi
done

mapfile -t wg_units < <(systemctl list-unit-files 'wg-quick@*.service' \
  --state=enabled --no-legend 2>/dev/null | awk '{print $1}')
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
  keyfile=$(find /etc/wireguard -path "*/peers/${peer}/public.key" 2>/dev/null | head -1)
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
```

- [ ] **Step 2: Lint**

Run: `shellcheck scripts/maintenance/vps-health.sh && bash -n scripts/maintenance/vps-health.sh`
Expected: clean. (`date -d`, `find -printf`, `nproc` are GNU-only — fine, this runs on Debian; do not "fix" for macOS.)

- [ ] **Step 3: Commit**

```bash
git add scripts/maintenance/vps-health.sh
git commit -m "Add vps-health check command"
```

---

### Task 5: vps-backup

**Files:**
- Create: `scripts/maintenance/vps-backup.sh` (installed as `/usr/local/sbin/vps-backup`)

**Interfaces:**
- Consumes: lib, conf `AGE_RECIPIENT`, `BACKUP_DIR`, `BACKUP_PATHS`, `BACKUP_RETENTION_DAYS`.
- Produces CLI: `vps-backup [--dry-run] [--notify]`; writes `${BACKUP_DIR}/vps-backup-<YYYYmmdd-HHMMSS>.tar.gz.age` + `.sha256`; prunes older than retention; exit 0 on success, 2 on failure. Requires the `vpsbackup` group (created by Task 9's deploy script).

- [ ] **Step 1: Write the script**

`scripts/maintenance/vps-backup.sh`:

```bash
#!/usr/bin/env bash
# vps-backup — encrypted snapshot of state not reproducible from the repo.
#
# Usage:
#   vps-backup [--dry-run] [--notify]
#
# Tars BACKUP_PATHS, verifies the tar, encrypts with age to AGE_RECIPIENT
# (public key — the private key lives at home, never on this VPS), writes
# BACKUP_DIR/vps-backup-<ts>.tar.gz.age + .sha256, prunes snapshots older
# than BACKUP_RETENTION_DAYS. Snapshots are 640 root:vpsbackup so a non-root
# home machine can rsync them off (content is age-encrypted).
# See docs/runbooks/backup-and-restore.md.

set -euo pipefail
# shellcheck source=scripts/maintenance/lib.sh
source "${VPS_MAINT_LIB:-/usr/local/lib/vps-maintenance/lib.sh}"

DRY_RUN=0
NOTIFY=0
usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --notify)  NOTIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

require_root
load_conf

if [[ -z "${AGE_RECIPIENT}" ]]; then
  log_error "AGE_RECIPIENT not set in ${VPS_MAINT_CONF} — generate a key at home (age-keygen) first."
  exit 2
fi
command -v age >/dev/null 2>&1 || { log_error "age not installed — run scripts/setup/01-maintenance.sh"; exit 2; }

# Resolve BACKUP_PATHS to what actually exists; warn about the rest.
existing=()
for p in "${BACKUP_PATHS[@]}"; do
  if [[ -e "${p}" ]]; then
    existing+=("${p}")
  else
    log_warn "Skipping missing backup path: ${p}"
  fi
done
if [[ ${#existing[@]} -eq 0 ]]; then
  log_error "None of the configured BACKUP_PATHS exist — nothing to back up."
  exit 2
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "Dry run — would snapshot the following into ${BACKUP_DIR}:"
  printf '  %s\n' "${existing[@]}"
  exit 0
fi

tmpdir=$(mktemp -d)
chmod 700 "${tmpdir}"
# On any failure: notify (if asked) and clean up the staging dir.
trap 'rc=$?;
  if [[ ${rc} -ne 0 && "${NOTIFY}" -eq 1 ]]; then
    notify critical "vps-backup failed" "vps-backup exited with code ${rc} on $(hostname) — journalctl -u vps-backup";
  fi
  rm -rf "${tmpdir}"' EXIT

install -d -m 750 -o root -g vpsbackup "${BACKUP_DIR}"

ts=$(date +%Y%m%d-%H%M%S)
archive="${tmpdir}/backup.tar.gz"
dest="${BACKUP_DIR}/vps-backup-${ts}.tar.gz.age"

log_info "Creating tar of ${#existing[@]} path(s) …"
tar -czf "${archive}" -C / "${existing[@]#/}"
tar -tzf "${archive}" >/dev/null
log_success "Tar created and verified ($(du -h "${archive}" | cut -f1))"

age -r "${AGE_RECIPIENT}" -o "${dest}" "${archive}"
chown root:vpsbackup "${dest}"
chmod 640 "${dest}"
(cd "${BACKUP_DIR}" && sha256sum "$(basename "${dest}")" > "$(basename "${dest}").sha256")
chown root:vpsbackup "${dest}.sha256"
chmod 640 "${dest}.sha256"
log_success "Encrypted snapshot: ${dest}"

pruned=$(find "${BACKUP_DIR}" -maxdepth 1 -name 'vps-backup-*' \
  -mtime +"${BACKUP_RETENTION_DAYS}" -print -delete | wc -l)
log_info "Pruned ${pruned} file(s) older than ${BACKUP_RETENTION_DAYS} days"

log_success "vps-backup complete"
```

- [ ] **Step 2: Lint + dry-run exercise**

Run: `shellcheck scripts/maintenance/vps-backup.sh && bash -n scripts/maintenance/vps-backup.sh`
Expected: clean.

(Root-only paths make a full dev-machine run impossible; the dry-run path is exercised on the VPS during Task 9 verification.)

- [ ] **Step 3: Commit**

```bash
git add scripts/maintenance/vps-backup.sh
git commit -m "Add vps-backup age-encrypted snapshot command"
```

---

### Task 6: vps-restore

**Files:**
- Create: `scripts/maintenance/vps-restore.sh` (installed as `/usr/local/sbin/vps-restore`)

**Interfaces:**
- Consumes: lib (`backup_file` pattern for pre-overwrite backups), snapshot format from Task 5.
- Produces CLI: `vps-restore [--dry-run] [--identity <age-key-file>] [--yes] <archive>` where archive is `.tar.gz.age` (needs identity) or plain `.tar.gz`. Interactive confirmation requires typing `restore`. Exit 0 restored, 1 usage error, 2 failure.

- [ ] **Step 1: Write the script**

`scripts/maintenance/vps-restore.sh`:

```bash
#!/usr/bin/env bash
# vps-restore — restore files from a vps-backup snapshot.
#
# Usage:
#   vps-restore [--dry-run] [--identity <age-key-file>] [--yes] <archive>
#
# <archive> is either a vps-backup-*.tar.gz.age (requires --identity or
# AGE_IDENTITY_FILE pointing at the age private key, brought from home for
# the occasion) or an already-decrypted .tar.gz. Existing files are backed up
# with a .bak.<timestamp> suffix before being overwritten. --dry-run only
# lists what would happen. See docs/runbooks/backup-and-restore.md and
# docs/runbooks/rebuild-from-scratch.md.

set -euo pipefail
# shellcheck source=scripts/maintenance/lib.sh
source "${VPS_MAINT_LIB:-/usr/local/lib/vps-maintenance/lib.sh}"

DRY_RUN=0
ASSUME_YES=0
IDENTITY="${AGE_IDENTITY_FILE:-}"
ARCHIVE=""

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --yes)      ASSUME_YES=1; shift ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         log_error "Unknown option: $1"; usage; exit 1 ;;
    *)          ARCHIVE="$1"; shift ;;
  esac
done

[[ -n "${ARCHIVE}" ]] || { log_error "No archive given."; usage; exit 1; }
[[ -f "${ARCHIVE}" ]] || { log_error "Archive not found: ${ARCHIVE}"; exit 1; }
require_root

tmpdir=$(mktemp -d)
chmod 700 "${tmpdir}"
trap 'rm -rf "${tmpdir}"' EXIT
tarball="${tmpdir}/backup.tar.gz"

case "${ARCHIVE}" in
  *.age)
    if [[ -z "${IDENTITY}" || ! -f "${IDENTITY}" ]]; then
      log_error "Encrypted archive needs the age private key: --identity <file> (or AGE_IDENTITY_FILE)."
      log_error "The key lives at home — copy it here temporarily, or decrypt at home and pass the .tar.gz."
      exit 1
    fi
    log_info "Decrypting with ${IDENTITY} …"
    age -d -i "${IDENTITY}" -o "${tarball}" "${ARCHIVE}"
    ;;
  *.tar.gz)
    cp "${ARCHIVE}" "${tarball}"
    ;;
  *)
    log_error "Unsupported archive type: ${ARCHIVE} (expected .tar.gz.age or .tar.gz)"
    exit 1
    ;;
esac

mapfile -t members < <(tar -tzf "${tarball}")
log_info "Snapshot contains ${#members[@]} entries."

if [[ "${DRY_RUN}" -eq 1 ]]; then
  for m in "${members[@]}"; do
    if [[ -e "/${m}" && ! -d "/${m}" ]]; then
      echo "would OVERWRITE /${m}"
    elif [[ ! -e "/${m}" ]]; then
      echo "would create   /${m}"
    fi
  done
  log_info "Dry run — nothing changed."
  exit 0
fi

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  log_warn "This overwrites live system files (WireGuard keys, SSH host keys, Caddy state …)."
  read -r -p "Type 'restore' to continue: " answer
  [[ "${answer}" == "restore" ]] || { log_info "Aborted."; exit 1; }
fi

# Back up every regular file we are about to overwrite (one timestamp per run).
ts=$(date +%Y%m%d%H%M%S)
for m in "${members[@]}"; do
  if [[ -f "/${m}" && ! -L "/${m}" ]]; then
    cp --preserve=all "/${m}" "/${m}.bak.${ts}"
  fi
done
log_info "Existing files backed up with suffix .bak.${ts}"

tar -xpzf "${tarball}" -C /
log_success "Snapshot restored."

cat <<'EOF'

  Next steps (see docs/runbooks/backup-and-restore.md):
    systemctl restart ssh          # if SSH host keys were restored
    systemctl restart wg-quick@wg0 # for each restored WireGuard interface
    systemctl restart caddy        # if Caddy state / caddy.env was restored
    vps-health                     # verify everything came back
  If you copied the age private key onto this machine, DELETE it now:
    shred -u <keyfile>
EOF
```

- [ ] **Step 2: Lint**

Run: `shellcheck scripts/maintenance/vps-restore.sh && bash -n scripts/maintenance/vps-restore.sh`
Expected: clean.

- [ ] **Step 3: Round-trip test on the dev machine (non-root paths)**

```bash
tmp=$(mktemp -d) && cd "$tmp" && mkdir -p data && echo hi > data/f.txt
tar -czf snap.tar.gz data
age-keygen -o key.txt 2>/dev/null; rec=$(grep -o 'age1.*' key.txt | head -1)
age -r "$rec" -o snap.tar.gz.age snap.tar.gz
age -d -i key.txt -o roundtrip.tar.gz snap.tar.gz.age && tar -tzf roundtrip.tar.gz
cd - && rm -rf "$tmp"
```
Expected: lists `data/` and `data/f.txt` — confirms the age+tar pipeline the script relies on. (Skip if `age` is not installed locally: `brew install age`.)

- [ ] **Step 4: Commit**

```bash
git add scripts/maintenance/vps-restore.sh
git commit -m "Add vps-restore snapshot restore command"
```

---

### Task 7: vps-audit

**Files:**
- Create: `scripts/maintenance/vps-audit.sh` (installed as `/usr/local/sbin/vps-audit`)

**Interfaces:**
- Consumes: lib (`check_*`, `finish_checks`), conf `REPO_DIR`.
- Produces CLI: `vps-audit [--notify] [--quiet]`; exit 0/1/2. The repo↔system mapping table `CONFIG_MAP` is the single place future services extend.

- [ ] **Step 1: Write the script**

`scripts/maintenance/vps-audit.sh`:

```bash
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
  grep -q '^permitrootlogin no$' <<<"${sshd_t}" \
    && check_ok "sshd: root login disabled" \
    || check_crit "sshd: PermitRootLogin is NOT 'no'"
  grep -q '^passwordauthentication no$' <<<"${sshd_t}" \
    && check_ok "sshd: password auth disabled" \
    || check_crit "sshd: PasswordAuthentication is NOT 'no'"
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
sysctl_src="${REPO_DIR}/config/sysctl/hardening.conf"
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
  [[ "${perms}" == "600 root:root" ]] \
    && check_ok "caddy.env permissions 600 root:root" \
    || check_crit "caddy.env permissions are ${perms} (expected 600 root:root)"
  grep -q '^LLM_KEY_[A-Z0-9_]*=..*' "${caddy_env}" \
    && check_ok "caddy.env contains at least one LLM_KEY_*" \
    || check_crit "caddy.env has no LLM_KEY_* entry — LLM endpoint auth would be broken"
fi

# --- 6. Boot enablement + unattended-upgrades ------------------------------------------
for svc in ssh caddy fail2ban auditd; do
  systemctl is-enabled --quiet "${svc}" \
    && check_ok "${svc} enabled at boot" \
    || check_warn "${svc} NOT enabled at boot"
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
```

- [ ] **Step 2: Lint**

Run: `shellcheck scripts/maintenance/vps-audit.sh && bash -n scripts/maintenance/vps-audit.sh`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/maintenance/vps-audit.sh
git commit -m "Add vps-audit hardening drift audit"
```

---

### Task 8: vps-update

**Files:**
- Create: `scripts/maintenance/vps-update.sh` (installed as `/usr/local/sbin/vps-update`)

**Interfaces:**
- Consumes: `vps-health` (exit codes), `vps-backup` (must succeed before upgrading), lib `notify`.
- Produces CLI: `vps-update [--reboot] [--yes] [--notify]`. Aborts on critical pre-flight health (unless `--yes`) or a failed backup. Exit 0 done, 2 aborted/failed.

- [ ] **Step 1: Write the script**

`scripts/maintenance/vps-update.sh`:

```bash
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
[[ "${health_rc}" -eq 0 ]] && log_success "Pre-flight health OK" \
  || log_warn "Proceeding with health exit code ${health_rc}"

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
  [[ "${post_rc}" -eq 1 ]] && sev=warning
  [[ "${post_rc}" -eq 2 || "${reboot_needed}" == "yes" ]] && sev=warning
  notify "${sev}" "vps-update finished" "${summary}"
fi

if [[ "${reboot_needed}" == "yes" && "${DO_REBOOT}" -eq 1 ]]; then
  shutdown -r +1 "vps-update: rebooting to apply kernel/libc updates"
fi
log_success "vps-update complete"
```

- [ ] **Step 2: Lint**

Run: `shellcheck scripts/maintenance/vps-update.sh && bash -n scripts/maintenance/vps-update.sh`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/maintenance/vps-update.sh
git commit -m "Add vps-update deliberate patch routine"
```

---

### Task 9: systemd units + 01-maintenance.sh deploy script

**Files:**
- Create: `config/maintenance/systemd/vps-health.service`, `vps-health.timer`, `vps-backup.service`, `vps-backup.timer`, `vps-audit.service`, `vps-audit.timer`
- Create: `scripts/setup/01-maintenance.sh`

**Interfaces:**
- Consumes: everything from Tasks 2–8; `common.sh` helpers (`require_root`, `require_debian_supported`, `apt_install`, `backup_file`, logging).
- Produces: installed toolkit (paths per Global Constraints), `vpsbackup` system group, enabled timers `vps-health.timer` / `vps-backup.timer` / `vps-audit.timer`. Re-runnable; `/etc/vps-maintenance.conf` deployed only if absent, with `REPO_DIR` set to the actual clone path on first deploy.

- [ ] **Step 1: Write the six systemd units**

`config/maintenance/systemd/vps-backup.service`:
```ini
# Deployed to /etc/systemd/system/ by scripts/setup/01-maintenance.sh
[Unit]
Description=Encrypted VPS state snapshot (vps-backup)
Documentation=https://github.com/peterekjs/vps/blob/main/docs/runbooks/backup-and-restore.md

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-backup --notify
```

`config/maintenance/systemd/vps-backup.timer`:
```ini
# Deployed to /etc/systemd/system/ by scripts/setup/01-maintenance.sh
[Unit]
Description=Daily encrypted VPS snapshot

[Timer]
OnCalendar=*-*-* 05:30:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
```

`config/maintenance/systemd/vps-health.service`:
```ini
# Deployed to /etc/systemd/system/ by scripts/setup/01-maintenance.sh
[Unit]
Description=VPS health check (vps-health)
Documentation=https://github.com/peterekjs/vps/blob/main/docs/runbooks/health-monitoring.md

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-health --notify --quiet
# vps-health exits 1 on warnings / 2 on critical; the notification is the
# alerting channel, so don't mark the unit failed for warnings.
SuccessExitStatus=1
```

`config/maintenance/systemd/vps-health.timer`:
```ini
# Deployed to /etc/systemd/system/ by scripts/setup/01-maintenance.sh
[Unit]
Description=Daily VPS health check

[Timer]
OnCalendar=*-*-* 07:00:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
```

`config/maintenance/systemd/vps-audit.service`:
```ini
# Deployed to /etc/systemd/system/ by scripts/setup/01-maintenance.sh
[Unit]
Description=Hardening drift audit (vps-audit)
Documentation=https://github.com/peterekjs/vps/blob/main/docs/runbooks/drift-audit.md

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-audit --notify --quiet
SuccessExitStatus=1
```

`config/maintenance/systemd/vps-audit.timer`:
```ini
# Deployed to /etc/systemd/system/ by scripts/setup/01-maintenance.sh
[Unit]
Description=Weekly hardening drift audit

[Timer]
OnCalendar=Sun *-*-* 07:30:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 2: Write the deploy script**

`scripts/setup/01-maintenance.sh`:

```bash
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
  log_warn "EDIT ${CONF_DEST}: set HA_WEBHOOK_URL and AGE_RECIPIENT before relying on backups/alerts"
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
    2. Create the Home Assistant webhook automation
       (docs/runbooks/health-monitoring.md) and set HA_WEBHOOK_URL
    3. Test the channel:                   vps-notify --title Test "hello from \$(hostname)"
    4. First snapshot + health pass:       vps-backup && vps-health
    5. Allow your SSH user to pull backups: usermod -aG vpsbackup <user>
       then from home: scripts/home/pull-backups.sh <user>@<vps>

EOF
```

- [ ] **Step 3: Lint**

Run: `shellcheck scripts/setup/01-maintenance.sh && bash -n scripts/setup/01-maintenance.sh`
Expected: clean.

- [ ] **Step 4: Verify on the VPS (deploy + exercise)**

On the VPS (after `git pull`):
```bash
sudo bash scripts/setup/01-maintenance.sh          # full deploy
sudo bash scripts/setup/01-maintenance.sh          # idempotency: conf untouched, no errors
sudo vps-backup --dry-run                          # lists BACKUP_PATHS
sudo vps-health; echo "rc=$?"                      # report + rc in {0,1}
sudo vps-audit;  echo "rc=$?"                      # everything freshly deployed → mostly in sync
systemctl list-timers 'vps-*'                      # three timers scheduled
```
Expected: no failures; `vps-audit` flags at most the conf placeholders you haven't filled yet.

- [ ] **Step 5: Commit**

```bash
git add config/maintenance/systemd scripts/setup/01-maintenance.sh
git commit -m "Add 01-maintenance.sh deploy script and systemd timers"
```

---

### Task 10: Home-side pull script

**Files:**
- Create: `scripts/home/pull-backups.sh`

**Interfaces:**
- Consumes: snapshot layout from Task 5 (`/var/backups/vps`, group-readable), SSH access to the VPS.
- Produces CLI (home machine, non-root): `pull-backups.sh [user@]host [dest-dir]` (dest default `~/Backups/vps`).

- [ ] **Step 1: Write the script**

`scripts/home/pull-backups.sh`:

```bash
#!/usr/bin/env bash
# pull-backups.sh — mirror the VPS's encrypted snapshots to this machine.
#
# Usage:
#   scripts/home/pull-backups.sh [user@]host [dest-dir]
#
# Runs on a HOME machine (macOS or Linux) — deliberately no root or Debian
# guard. Requires ssh+rsync and that the remote user is in the vpsbackup
# group. No --delete: local copies intentionally outlive the VPS's retention
# window, they are your disaster-recovery history. Schedule via cron/launchd
# if wanted — see docs/runbooks/backup-and-restore.md.

set -euo pipefail

HOST="${1:?Usage: pull-backups.sh [user@]host [dest-dir]}"
DEST="${2:-${HOME}/Backups/vps}"
REMOTE_DIR="/var/backups/vps"

mkdir -p "${DEST}"
rsync -avz --itemize-changes "${HOST}:${REMOTE_DIR}/" "${DEST}/"

echo
echo "Local snapshots (newest first):"
ls -1t "${DEST}" | grep '\.age$' | head -5
newest="$(ls -1t "${DEST}" | grep '\.age$' | head -1 || true)"
if [[ -n "${newest}" && -f "${DEST}/${newest}.sha256" ]]; then
  (cd "${DEST}" && shasum -a 256 -c "${newest}.sha256" 2>/dev/null \
    || sha256sum -c "${newest}.sha256")
fi
```

- [ ] **Step 2: Lint**

Run: `shellcheck scripts/home/pull-backups.sh && bash -n scripts/home/pull-backups.sh`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/home/pull-backups.sh
git commit -m "Add home-side backup pull script"
```

---

### Task 11: Runbooks — core operations

**Files:**
- Create: `docs/runbooks/health-monitoring.md`, `docs/runbooks/backup-and-restore.md`, `docs/runbooks/drift-audit.md`, `docs/runbooks/updates-and-patching.md`

**Interfaces:**
- Consumes: exact CLI/flags/exit codes from Tasks 3–8, conf variables from Task 2, timer cadences from Task 9.
- Produces: four runbooks following the skeleton **When to use → Prerequisites → Steps → Verify → Rollback/Recovery**. Every command copy-pasteable; every conf variable referenced by exact name.

- [ ] **Step 1: Write health-monitoring.md**

Content requirements (write full prose around these):
- *When to use:* daily automatic run; manually after any change or alert.
- *Prerequisites:* toolkit installed (`01-maintenance.sh`), conf filled in.
- *Steps:* `sudo vps-health` (verbose) / `sudo vps-health --quiet`; a table of every check (mirroring the seven check groups in `vps-health.sh`) with meaning and the conf variable that tunes it (`DISK_WARN_PCT`, `DISK_CRIT_PCT`, `MEM_AVAILABLE_MIN_MB`, `CERT_WARN_DAYS`, `WG_CRITICAL_PEERS`, `WG_HANDSHAKE_MAX_AGE`, `BACKUP_MAX_AGE_HOURS`); exit codes 0/1/2.
- *Setting up the HA webhook* (this section is referenced by other runbooks): in Home Assistant create Settings → Automations → new automation with a **Webhook** trigger (id e.g. `vps-maintenance`, method POST, only accessible from local network — WG traffic is local to HA), action = mobile notification using `{{ trigger.json.title }}` / `{{ trigger.json.message }}` / `{{ trigger.json.severity }}`; put `http://<HA-address>:8123/api/webhook/vps-maintenance` into `HA_WEBHOOK_URL`; test with `sudo vps-notify --title Test "hello"`.
- *Verify:* `systemctl list-timers 'vps-*'`, `journalctl -u vps-health -n 50`.
- *Rollback/Recovery:* symptom → runbook table (cert warnings → this file's cert section + `journalctl -u caddy`; WG handshake critical → check home router/peer; backup stale → backup-and-restore.md).

- [ ] **Step 2: Write backup-and-restore.md**

Content requirements:
- *When to use:* automatic daily snapshots; manual before risky changes; restore after data loss / on rebuild.
- *Prerequisites:* `AGE_RECIPIENT` set; age key pair generated **at home** (`age-keygen -o vps-backup.key`), private key in password manager + one offline copy; SSH user in `vpsbackup` group.
- *Steps — backing up:* `sudo vps-backup` (or `--dry-run`); what's inside a snapshot (list `BACKUP_PATHS` and *why* each — identity & secrets, not repo-reproducible config); extending `BACKUP_PATHS` when a new service appears.
- *Steps — pulling to home:* `scripts/home/pull-backups.sh jiri@37.205.10.203` (or over WG `jiri@10.9.0.1`); scheduling example (launchd/cron line); note no `--delete` and why.
- *Steps — restoring:* single file (`sudo vps-restore --dry-run <snap>` then full restore; or extract one path: `age -d -i key.txt -o - snap.age | tar -xzf - -C / etc/wireguard/wg0.conf` style example); full restore with `--identity`; the post-restore service restarts printed by the script; **delete the private key from the VPS afterwards** (`shred -u`).
- *Verify:* checksum verification (`sha256sum -c`), a periodic **restore drill**: decrypt the newest pulled snapshot at home and `tar -tzf` it.
- *Rollback:* every overwritten file has a `.bak.<timestamp>` sibling; how to revert.

- [ ] **Step 3: Write drift-audit.md**

Content requirements:
- *When to use:* weekly automatic; manually after any hands-on change to the VPS.
- *Prerequisites:* `REPO_DIR` in conf pointing at an up-to-date clone (`git -C $REPO_DIR pull`).
- *Steps:* `sudo vps-audit`; explanation of each check group (config diffs via `CONFIG_MAP`, toolkit copies, `sshd -T`, UFW expected/unexpected rules, sysctl, caddy.env guards, boot enablement, jails).
- *Resolving drift — the core decision:* (a) the live change is wanted → port it into the repo (`config/...`), commit, redeploy via the owning setup script; (b) the live change is unwanted/unknown → redeploy from the repo (`00-security-hardening.sh` / `21-caddy.sh` / `01-maintenance.sh`) and investigate how it got there (check `auditd` logs, `~/.bash_history`).
- *Extending:* new service = one `CONFIG_MAP` line in `vps-audit.sh` (+ redeploy).
- *Verify:* re-run `sudo vps-audit` → exit 0.
- *Rollback/Recovery:* if redeploying sshd/UFW config, keep the current SSH session open and verify a second login works (lockout warning, link lockout-recovery.md).

- [ ] **Step 4: Write updates-and-patching.md**

Content requirements:
- *When to use:* monthly, or when `vps-health` warns about reboot-required / pending updates. Clarify division of labour: unattended-upgrades = daily security patches (automatic); `vps-update` = everything else (deliberate).
- *Prerequisites:* recent backup pull at home (in case an upgrade goes sideways).
- *Steps:* `sudo vps-update` (review output, reboot later) or `sudo vps-update --reboot`; what each phase does (pre-flight health, snapshot, full-upgrade, reboot check, post-flight); `--yes` semantics; checking what unattended-upgrades did lately: `journalctl -u apt-daily-upgrade`, `/var/log/unattended-upgrades/`.
- *Verify:* `sudo vps-health` after reboot; `uname -r` shows the new kernel; all timers still scheduled.
- *Rollback/Recovery:* apt has no transactional rollback — recovery = the pre-update snapshot (config/identity) + provider console if boot fails (link lockout-recovery.md and rebuild-from-scratch.md).

- [ ] **Step 5: Commit**

```bash
git add docs/runbooks/health-monitoring.md docs/runbooks/backup-and-restore.md \
        docs/runbooks/drift-audit.md docs/runbooks/updates-and-patching.md
git commit -m "Add core-operations runbooks"
```

---

### Task 12: Runbooks — disaster recovery & future-proofing

**Files:**
- Create: `docs/runbooks/rebuild-from-scratch.md`, `docs/runbooks/debian-release-upgrade.md`, `docs/runbooks/provider-or-ip-migration.md`, `docs/runbooks/lockout-recovery.md`

**Interfaces:**
- Consumes: restore CLI from Task 6, deploy scripts `00-security-hardening.sh`/`21-caddy.sh`/`01-maintenance.sh`, `SUPPORTED_CODENAMES` from Task 1, WG state layout from README.

- [ ] **Step 1: Write rebuild-from-scratch.md** (the DR guarantee — most important runbook)

Content requirements — an ordered, end-to-end procedure:
1. *When to use / Prerequisites:* dead VPS or fresh provider box; needs: newest pulled snapshot (home), age private key (home), SSH pubkey, this repo.
2. Provision fresh Debian VPS (matching the supported codename in `scripts/utils/common.sh`), add your SSH key to root or the default user.
3. `git clone https://github.com/peterekjs/vps.git && cd vps`.
4. `sudo bash scripts/setup/00-security-hardening.sh` — **verify key-based SSH login in a second session before continuing** (password auth is now off).
5. Upload snapshot + key: `scp vps-backup-<ts>.tar.gz.age vps-backup.key <host>:` (over the new IP).
6. `sudo bash scripts/setup/01-maintenance.sh` (installs `vps-restore` + age).
7. `sudo vps-restore --identity vps-backup.key vps-backup-<ts>.tar.gz.age` → restores WG identity, SSH host keys, Caddy/ACME state, caddy.env, conf. Then `shred -u vps-backup.key`.
8. `sudo systemctl restart ssh` (host identity back — clients stop warning); `sudo bash scripts/setup/21-caddy.sh`; `sudo systemctl restart wg-quick@wg0` (or re-run `scripts/wireguard/init.sh` guidance if the unit isn't enabled yet — restored `/etc/wireguard/wg0.conf` + `systemctl enable --now wg-quick@wg0`).
9. If the IP changed → continue with provider-or-ip-migration.md (DNS + peer endpoints).
10. *Verify:* `sudo vps-health` exit 0; `wg show` handshake from HOME; `curl -I https://home.peterek.net`; from home, SSH host-key fingerprint matches the old one.
11. *Rollback:* none needed — the old box is gone; if restore fails, snapshots older than the newest are still at home.

- [ ] **Step 2: Write debian-release-upgrade.md**

Content requirements:
- *When to use:* new stable Debian release (bookworm → trixie), no rush — oldstable gets ~1 year of support after a release.
- *Prerequisites:* fresh snapshot pulled home; `vps-health` + `vps-audit` clean; ~2 GB free; provider console access ready (link lockout-recovery.md).
- *Steps:* full current-release patch (`sudo vps-update`); edit `/etc/apt/sources.list` (+ `/etc/apt/sources.list.d/*.list`, including caddy list — it uses `any-version`, no change needed) replacing `bookworm` with the new codename; `apt update && apt upgrade --without-new-pkgs -y && apt full-upgrade -y` (two-stage per Debian release notes — always check the official notes for release-specific steps); reboot; **temporarily** the OS guard blocks re-runs — add the new codename to `SUPPORTED_CODENAMES` in `scripts/utils/common.sh` *after* the next step passes.
- *Post-upgrade re-validation:* `sudo vps-health`, `sudo vps-audit`, `sshd -t`, `sudo ufw status`, spot-check fail2ban regexes still match (`fail2ban-client status sshd`), `journalctl -u caddy` — then commit the `SUPPORTED_CODENAMES` change and update the README requirement line.
- *Verify / Rollback:* verify = both check commands exit 0 on the new release; rollback = no in-place downgrade exists — restore path is rebuild-from-scratch.md on a bookworm image, which is why the snapshot comes first.

- [ ] **Step 3: Write provider-or-ip-migration.md**

Content requirements:
- *When to use:* moving providers, or the VPS gets a new public IP.
- *Prerequisites:* rebuild-from-scratch.md completed on the new box (if migrating), or just the new IP known (if in-place).
- *Steps:* update DNS A records for `home.peterek.net`, `agent.peterek.net`, `llm.peterek.net` (grey-cloud/DNS-only, per ADR 0001) to the new IP; keep TTL low (300) during migration; update every WG peer's `Endpoint = <new-ip>:51830` (peers connect *to* the VPS — list where each peer's config lives: STUDIO, HOME router/UniFi, phones via re-issued QR from `scripts/wireguard/info.sh <peer> --qr`); certs: HTTP-01 re-issues automatically once DNS points at the new box (`journalctl -u caddy -f`); update the endpoint recorded in `/etc/wireguard/<name>.d/server/endpoint`; run old+new in parallel during DNS propagation, then decommission.
- *Verify:* `dig +short` each hostname → new IP; `wg show` handshakes from all critical peers; `curl -I https://…` all three hosts; `sudo vps-health` exit 0.
- *Rollback:* DNS back to the old IP (old box still running), peers' endpoints back.

- [ ] **Step 4: Write lockout-recovery.md**

Content requirements:
- *When to use:* can't SSH in.
- Diagnosis order with exact commands run **from home**: is it the network (`ping`), the port (`nc -zv <ip> 22`), a fail2ban self-ban (try from a second IP / phone hotspot), or auth (`ssh -v` output meaning).
- *fail2ban self-ban:* log in from another IP (or console) → `sudo fail2ban-client status sshd`, `sudo fail2ban-client set sshd unbanip <ip>`.
- *Key loss / auth failure:* provider console (VNC/serial) → log in locally → fix `~/.ssh/authorized_keys`; note root password login on console still works even though SSH password auth is off (PAM console ≠ sshd) — if no root password was ever set, use the provider's rescue mode / password reset.
- *Firewall mistake:* console → `sudo ufw status numbered`, re-allow SSH (`sudo ufw allow 22/tcp`), or `sudo ufw disable` temporarily.
- *sshd config broken:* console → `sudo sshd -t` shows the error; restore the newest `/etc/ssh/sshd_config.bak.*` (created by every deploy) and `sudo systemctl restart ssh`.
- *Prevention:* the "verify in a second session" habit; keeping provider console credentials somewhere that is NOT behind the VPN.

- [ ] **Step 5: Commit**

```bash
git add docs/runbooks/rebuild-from-scratch.md docs/runbooks/debian-release-upgrade.md \
        docs/runbooks/provider-or-ip-migration.md docs/runbooks/lockout-recovery.md
git commit -m "Add disaster-recovery and future-proofing runbooks"
```

---

### Task 13: Runbook index, add-a-service, README + CLAUDE.md

**Files:**
- Create: `docs/runbooks/README.md`, `docs/runbooks/add-a-service.md`
- Modify: `README.md` (add Maintenance section after the Caddy section; add new paths to the structure tree)
- Modify: `CLAUDE.md` (new directories, runbook convention, maintenance commands)

**Interfaces:**
- Consumes: all nine runbooks, all commands, timer table, numbering convention from CLAUDE.md.

- [ ] **Step 1: Write docs/runbooks/README.md**

Content requirements:
- One-page mental model: repo = configuration (reproducible), snapshots = identity & secrets (age-encrypted, pulled home), timers watch health/drift/backups and page via HA, `vps-update` is the only manual routine.
- Symptom → runbook table (got an HA alert about X / can't SSH / new Debian released / adding a service / VPS died / moving provider → file).
- The runbook skeleton, stated as the convention for new runbooks.

- [ ] **Step 2: Write docs/runbooks/add-a-service.md**

Content requirements:
- *When to use:* exposing a new backend through Caddy and/or adding a WG peer.
- *Steps — new proxied service:* backend reachable over WG first (`curl` from VPS); add DNS A record (grey-cloud); add site block to `config/caddy/Caddyfile`; **decision point:** backend has own auth (plain `reverse_proxy`, like agent) vs no auth (edge-auth pattern from ADR 0002: `{$KEY}` placeholders + path allowlist + fail2ban jail, like llm); redeploy `sudo bash scripts/setup/21-caddy.sh`; extend `CONFIG_MAP` in `scripts/maintenance/vps-audit.sh` for any new deployed file; extend `BACKUP_PATHS` in `/etc/vps-maintenance.conf` (and the repo template) for any new machine-specific state; add a runbook if the service brings a new operational workflow.
- *Steps — new WG peer:* `sudo bash scripts/wireguard/add-peer.sh`; add to `WG_CRITICAL_PEERS` only if the VPS depends on it.
- *Steps — new setup script:* numbering rules (recap of CLAUDE.md: category ranges, `N0` reserved, lowest free ≥ N1).
- *Verify:* `curl -I https://<new-host>`, `sudo vps-audit` exit 0 (proves CONFIG_MAP was extended), `sudo vps-backup --dry-run` shows new state.
- *Rollback:* remove the site block, redeploy 21-caddy.sh, remove DNS record.

- [ ] **Step 3: Update README.md**

- In the structure tree add: `scripts/setup/01-maintenance.sh`, `scripts/maintenance/` (one line per command), `scripts/home/pull-backups.sh`, `config/maintenance/`, `docs/runbooks/`.
- New `## Maintenance` section after the Caddy section containing: install command (`sudo bash scripts/setup/01-maintenance.sh`), first-install checklist (age-keygen at home → AGE_RECIPIENT; HA webhook → HA_WEBHOOK_URL; `usermod -aG vpsbackup`), command table (command → what it does → runbook link, six rows), timer table (unit → cadence → what pages you), and the "after `git pull`, re-run `01-maintenance.sh` to redeploy" upgrade note.

- [ ] **Step 4: Update CLAUDE.md**

- In the architecture section: add `scripts/maintenance/` (deployed to `/usr/local/sbin`, self-contained lib, `VPS_MAINT_LIB` override), `config/maintenance/`, `scripts/home/` (no root/OS guards — home machines).
- Commands section: add `shellcheck scripts/maintenance/*.sh scripts/home/*.sh` to the lint line; add `sudo bash scripts/setup/01-maintenance.sh`.
- New convention bullets: runbooks live in `docs/runbooks/` and follow the skeleton (name it); **any new operational workflow ships with a runbook**; new deployed config ⇒ extend `CONFIG_MAP` in `vps-audit.sh`; new machine-specific state ⇒ extend `BACKUP_PATHS` (template + live conf); check-command exit convention 0/1/2; the OS guard is `require_debian_supported` / `SUPPORTED_CODENAMES`.

- [ ] **Step 5: Full lint + docs cross-check**

Run: `shellcheck scripts/setup/*.sh scripts/utils/*.sh scripts/maintenance/*.sh scripts/home/*.sh scripts/wireguard/*.sh`
Expected: clean.
Cross-check: every runbook referenced from code comments/summaries exists (`grep -rn 'docs/runbooks/' scripts/ config/ | awk -F'docs/runbooks/' '{print $2}'` — each named file present in `docs/runbooks/`).

- [ ] **Step 6: Commit**

```bash
git add docs/runbooks/README.md docs/runbooks/add-a-service.md README.md CLAUDE.md
git commit -m "Add runbook index and add-a-service guide; document maintenance in README and CLAUDE.md"
```

---

## Self-Review (performed while writing)

- **Spec coverage:** all six commands (T3–T8), conf + lib (T2), installed-toolkit deploy + timers + `SuccessExitStatus` nuance (T9), pull-from-home (T10), all ten runbooks (T11–T13), OS-guard future-proofing (T1), README/CLAUDE.md (T13), caddy.env in backups + audit guards (T2/T5/T7). No spec section without a task.
- **Deviation from spec (deliberate):** snapshot modes are `640 root:vpsbackup` (dir `750`), not root-only — a non-root home user must be able to rsync them, and content is age-encrypted; the spec's trust model is preserved (VPS holds no foreign credentials). Recorded in Global Constraints.
- **Type consistency:** conf variable names, lib function signatures (`finish_checks "<title>" <0|1>`, `notify <sev> <title> <msg>`), CLI flags, exit codes, and file paths verified identical across tasks. `vps-health.timer` runs `--notify --quiet` matching T4's flags; T7's `CONFIG_MAP` covers exactly the six unit files created in T9.
- **Placeholder scan:** every code step contains complete file content; runbook steps specify concrete content and exact commands rather than "document X".
