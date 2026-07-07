# VPS Maintenance Toolkit & Runbooks — Design

**Date:** 2026-07-07
**Status:** Approved

## Goal

Extend this repo beyond initial setup: add maintenance/utility scripts covering
health monitoring, backup & restore, hardening-drift auditing, and a controlled
update routine — plus runbooks documenting every operational workflow so future
changes have written guidance. The VPS is a security-sensitive single host
(public TLS edge + WireGuard endpoint for the home network).

## Scope decisions (from brainstorming)

- **Scenarios:** health check, backup & restore, drift audit, update routine — all in scope.
- **Backup destination:** encrypted local snapshots on the VPS, **pulled from home over WireGuard**. The VPS holds no credentials to any other system.
- **Alerting:** daily/weekly systemd timers; findings notify via a **Home Assistant webhook** over WireGuard. On-demand runs always work.
- **Future-proofing:** Debian release-upgrade runbook, rebuild-from-scratch (DR) runbook, new-service checklist, provider/IP migration runbook.
- **Architecture:** **installed toolkit** — a numbered setup script deploys maintenance scripts to `/usr/local/sbin/vps-*`, systemd units to `/etc/systemd/system`, and a config template to `/etc/vps-maintenance.conf`. This matches the repo's existing "canonical files in repo, deployed by idempotent setup script" pattern. The drift audit verifies installed copies match the repo, so the deploy-copy risk polices itself.
  - Rejected: running timers directly out of the git clone (clone path becomes load-bearing); single `vps` multiplexer command (monolith, against the repo's one-script-per-concern grain).

## New files

```
scripts/setup/01-maintenance.sh      # deploys everything below (idempotent, 0x range)
scripts/maintenance/
  lib.sh          → /usr/local/lib/vps-maintenance/lib.sh
  vps-health.sh   → /usr/local/sbin/vps-health
  vps-backup.sh   → /usr/local/sbin/vps-backup
  vps-restore.sh  → /usr/local/sbin/vps-restore
  vps-audit.sh    → /usr/local/sbin/vps-audit
  vps-update.sh   → /usr/local/sbin/vps-update
  vps-notify.sh   → /usr/local/sbin/vps-notify
scripts/home/pull-backups.sh         # runs on a home machine (no root/Bookworm guard)
config/maintenance/
  vps-maintenance.conf               # template → /etc/vps-maintenance.conf (only if absent)
  systemd/vps-health.service  vps-health.timer
  systemd/vps-audit.service   vps-audit.timer
  systemd/vps-backup.service  vps-backup.timer
docs/runbooks/                       # see Documentation section
```

Deployment strips the `.sh` extension for the `sbin` commands. Sources keep it
for shellcheck globbing.

## Components

All installed scripts source `/usr/local/lib/vps-maintenance/lib.sh` (logging
helpers mirroring `common.sh`, conf loading, notify wrapper). All use
`set -euo pipefail` and are shellcheck-clean. Exit-code convention:
**0 = ok, 1 = warnings, 2 = critical**.

### vps-health
One-shot health report:
- systemd units active: `ssh`, `caddy`, `fail2ban`, `auditd`, every `wg-quick@*`
- disk / memory / load against thresholds from conf
- TLS cert expiry per hostname parsed from `/etc/caddy/Caddyfile`
  (`openssl s_client` against localhost with SNI). **Warn under 14 days** —
  Let's Encrypt renews at 30, so <14 means renewal is broken.
- WireGuard handshake age for critical peers (`WG_CRITICAL_PEERS` in conf, e.g. HOME)
- pending apt updates count; `/var/run/reboot-required` flag
- fail2ban per-jail status + ban counts for all configured jails
  (currently `sshd` and `caddy-llm`; discovered via `fail2ban-client status`,
  not hard-coded)
- age of newest snapshot in the backup dir (warn above threshold)

`--notify` (used by the timer) pushes issues to Home Assistant; quiet on success.

### vps-backup
Backs up **only state not reproducible from this repo** (backup = identity &
state; repo = configuration):
- `/etc/wireguard/` (server + peer keys/configs)
- `/etc/ssh/ssh_host_*` (server identity — peers' known_hosts stay valid after rebuild)
- `/var/lib/caddy/` (certs + ACME account state — avoids rate limits/downtime on rebuild)
- `/etc/caddy/caddy.env` (per-client LLM API keys — generated once by
  `21-caddy.sh`, never in git; losing it means re-issuing every client key)
- `/etc/vps-maintenance.conf`
- `/root/.ssh/authorized_keys` (template default; the conf documents adding
  per-user paths — the repo defines no admin user, so this stays per-machine)

Path list lives in the conf (`BACKUP_PATHS`), so it's extensible. Flow: tar →
verify tar readability → encrypt with `age` to `AGE_RECIPIENT` (public key;
private key never touches the VPS) → write
`/var/backups/vps/vps-backup-<timestamp>.tar.gz.age` + SHA-256 checksum file →
prune beyond `BACKUP_RETENTION_DAYS`. `--dry-run` lists what would be captured.

### vps-restore
Inverse of backup. Accepts an `.age` file (age identity supplied at restore
time via flag/env) or a plain `.tar.gz` (decrypted at home). `--dry-run` lists
what would be overwritten; real runs back up current files first
(`backup_file` pattern) and require confirmation.

### vps-audit
Hardening drift detection:
- diff deployed configs vs repo clone (`REPO_DIR` from conf), driven by a
  single mapping table in the script (repo path → system path) so new
  services extend it in one place. Initial set: sshd_config, fail2ban
  jail.local + filter.d/caddy-llm.conf + jail.d/caddy-llm.local, sysctl
  hardening.conf, Caddyfile, 50unattended-upgrades, the caddy systemd
  drop-in (caddy.service.d/env.conf)
- `/etc/caddy/caddy.env`: exists, mode 600 root:root, contains at least one
  `LLM_KEY_*` entry (presence/permissions only — content is secret and has
  no repo counterpart). Guards the fail-closed edge-auth design of ADR 0002.
- fail2ban: both jails (`sshd`, `caddy-llm`) enabled and running
- `sshd -T` effective values: `permitrootlogin no`, `passwordauthentication no`, port
- UFW: active + expected rule set, derived from live sources of truth —
  SSH port from `sshd -T`, 80/443 because Caddy is deployed, WG listen port(s)
  from `/etc/wireguard/*.conf`
- sysctl live values match `hardening.conf`
- services enabled at boot; unattended-upgrades periodic config present
- installed `/usr/local/sbin/vps-*` and lib match the repo copies

If `REPO_DIR` is missing, file-diff checks are skipped with a warning (other
checks still run). Exit code + notify on drift.

### vps-update
Deliberate (manual, roughly monthly) patch routine — unattended-upgrades keeps
handling daily security patches automatically:
1. pre-flight: health pass, disk-space check
2. fresh `vps-backup`
3. `apt update && apt full-upgrade && apt autoremove`
4. reboot-required detection; `--reboot` actually reboots (after notifying), default only reports
5. post-flight health check; notify summary

No timer — a full-upgrade with possible reboot must not happen unattended.

### vps-notify
Thin `curl` POST of JSON (`title`, `message`, `severity`, `host`) to
`HA_WEBHOOK_URL` (Home Assistant webhook reached over WireGuard). Used by the
other scripts; standalone for testing the channel. Notification failure logs a
warning and **never** fails the caller. If the tunnel itself is down, the daily
notification rhythm means silence is the signal.

### Configuration — /etc/vps-maintenance.conf
Machine-specific values, deployed from template **only if absent** (never
clobbered): `HA_WEBHOOK_URL`, `AGE_RECIPIENT`, `REPO_DIR`, `BACKUP_DIR`,
`BACKUP_PATHS`, `BACKUP_RETENTION_DAYS`, `WG_CRITICAL_PEERS`, disk/handshake/
backup-age thresholds. Included in backups. The repo template ships
placeholders + comments (repo is public — no real webhook ID or keys in git).

## Backup trust model

- `age` public-key encryption: a compromised VPS cannot read historical backups.
- Private key lives at home (password manager + one offline copy). Runbook
  covers generating the pair and storing it.
- Home pulls; the VPS has no credentials into the home network (trust flows
  the same direction as always: home → VPS over SSH/WG).
- `scripts/home/pull-backups.sh`: ssh+rsync mirror of `/var/backups/vps/` to a
  local dir. Documented alongside the raw one-liner and optional
  launchd/cron scheduling.
- DR guarantee: repo + newest pulled snapshot + age private key → full rebuild
  with the same WireGuard identity and SSH host keys.

## Scheduling

systemd timers (journald logging, `Persistent=true` to catch missed runs):

| Timer | Cadence | Behaviour |
|---|---|---|
| vps-backup | daily 05:30 | snapshot + prune; notify on failure |
| vps-health | daily 07:00 | notify failing checks |
| vps-audit | weekly Sun 07:30 | notify drift summary |

`RandomizedDelaySec` on each to avoid thundering-herd exactness.

## Documentation

`docs/runbooks/`, one file per workflow, all following the same skeleton:
**When to use → Prerequisites → Steps (copy-pasteable) → Verify → Rollback/Recovery.**

| Runbook | Covers |
|---|---|
| README.md | Index (symptom → runbook); the maintenance model on one page |
| health-monitoring.md | Reading vps-health, meaning of each check, tuning thresholds |
| backup-and-restore.md | Snapshot flow, pulling to home, restore (single file & full), age key handling, LLM key file (`caddy.env`) |
| rebuild-from-scratch.md | Fresh VPS → hardened, restored, identical server (end-to-end DR) |
| drift-audit.md | Running/reading vps-audit; resolving drift (adopt into repo vs revert) |
| updates-and-patching.md | Monthly vps-update routine, reboots, what unattended-upgrades already covers |
| debian-release-upgrade.md | Bookworm → Trixie: pre-checks, upgrade, re-validate hardening, update OS guard |
| add-a-service.md | New proxied service / WG peer: files to touch, numbering, verification; edge-auth pattern (ADR 0002) when the backend has no auth of its own |
| provider-or-ip-migration.md | New VPS/IP: DNS cutover, WG endpoint updates on peers, cert re-issuance |
| lockout-recovery.md | SSH lockout paths: provider console, fail2ban self-ban, key loss |

Repo docs updated: README gains a Maintenance section (command table, timers,
runbook links); CLAUDE.md gains the new directories, the runbook skeleton
convention, and the rule that new workflows ship with a runbook.

The HA-side automation (webhook → phone notification) is documented in the
runbook but not managed by this repo (same stance as the Home Assistant
`trusted_proxies` note).

## Future-proofing the OS guard

`require_debian_bookworm` in `common.sh` is refactored to
`require_debian_supported` checking `SUPPORTED_CODENAMES` (initially
`bookworm` only). The release-upgrade runbook instructs adding `trixie` after
a validated upgrade — a one-line change. Existing call sites migrate to the
new name.

## Error handling

- `set -euo pipefail` everywhere; timer runs rely on exit codes + `--notify`.
- Destructive paths (`vps-restore`, `vps-update --reboot`) require
  confirmation and offer `--dry-run`.
- Every overwrite of a system file goes through the `backup_file` pattern.
- Notify failures degrade to journald warnings, never abort the caller.

## Validation

No test framework exists in-repo and none is introduced. Validation is:
- `shellcheck` + `bash -n` on all scripts (dev machine, before commit)
- each runbook's **Verify** section doubles as the manual test procedure
- re-running `01-maintenance.sh` is the deploy test (idempotent)
- `--dry-run` on backup/restore lets DR be rehearsed without touching state

## Dependencies added on the VPS

`age` (apt package, Bookworm has it), `openssl` + `curl` (already present).
No jq, no restic, no external services.
