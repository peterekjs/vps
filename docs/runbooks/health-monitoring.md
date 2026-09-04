# Health monitoring

## When to use

- Automatically: `vps-health.timer` runs daily at ~07:00 and pushes findings to Home Assistant.
- Manually: after any change to the VPS, after an alert, or whenever something feels off.

## Prerequisites

- Toolkit installed: `sudo bash scripts/setup/01-maintenance.sh`
- `/etc/vps-maintenance.conf` filled in (at minimum `MAIL_TO`, `SMTP_USER`,
  `SMTP_PASS` for alerts).

## Steps

Run the full report:

```bash
sudo vps-health            # verbose: every check, OK lines included
sudo vps-health --quiet    # findings only (what the timer runs)
```

Exit codes: `0` = all OK, `1` = warnings, `2` = at least one critical finding.

### What each check means

| Check | Critical when | Tuned by |
|---|---|---|
| Services (`ssh`, `caddy`, `fail2ban`, `wg-quick@*`) | unit not active | — |
| WireGuard listen port in UFW (each `/etc/wireguard/*.conf`) | UFW active but no allow rule for the interface's `ListenPort/udp` | — |
| Audit daemon (`auditd`) | unit not active — unless running in a container (LXC/OpenVZ), where it's expected to be skipped | — |
| Root filesystem usage | ≥ `DISK_CRIT_PCT` (warn ≥ `DISK_WARN_PCT`) | `DISK_WARN_PCT`, `DISK_CRIT_PCT` |
| Available memory | — (warn < `MEM_AVAILABLE_MIN_MB` MB) | `MEM_AVAILABLE_MIN_MB` |
| 15-min load | — (warn > 2× cores) | — |
| TLS cert expiry (every hostname in the Caddyfile) | < 3 days, or cert unfetchable | `CERT_WARN_DAYS` |
| WireGuard handshake for critical peers | older than `WG_HANDSHAKE_MAX_AGE` s, never, or peer missing | `WG_CRITICAL_PEERS`, `WG_HANDSHAKE_MAX_AGE` |
| Pending updates / reboot-required | — (informational / warn) | — |
| fail2ban jails | no active jails | — |
| Backup freshness | — (warn > `BACKUP_MAX_AGE_HOURS` h) | `BACKUP_MAX_AGE_HOURS` |

Cert note: Let's Encrypt certs are renewed by Caddy ~30 days before expiry, so
anything under `CERT_WARN_DAYS` (default 14) means renewal has been failing
for weeks — check `journalctl -u caddy` and that ports 80/443 are reachable.

### Setting up email alerts (one-time, primary channel)

Email is the primary channel because it does **not** depend on WireGuard:
a broken tunnel is exactly the failure that must still reach you (the
Home Assistant webhook below cannot report it). No MTA is installed —
`vps-notify` speaks SMTPS directly through `curl`.

1. Create a Google **app password** for the mailbox that will send the alerts
   (your own Workspace account is fine): <https://myaccount.google.com/apppasswords>,
   name it `vps-notify`. This needs 2-step verification on the account. The
   app password is a mailbox credential living on the VPS — if the box is ever
   compromised, **revoke that one app password** there and nothing else changes.
2. On the VPS, set in `/etc/vps-maintenance.conf` (mode 600 root):

   ```bash
   MAIL_TO="you@example.com"
   SMTP_URL="smtps://smtp.gmail.com:465"
   SMTP_USER="you@example.com"
   SMTP_PASS="xxxx xxxx xxxx xxxx"     # the app password; spaces are fine
   ```

3. Test the channel end-to-end (the subject arrives as
   `[WARNING] Test (<hostname>)`):

   ```bash
   sudo vps-notify --severity warning --title "Test" "hello from the VPS"
   ```

4. Optionally add a Gmail filter on subject `[CRITICAL]` so those bypass
   the inbox tabs / trigger a phone alert.

The app password also lands in backups through `/etc/vps-maintenance.conf`,
which is already in `BACKUP_PATHS` and age-encrypted — nothing extra to do.

### Setting up the Home Assistant webhook (optional second channel)

Only useful for phone push while the tunnel is up; leave `HA_WEBHOOK_URL`
empty if you don't need it. Both channels are tried when both are set.

1. In Home Assistant: **Settings → Automations & Scenes → Create automation**.
2. Trigger: **Webhook**, id `vps-maintenance`, method **POST**, leave "Only
   accessible from the local network" **on** — traffic arrives over WireGuard,
   which HA sees as local.
3. Action: **Send notification** to your phone, using the payload fields:

   ```yaml
   action: notify.mobile_app_<your_phone>
   data:
     title: "{{ trigger.json.severity | upper }}: {{ trigger.json.title }}"
     message: "{{ trigger.json.message }} ({{ trigger.json.host }})"
   ```

4. On the VPS, set in `/etc/vps-maintenance.conf`:

   ```bash
   HA_WEBHOOK_URL="http://192.168.60.20:8123/api/webhook/vps-maintenance"
   ```

5. Test with the same `vps-notify` command as above — both channels report.

Silence is a signal: the notifier only pages on findings, so if the mail
channel breaks you will simply stop getting anything — a manual `sudo vps-health`
during a quiet week is a cheap sanity check.

## Verify

```bash
systemctl list-timers 'vps-*'        # three timers scheduled
journalctl -u vps-health -n 50       # last scheduled run's output
sudo vps-health; echo "rc=$?"        # rc matches the report
```

## Rollback / Recovery

Nothing to roll back — the command only reads. When it reports problems:

| Finding | Go to |
|---|---|
| cert expiring / unfetchable | this file (cert note) + `journalctl -u caddy -f` |
| WG handshake critical | *all* peers never/stale → firewall: `sudo ufw status \| grep udp` must list each WireGuard `ListenPort` (a hardening re-run before 2026-09 dropped it). Single peer → check that device / the home router; `sudo wg show` |
| backup stale or missing | [backup-and-restore.md](backup-and-restore.md) |
| reboot required | [updates-and-patching.md](updates-and-patching.md) |
| service not active | `systemctl status <svc>`, then the service's runbook/ADR |
| tune a noisy threshold | edit `/etc/vps-maintenance.conf` (this file's table) |
