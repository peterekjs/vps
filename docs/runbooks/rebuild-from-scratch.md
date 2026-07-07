# Rebuild from scratch (disaster recovery)

## When to use

The VPS is dead, compromised, or you're starting over on a fresh box. This
is the repo's DR guarantee: **repo + newest snapshot + age key = the same
server** — same WireGuard identity, same SSH host keys, same certificates,
same LLM API keys. Peers and clients notice nothing (except the IP, if it
changed).

## Prerequisites

All of these live at home, which is the point:

- the newest pulled snapshot (`~/Backups/vps/vps-backup-<ts>.tar.gz.age`)
- the age private key (`vps-backup.key`, from your password manager)
- your SSH public key
- this repo (GitHub)
- provider account access

## Steps

1. **Provision** a fresh Debian VPS matching a codename in
   `SUPPORTED_CODENAMES` (`scripts/utils/common.sh`). Add your SSH public key
   to the root/default user during provisioning.

2. **Clone and harden:**

   ```bash
   git clone https://github.com/peterekjs/vps.git && cd vps
   sudo bash scripts/setup/00-security-hardening.sh
   ```

   ⚠ **Before anything else:** verify key-based SSH login works in a
   *second* terminal — password auth is now disabled.

3. **Install the toolkit** (brings `age` and `vps-restore`):

   ```bash
   sudo bash scripts/setup/01-maintenance.sh
   ```

4. **Upload snapshot + key** (from home):

   ```bash
   scp ~/Backups/vps/vps-backup-<ts>.tar.gz.age vps-backup.key <user>@<new-ip>:
   ```

5. **Restore identity & state:**

   ```bash
   sudo vps-restore --dry-run  --identity vps-backup.key vps-backup-<ts>.tar.gz.age
   sudo vps-restore            --identity vps-backup.key vps-backup-<ts>.tar.gz.age
   shred -u vps-backup.key     # private key must not live on the VPS
   ```

6. **Bring services up on the restored state:**

   ```bash
   sudo systemctl restart ssh                       # old host identity is back
   sudo systemctl enable --now wg-quick@wg0         # restored /etc/wireguard/wg0.conf
   sudo bash scripts/setup/21-caddy.sh              # installs caddy; sees restored certs + caddy.env
   ```

7. **If the IP changed** → continue with
   [provider-or-ip-migration.md](provider-or-ip-migration.md) (DNS + every
   peer's `Endpoint`). Until DNS/peers are updated, WireGuard handshakes and
   HTTP-01 renewals will fail — expected.

## Verify

```bash
sudo vps-health; echo "rc=$?"          # 0 (cert checks OK because /var/lib/caddy was restored)
sudo wg show                            # handshake from HOME within keepalive time
curl -I https://home.peterek.net        # 200/302 via the tunnel
```

From home: `ssh <user>@<host>` connects **without** a host-key warning —
proof the server identity survived.

## Rollback / Recovery

There's nothing to roll back to — the old box is gone. If the restore
itself fails: older snapshots are still at home (the pull script never
deletes), and each restore attempt leaves `.bak.<ts>` copies of whatever it
touched. Worst case (no usable snapshot): run the setup scripts for a clean
new identity, re-issue WireGuard peer configs (`scripts/wireguard/init.sh` +
`add-peer.sh`), accept new SSH host keys everywhere, re-onboard LLM clients
with new keys, and let Caddy issue fresh certificates.
