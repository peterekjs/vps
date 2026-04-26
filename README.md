# vps
Tools & configurations for my personal VPS (Debian Bookworm).

## Repository structure

```
config/                        # Drop-in configuration files deployed by scripts
  fail2ban/jail.local          # Fail2ban jail overrides
  n8n/docker-compose.yml       # Compose template for the n8n service
  ssh/sshd_config              # Hardened OpenSSH server configuration
  sysctl/hardening.conf        # Kernel parameter hardening (sysctl)
  systemd/n8n.service          # Systemd unit that drives the n8n compose stack
  unattended-upgrades/         # Automatic security update configuration
    50unattended-upgrades
scripts/
  setup/
    00-security-hardening.sh   # Initial security hardening (run once on a fresh VPS)
    31-n8n.sh                  # Self-hosted n8n via Docker Compose
  wireguard/
    init.sh                    # Initialize this VPS as a WireGuard server
    add-peer.sh                # Add a peer (generates keys, prints client config)
    info.sh                    # List peers or print a peer's client config
  utils/
    common.sh                  # Shared helper functions sourced by all scripts
    wireguard.sh               # WireGuard-specific helpers (keys, IPs, sync)
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

Individual scripts in a category therefore start at `N1` (e.g. `31-n8n.sh`).
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
| Firewall (UFW) | Default-deny incoming; allows only the SSH port |
| Fail2ban | Bans IPs for 24 h after 3 failed SSH logins |
| Automatic updates | Enables `unattended-upgrades` for security packages |
| Kernel hardening | Deploys `config/sysctl/hardening.conf` — enables SYN cookies, disables ICMP redirects, ASLR max, etc. |
| Password policy | Enforces 12-char minimum, complexity, 90-day rotation via `pam_pwquality` |
| Audit logging | Enables and starts `auditd` |

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

### 3. n8n

Deploys [n8n](https://n8n.io) as a Docker Compose stack managed by systemd.
Installs Docker Engine + Compose v2 from Docker's official Debian repo if not
already present, prompts for the basic-auth username, password and bind host,
and starts the service.

```bash
sudo bash scripts/setup/31-n8n.sh
```

Flags (all optional — defaults are interactive prompts):

| Flag                | Purpose                                                           |
|---------------------|-------------------------------------------------------------------|
| `--user <name>`     | Basic-auth username (default prompt: `admin`)                     |
| `--host <addr>`     | Bind host (default prompt: `0.0.0.0`)                             |
| `--password-stdin`  | Read the basic-auth password from stdin (no confirmation prompt)  |
| `--ufw-allow`       | Open `5678/tcp` in UFW (default: leave closed)                    |

#### What it does

| Step | Action |
|------|--------|
| Docker | Adds Docker's apt repo, installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` |
| Credentials | Prompts for basic-auth username / password / bind host (or takes them from flags / stdin) |
| Compose | Deploys `config/n8n/docker-compose.yml` to `/opt/n8n/docker-compose.yml` and writes `/opt/n8n/.env` (mode 600) |
| Validate | Runs `docker compose config -q`; restores backups and aborts on failure |
| Systemd | Deploys `config/systemd/n8n.service` to `/etc/systemd/system/`, reloads systemd, enables & starts `n8n.service` |
| Firewall | Opt-in via `--ufw-allow`; otherwise `5678/tcp` stays closed (access is expected via WireGuard or a future reverse proxy) |

State layout on the VPS:

```
/opt/n8n/
  docker-compose.yml      # copied from config/n8n/docker-compose.yml
  .env                    # generated (mode 600 — contains basic-auth password)
  n8n_data/               # bind mount, created by the n8n container on first run
/etc/systemd/system/n8n.service
```

Re-running the script is safe: if `/opt/n8n/.env` already exists you'll be
asked whether to overwrite credentials. Decline to keep credentials and only
refresh Docker, the compose file, and the systemd unit.

Reach the UI at `http://<host>:5678/` (basic auth required). To upgrade to
the latest n8n image:

```bash
sudo docker compose -f /opt/n8n/docker-compose.yml pull
sudo docker compose -f /opt/n8n/docker-compose.yml up -d
```
