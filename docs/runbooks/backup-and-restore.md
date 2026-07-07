# Backup & restore

## When to use

- Automatically: `vps-backup.timer` snapshots daily at ~05:30.
- Manually: before any risky change (`sudo vps-backup`), and to restore after
  data loss or during [rebuild-from-scratch.md](rebuild-from-scratch.md).

## Prerequisites

- One-time key setup, done **at home** (never on the VPS):

  ```bash
  age-keygen -o vps-backup.key
  # Public key:  age1...   ← paste into /etc/vps-maintenance.conf AGE_RECIPIENT
  ```

  Store `vps-backup.key` in your password manager **plus one offline copy**.
  Whoever holds it can read every snapshot (WireGuard keys, SSH host keys,
  LLM API keys); without it the snapshots are unreadable — including by the
  VPS itself. That asymmetry is the point: a compromised VPS cannot decrypt
  its own backup history.

- For pulls: your SSH user must be in the `vpsbackup` group on the VPS:

  ```bash
  sudo usermod -aG vpsbackup <user>    # then reconnect SSH
  ```

## Steps — creating snapshots

```bash
sudo vps-backup --dry-run    # list what would be captured
sudo vps-backup              # tar → verify → age-encrypt → prune
```

Snapshots land in `/var/backups/vps/` as
`vps-backup-<YYYYmmdd-HHMMSS>.tar.gz.age` + `.sha256`, kept
`BACKUP_RETENTION_DAYS` (default 14) days.

**What's inside (`BACKUP_PATHS` in `/etc/vps-maintenance.conf`)** — identity
and secrets that the repo cannot regenerate:

| Path | Why |
|---|---|
| `/etc/wireguard` | server + peer keys — the VPN's identity |
| `/etc/ssh/ssh_host_*` | SSH host keys — clients' `known_hosts` stay valid after a rebuild |
| `/var/lib/caddy` | certificates + ACME account — no rate-limit dance on rebuild |
| `/etc/caddy/caddy.env` | per-client LLM API keys (ADR 0002) — otherwise every client re-onboards |
| `/etc/vps-maintenance.conf` | this machine's own settings |
| `/root/.ssh/authorized_keys` | root's key trust |

Everything else (sshd_config, Caddyfile, sysctl, jails …) is *configuration*
and comes from this repo — that's the repo/backup split by design. **When a
new service adds machine-specific state, extend `BACKUP_PATHS`** in both the
live conf and the repo template (`config/maintenance/vps-maintenance.conf`).

## Steps — pulling snapshots home

```bash
scripts/home/pull-backups.sh jiri@10.9.0.1        # over WireGuard
scripts/home/pull-backups.sh jiri@37.205.10.203   # or over the public IP
```

Default destination `~/Backups/vps` (override with a second argument). The
script deliberately does **not** mirror deletions: local copies outlive the
VPS's 14-day retention and form your long-term DR history — prune them
yourself if they grow annoying.

Schedule it (macOS example, weekly):

```bash
crontab -e
# m h dom mon dow
0 9 * * 1 $HOME/projects/peterekjs/vps/scripts/home/pull-backups.sh jiri@10.9.0.1 >> $HOME/Backups/vps/pull.log 2>&1
```

## Steps — restoring

**Single file** (e.g. one WireGuard peer config), decrypted at home:

```bash
age -d -i vps-backup.key -o - vps-backup-<ts>.tar.gz.age \
  | tar -xzf - -C /tmp/restore etc/wireguard/wg0.conf
# inspect /tmp/restore/..., scp the file to the VPS, place it manually
```

**Full restore on the VPS:**

```bash
# 1. get the snapshot + key onto the VPS (key only temporarily!)
scp vps-backup-<ts>.tar.gz.age vps-backup.key jiri@<vps>:

# 2. rehearse, then restore
sudo vps-restore --dry-run  --identity vps-backup.key vps-backup-<ts>.tar.gz.age
sudo vps-restore            --identity vps-backup.key vps-backup-<ts>.tar.gz.age
# type 'restore' at the prompt

# 3. restart the services whose state came back (the command prints this list)
sudo systemctl restart ssh wg-quick@wg0 caddy

# 4. REMOVE the private key from the VPS
shred -u vps-backup.key

sudo vps-health
```

## Verify

- After any backup: `sha256sum -c` the newest pair (the pull script does this
  automatically after each pull).
- **Restore drill (do this a couple of times a year):** at home, decrypt the
  newest pulled snapshot and list it —

  ```bash
  age -d -i vps-backup.key -o /tmp/drill.tar.gz ~/Backups/vps/vps-backup-<ts>.tar.gz.age
  tar -tzf /tmp/drill.tar.gz | head    # paths listed → backup chain works
  rm /tmp/drill.tar.gz
  ```

- `sudo vps-health` warns when the newest snapshot exceeds
  `BACKUP_MAX_AGE_HOURS` (default 48 h).

## Rollback / Recovery

`vps-restore` backs up every file it overwrites as `<file>.bak.<timestamp>`
(one timestamp per run). To undo a restore, copy the `.bak.<ts>` files back
and restart the affected services. If the age key is lost, snapshots are
gone for good — that's why the key lives in the password manager *and* one
offline copy.
