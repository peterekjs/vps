# vps
Tools & configurations for my personal VPS (Debian Bookworm).

## Repository structure

```
config/                        # Drop-in configuration files deployed by scripts
  caddy/Caddyfile              # Edge reverse proxy routes (TLS via Let's Encrypt)
  fail2ban/jail.local          # Fail2ban jail overrides
  maintenance/                 # Maintenance toolkit config template + systemd timers
    vps-maintenance.conf       #   template for /etc/vps-maintenance.conf
    systemd/                   #   vps-{health,backup,audit}.{service,timer}
  ssh/sshd_config              # Hardened OpenSSH server configuration
  sysctl/hardening.conf        # Kernel parameter hardening (sysctl)
  unattended-upgrades/         # Automatic security update configuration
    50unattended-upgrades
scripts/
  setup/
    00-security-hardening.sh   # Initial security hardening (run once on a fresh VPS)
    01-maintenance.sh          # Install the vps-* maintenance toolkit + timers
    21-caddy.sh                # Caddy edge reverse proxy (HTTP-01 TLS)
  maintenance/                 # Sources of the installed vps-* commands
    lib.sh                     #   shared helpers → /usr/local/lib/vps-maintenance/
    vps-health.sh              #   health report → /usr/local/sbin/vps-health
    vps-backup.sh              #   encrypted snapshots → vps-backup
    vps-restore.sh             #   snapshot restore → vps-restore
    vps-audit.sh               #   hardening drift audit → vps-audit
    vps-update.sh              #   deliberate patch routine → vps-update
    vps-notify.sh              #   Home Assistant notifier → vps-notify
  home/
    pull-backups.sh            # Run at HOME: mirror snapshots off the VPS
  wireguard/
    init.sh                    # Initialize this VPS as a WireGuard server
    add-peer.sh                # Add a peer (generates keys, prints client config)
    info.sh                    # List peers or print a peer's client config
  utils/
    common.sh                  # Shared helper functions sourced by all scripts
    wireguard.sh               # WireGuard-specific helpers (keys, IPs, sync)
docs/
  adr/                         # Architecture decision records
  runbooks/                    # Operational guides — start at docs/runbooks/README.md
wireguard/
  templates/                   # Optional templates fed to init.sh --template
```

### Setup script numbering

Scripts under `scripts/setup/` are numbered by category; within each category
the leading `N0` slot is reserved for category-foundational / shared work.

| Range | Purpose                                  | Reserved `N0`                    |
|-------|------------------------------------------|----------------------------------|
| `0x`  | Initial setup / hardening                | `00-security-hardening.sh`       |
| `1x`  | Accounts / users                         | (reserved for shared base)       |
| `2x`  | Communication / networking               | (reserved for shared base)       |
| `3x`  | Application services                     | (reserved, e.g. future Docker base) |

Individual scripts in a category therefore start at `N1` (e.g. `21-caddy.sh`).
The WireGuard scripts under `scripts/wireguard/` predate this convention and
remain in place for now.

## Quickstart

All setup scripts must be run as **root** on a fresh Debian Bookworm host.

### 1. Initial security hardening

```bash
git clone https://github.com/peterekjs/vps.git
cd vps
sudo bash scripts/setup/00-security-hardening.sh
```

If your SSH daemon listens on a non-default port, pass `--ssh-port`:

```bash
sudo bash scripts/setup/00-security-hardening.sh --ssh-port 2222
```

#### What it does

| Step | Action |
|------|--------|
| System update | Full `apt full-upgrade` |
| SSH hardening | Deploys `config/ssh/sshd_config` — disables root login & password auth, restricts ciphers |
| Firewall (UFW) | Default-deny incoming; allows the SSH port. On re-runs it also re-opens ports of already-deployed services (each WireGuard `ListenPort`, Caddy 80/443) — the reset would otherwise wipe them |
| Fail2ban | Bans IPs for 24 h after 3 failed SSH logins |
| Automatic updates | Enables `unattended-upgrades` for security packages |
| Kernel hardening | Deploys `config/sysctl/hardening.conf` — enables SYN cookies, disables ICMP redirects, ASLR max, etc. |
| Password policy | Enforces 12-char minimum, complexity, 90-day rotation via `pam_pwquality` |
| Audit logging | Enables and starts `auditd` (skipped inside containers — LXC/OpenVZ never get `CAP_AUDIT_CONTROL` from the host, so it can't run there) |

> ⚠ **Before logging out**: verify that your SSH public key is present in
> `~/.ssh/authorized_keys`. Password authentication is **disabled** by the
> script — you will be locked out without a working key.

### 2. WireGuard server

Initialize the VPS as a WireGuard server. Interactive prompts ask for the config
name (default `wg0`), VPN address (e.g. `10.9.0.1/24`), listen port and public
endpoint; a fresh server keypair is generated and stored under
`/etc/wireguard/<name>.d/server/`.

```bash
sudo bash scripts/wireguard/init.sh
```

Or build everything (server + every peer's keys) from a template — the comment
line directly above each `[Peer]` is used as the peer's name:

```bash
sudo bash scripts/wireguard/init.sh --template wireguard/templates/wg-home.conf
```

Add a peer (prompts for name and suggests the next free /24 IP). Prints the
ready-to-paste client configuration (and a QR code if `qrencode` is installed):

```bash
sudo bash scripts/wireguard/add-peer.sh
```

Inspect:

```bash
sudo bash scripts/wireguard/info.sh list          # all peers + last handshake
sudo bash scripts/wireguard/info.sh laptop        # client config for one peer
sudo bash scripts/wireguard/info.sh laptop --qr   # ...with QR code
```

State layout on the VPS:

```
/etc/wireguard/<name>.conf            # the server config (used by wg-quick)
/etc/wireguard/<name>.d/
  server/{private.key,public.key,address,listen_port,endpoint,dns}
  peers/<peer>/{private.key,public.key,address,client.conf}
```

### 3. Caddy (edge reverse proxy)

Installs [Caddy](https://caddyserver.com) natively from its official apt repo
and manages it with systemd. Caddy terminates TLS for the public hostnames and
forwards into the WireGuard mesh. Certificates come from Let's Encrypt via the
**HTTP-01** challenge — no Cloudflare API token / DNS-01, so ports 80 + 443 must
be reachable and the hostnames must resolve grey-cloud (DNS-only) to the VPS.

```bash
sudo bash scripts/setup/21-caddy.sh
```

Flag (optional):

| Flag             | Purpose                                                              |
|------------------|---------------------------------------------------------------------|
| `--keep-traefik` | Do not stop a running Traefik container (default: park it so Caddy can bind 80/443) |

#### What it does

| Step | Action |
|------|--------|
| Install | Adds Caddy's apt repo and installs the `caddy` package |
| LLM keys | Generates `/etc/caddy/caddy.env` (per-client API keys, created once), installs the systemd drop-in that loads it, prepares `/var/log/caddy` |
| Config | Deploys `config/caddy/Caddyfile` to `/etc/caddy/Caddyfile` (with backup) |
| Validate | Runs `caddy validate`; restores the backup and aborts on failure |
| Firewall | Opens `80/tcp` + `443/tcp` in UFW (required for HTTP-01 + HTTPS) |
| Cutover | Stops (parks, does not remove) any running Traefik container to free 80/443 |
| Systemd | Enables & (re)starts `caddy`, which issues certs via HTTP-01 on first request |
| fail2ban | Deploys the `caddy-llm` filter + jail (bans repeated unauthenticated probes of the LLM endpoint) |

Routes (edit `config/caddy/Caddyfile` to change them):

| Hostname             | Backend                  | Notes |
|----------------------|--------------------------|-------|
| `home.peterek.net`   | `192.168.60.20:8123`     | Home Assistant (over WireGuard HOME peer) |
| `agent.peterek.net`  | `192.168.40.10:8811`     | Agent webhooks (home-LAN host via HOME peer) — backend validates auth |
| `llm.peterek.net`    | `192.168.40.10:11434`    | Ollama on the Mac Studio — **auth at the edge**: per-client bearer keys, inference-only path allowlist, pinned CORS origins ([ADR 0002](docs/adr/0002-authenticated-llm-endpoint.md)) |

State layout on the VPS:

```
/etc/caddy/Caddyfile                          # copied from config/caddy/Caddyfile
/etc/caddy/caddy.env                          # LLM API keys — root-only, never in git
/etc/systemd/system/caddy.service.d/env.conf  # loads caddy.env into Caddy's environment
/var/log/caddy/llm-access.log                 # LLM endpoint access log (fail2ban watches it)
/var/lib/caddy/.local/share/caddy/            # certificates + ACME state
```

LLM key management: one `LLM_KEY_<CLIENT>=<openssl rand -hex 32>` line per
client in `/etc/caddy/caddy.env`, plus a matching `header Authorization` line
in the Caddyfile's `@no_key` matcher. Apply with `systemctl reload caddy`
(systemd re-reads the env file on reload; a bare `caddy reload` does not).
Browser clients additionally need their origin pinned in the `@cors_origin`
matcher. On the Mac Studio: enable "Expose Ollama to the network" in
Ollama.app, allow it through the macOS firewall, and prevent sleep.

Re-running the script is safe: it re-deploys and re-validates the Caddyfile and
reloads the service. Verify with `journalctl -u caddy -f` and
`curl -I https://agent.peterek.net`. To roll back during the verification
window: `systemctl stop caddy && docker start <traefik-container>`.

> Home Assistant must trust the proxy: add the VPS WireGuard address to
> `http.trusted_proxies` and set `use_x_forwarded_for: true` in its
> `configuration.yaml`, or logins will fail. (Home Assistant side — not managed
> by this repo.)

## Maintenance

The maintenance toolkit installs six `vps-*` commands plus systemd timers that
watch the box and page you through Home Assistant. Full operational docs live
in [docs/runbooks/](docs/runbooks/README.md).

```bash
sudo bash scripts/setup/01-maintenance.sh
```

First-install checklist (details in the runbooks):

1. **At home:** `age-keygen -o vps-backup.key` → put the public key in
   `/etc/vps-maintenance.conf` (`AGE_RECIPIENT`); keep the private key in your
   password manager + one offline copy. It never goes on the VPS.
2. Create the Home Assistant webhook automation
   ([health-monitoring.md](docs/runbooks/health-monitoring.md)) and set
   `HA_WEBHOOK_URL`.
3. `sudo usermod -aG vpsbackup <user>` so your SSH user can pull snapshots,
   then from home: `scripts/home/pull-backups.sh <user>@<vps>`.
4. Test: `sudo vps-notify --title Test "hello"`, then `sudo vps-backup && sudo vps-health`.

### Commands

| Command | Purpose | Runbook |
|---|---|---|
| `vps-health` | One-shot health report (services, disk, certs, WG peers, backups) | [health-monitoring.md](docs/runbooks/health-monitoring.md) |
| `vps-backup` | age-encrypted snapshot of identity & secrets → `/var/backups/vps` | [backup-and-restore.md](docs/runbooks/backup-and-restore.md) |
| `vps-restore` | Restore a snapshot (dry-run, per-file `.bak` safety copies) | [backup-and-restore.md](docs/runbooks/backup-and-restore.md) |
| `vps-audit` | Hardening drift audit: live system vs this repo | [drift-audit.md](docs/runbooks/drift-audit.md) |
| `vps-update` | Deliberate monthly full-upgrade with backup + health gates | [updates-and-patching.md](docs/runbooks/updates-and-patching.md) |
| `vps-notify` | Send a message to the Home Assistant webhook | [health-monitoring.md](docs/runbooks/health-monitoring.md) |

Exit codes for the check commands: `0` ok · `1` warnings · `2` critical.

### Timers

| Timer | Cadence | Pages you when |
|---|---|---|
| `vps-backup.timer` | daily 05:30 | a snapshot fails |
| `vps-health.timer` | daily 07:00 | any check warns or goes critical |
| `vps-audit.timer` | weekly Sun 07:30 | live config drifts from this repo |

`vps-update` deliberately has **no timer** — security patches are automatic
via unattended-upgrades; full upgrades with possible reboots are a human
decision.

After a `git pull`, re-run `sudo bash scripts/setup/01-maintenance.sh` to
redeploy the toolkit (the audit will remind you if you forget).
