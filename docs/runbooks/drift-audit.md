# Hardening drift audit

## When to use

- Automatically: `vps-audit.timer` runs Sundays ~07:30 and pages on drift.
- Manually: after **any** hands-on change to the VPS, and after every
  `git pull` + redeploy.

## Prerequisites

- `REPO_DIR` in `/etc/vps-maintenance.conf` points at this repo's clone on
  the VPS, and that clone is current:

  ```bash
  sudo git -C "$(. /etc/vps-maintenance.conf && echo "$REPO_DIR")" pull
  ```

  (An outdated clone makes the audit compare against stale expectations.)

## Steps

```bash
sudo vps-audit             # verbose
sudo vps-audit --quiet     # findings only (what the timer runs)
```

Exit codes: `0` clean, `1` warnings (drift), `2` critical (hardening broken).

### What it checks

1. **Repo-managed configs vs deployed files** — every pair in `CONFIG_MAP`
   (top of `scripts/maintenance/vps-audit.sh`): sshd_config, fail2ban jail +
   caddy-llm filter/jail, sysctl, Caddyfile, unattended-upgrades, the Caddy
   systemd drop-in, and the six vps-* units.
2. **Installed toolkit** — `/usr/local/sbin/vps-*` and the lib match
   `scripts/maintenance/` in the repo.
3. **sshd effective settings** (`sshd -T`) — root login off, password auth off.
4. **UFW** — active; expected allows present (SSH port from `sshd -T`, 80,
   443, each WireGuard `ListenPort`); **unexpected** allow rules flagged.
5. **Live sysctl values** match `config/sysctl/hardening.conf`.
6. **caddy.env guards** (ADR 0002) — exists, `600 root:root`, has an
   `LLM_KEY_*` entry.
7. **Boot enablement** of core services + unattended-upgrades periodic run.
8. **fail2ban jails** `sshd` and `caddy-llm` active.

## Resolving drift — the core decision

For every `DRIFT:` line, decide which side is right:

**(a) The live change is wanted** → port it into the repo, then redeploy so
file and repo agree:

```bash
diff /etc/ssh/sshd_config "$REPO_DIR/config/ssh/sshd_config"
# edit the repo copy to match intent, commit, push, pull on the VPS…
sudo bash scripts/setup/00-security-hardening.sh   # owner of ssh/fail2ban/sysctl/UFW
sudo bash scripts/setup/21-caddy.sh                # owner of Caddyfile/caddy-llm
sudo bash scripts/setup/01-maintenance.sh          # owner of vps-*/timers/conf template
```

**(b) The live change is unwanted or unexplained** → redeploy from the repo
(same commands as above) and **investigate how it got there**:

```bash
ausearch -f /etc/ssh/sshd_config -i | tail    # auditd trail for the file
history                                        # your own shell history
last -20                                       # recent logins
```

An unexplained change to sshd_config, UFW rules, or caddy.env on a public
VPS is a potential compromise indicator — treat it seriously; if in doubt,
rotate keys ([backup-and-restore.md](backup-and-restore.md)) and consider
[rebuild-from-scratch.md](rebuild-from-scratch.md).

## Extending

New service deployed a new config file? Add **one line** to `CONFIG_MAP` in
`scripts/maintenance/vps-audit.sh` (repo-relative path `:` deployed path),
commit, redeploy with `01-maintenance.sh`. This is part of the
[add-a-service.md](add-a-service.md) checklist.

## Verify

```bash
sudo vps-audit; echo "rc=$?"    # rc=0 after resolving
```

## Rollback / Recovery

If you redeploy SSH or firewall config to resolve drift: **keep your current
SSH session open** and verify a fresh login in a second terminal before
disconnecting — see [lockout-recovery.md](lockout-recovery.md) if it goes
wrong. Deploy scripts back up every file they overwrite (`*.bak.<ts>`), so
the pre-redeploy state is always recoverable.

`00-security-hardening.sh` **resets UFW** and rebuilds the rule set. It
re-opens the SSH port, every `ListenPort` found in `/etc/wireguard/*.conf`,
and 80/443 when the caddy unit is enabled. Anything else (a manually added
rule, a service whose setup script opens its own port) is gone after the
re-run — check `sudo ufw status` against the audit's expected list before
you log off. UFW keeps a copy of the previous rules as
`/etc/ufw/user.rules.<timestamp>` if you need to see what was there.
