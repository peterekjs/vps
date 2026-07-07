# Adding a service

## When to use

Exposing a new backend through Caddy, adding a WireGuard peer, or adding a
new setup script. This is the checklist that keeps the hardening, audit, and
backup guarantees intact while the system grows.

## Prerequisites

- The backend exists and is reachable from the VPS over WireGuard.
- For a public hostname: DNS control for `peterek.net`.

## Steps — new proxied service

1. **Reachability first** — from the VPS:

   ```bash
   curl -sv http://192.168.x.y:PORT/ -o /dev/null   # via the HOME peer's routes
   ```

2. **DNS**: add an A record `svc.peterek.net → <vps-ip>`, **grey-cloud /
   DNS-only** (ADR 0001 — Cloudflare must not be in the request path, or
   HTTP-01 breaks).

3. **Decision point — where does authentication live?**

   | Backend | Pattern | Example |
   |---|---|---|
   | has its own auth (login page, validated webhooks) | plain `reverse_proxy` site block | `agent.peterek.net` |
   | has **no** auth of its own | **edge-auth pattern** (ADR 0002): per-client `{$KEY_*}` bearer keys in `/etc/caddy/caddy.env`, path allowlist, pinned CORS, per-site access log + fail2ban jail on 401s | `llm.peterek.net` |

   Copy the matching existing site block in `config/caddy/Caddyfile` as a
   starting point. For edge-auth, read ADR 0002 first — the fail-closed
   env-file loading and the 401-vs-403 fail2ban distinction are deliberate.

4. **Deploy:** `sudo bash scripts/setup/21-caddy.sh` — it validates the
   Caddyfile before touching the running service and rolls back on failure.

5. **Keep the guarantees intact:**

   - New deployed file (fail2ban filter, systemd drop-in, …)? → add a line
     to `CONFIG_MAP` in `scripts/maintenance/vps-audit.sh`.
   - New machine-specific secret/state (like a key env file)? → add the path
     to `BACKUP_PATHS` in **both** `/etc/vps-maintenance.conf` and the repo
     template `config/maintenance/vps-maintenance.conf`.
   - New operational workflow (key rotation, client onboarding, …)? → write
     a runbook (skeleton in [README.md](README.md)).
   - Then redeploy the toolkit: `sudo bash scripts/setup/01-maintenance.sh`.

## Steps — new WireGuard peer

```bash
sudo bash scripts/wireguard/add-peer.sh        # prompts for name, prints config + QR
```

Add the peer to `WG_CRITICAL_PEERS` in `/etc/vps-maintenance.conf` **only**
if the VPS depends on it being connected (like HOME, which carries the
proxied backends) — otherwise the health check will page you every time a
laptop sleeps.

## Steps — new setup script

Numbering (from `CLAUDE.md`): `0x` initial setup/hardening, `1x` accounts,
`2x` networking, `3x` application services. The `N0` slot of each range is
reserved for category-foundational work; individual scripts take the lowest
free number ≥ `N1`. Follow the existing pattern: source `common.sh`,
`require_root` + `require_debian_supported`, `backup_file` before
overwrites, validate before restart, idempotent re-runs.

## Verify

```bash
curl -I https://svc.peterek.net      # 200/302 with a fresh LE certificate
sudo vps-health                      # new hostname's cert picked up automatically
sudo vps-audit; echo "rc=$?"         # 0 → CONFIG_MAP was extended correctly
sudo vps-backup --dry-run            # new state paths listed
```

## Rollback / Recovery

Remove the site block from `config/caddy/Caddyfile`, re-run
`scripts/setup/21-caddy.sh`, delete the DNS record. For edge-auth services
also remove the client keys from `/etc/caddy/caddy.env` and the fail2ban
drop-ins (then `sudo systemctl reload fail2ban`), and revert the
`CONFIG_MAP`/`BACKUP_PATHS` entries.
