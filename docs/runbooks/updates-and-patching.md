# Updates & patching

## When to use

- Roughly **monthly**, or when `vps-health` warns about *reboot required* or
  a growing pending-updates count.

**Division of labour:** `unattended-upgrades` (installed by
`00-security-hardening.sh`) applies **security** patches automatically every
day — you don't act on those. `vps-update` is the deliberate routine for
everything else: kernel point releases, Caddy/WireGuard/fail2ban package
updates, and the reboot decision. A full-upgrade with a possible reboot
should never happen unattended, which is why `vps-update` has **no timer**.

## Prerequisites

- A recent snapshot pulled home (`scripts/home/pull-backups.sh …`) — if an
  upgrade goes sideways, that plus the repo is your way back.

## Steps

```bash
sudo vps-update            # upgrade now, reboot later yourself if needed
sudo vps-update --reboot   # upgrade and auto-reboot (1-min delay) if required
```

What each phase does:

1. **Pre-flight** — runs `vps-health --quiet`; **aborts on critical findings**
   (override with `--yes` if the critical finding is the very thing the
   update fixes) and requires ≥ 1 GB free on `/`.
2. **Snapshot** — a fresh `vps-backup`; a failed backup aborts the update.
3. **Upgrade** — `apt-get update`, `full-upgrade`, `autoremove`, `autoclean`.
4. **Reboot check** — reports `/var/run/reboot-required`; with `--reboot`
   schedules `shutdown -r +1` (cancel window: `shutdown -c`).
5. **Post-flight** — `vps-health` again; with `--notify` a summary lands in
   Home Assistant.

Curious what unattended-upgrades has been doing meanwhile?

```bash
journalctl -u apt-daily-upgrade.service -n 50
ls -lt /var/log/unattended-upgrades/ | head
```

## Verify

```bash
sudo vps-health; echo "rc=$?"     # 0 after the dust settles
uname -r                          # new kernel actually running (after reboot)
systemctl list-timers 'vps-*'     # timers survived the reboot
```

## Rollback / Recovery

apt has no transactional rollback. Recovery paths, in order of severity:

- A package misbehaves → pin/downgrade that package
  (`apt-get install <pkg>=<version>`, versions via `apt-cache policy <pkg>`).
- Config/state damaged → restore from the pre-update snapshot
  ([backup-and-restore.md](backup-and-restore.md)); every deploy script also
  leaves `*.bak.<ts>` files.
- Box won't boot after a kernel update → provider console, select the
  previous kernel in GRUB ([lockout-recovery.md](lockout-recovery.md)); worst
  case [rebuild-from-scratch.md](rebuild-from-scratch.md).
