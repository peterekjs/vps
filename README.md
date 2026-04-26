# vps
Tools & configurations for my personal VPS (Debian Bookworm).

## Repository structure

```
config/                        # Drop-in configuration files deployed by scripts
  fail2ban/jail.local          # Fail2ban jail overrides
  ssh/sshd_config              # Hardened OpenSSH server configuration
  sysctl/hardening.conf        # Kernel parameter hardening (sysctl)
  unattended-upgrades/         # Automatic security update configuration
    50unattended-upgrades
scripts/
  setup/
    00-security-hardening.sh   # Initial security hardening (run once on a fresh VPS)
  utils/
    common.sh                  # Shared helper functions sourced by all scripts
```

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
