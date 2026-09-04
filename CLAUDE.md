# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Bash scripts and drop-in config files for hardening and maintaining a personal VPS running **Debian Bookworm (12)**. There is no build system, package manager, or test suite — just shell scripts that deploy files from `config/` to system paths and configure services.

Scripts are intended to run **as root on the target VPS**, not on the developer machine. They will refuse to run elsewhere (`require_root` + `require_debian_supported` guards in [scripts/utils/common.sh](scripts/utils/common.sh); supported releases live in the `SUPPORTED_CODENAMES` list there — extended only via the debian-release-upgrade runbook). Exceptions: `scripts/home/` runs on a home machine (no guards), and the sources under `scripts/maintenance/` run on the VPS as installed copies (see below).

## Architecture

Two-layer structure, plus an installed maintenance toolkit:

1. **`config/`** — canonical, version-controlled configuration files. Each subdirectory mirrors the system path it targets (`config/ssh/sshd_config` → `/etc/ssh/sshd_config`, `config/sysctl/hardening.conf` → `/etc/sysctl.d/99-hardening.conf`, etc.). Edit these files to change deployed configuration; do not embed config in the scripts.

2. **`scripts/setup/NN-*.sh`** — numbered, idempotent setup scripts. Each script:
   - sources [scripts/utils/common.sh](scripts/utils/common.sh) for shared helpers
   - resolves `REPO_ROOT` from `BASH_SOURCE` so it works regardless of cwd
   - calls `require_root` and `require_debian_bookworm` first
   - calls `backup_file` before overwriting any existing system file (creates `<file>.bak.<timestamp>`)
   - validates config before restarting services (e.g. `sshd -t` before `service_enable_restart ssh`, with rollback to the backup on failure)
   - is **safe to re-run** — uses `apt_install` (skips already-installed packages), `service_enable_restart` (start or restart depending on current state), and `sed` in-place edits with idempotent patterns

3. **`scripts/maintenance/`** — sources of the installed `vps-*` commands (`vps-health`, `vps-backup`, `vps-restore`, `vps-audit`, `vps-update`, `vps-notify`). `scripts/setup/01-maintenance.sh` deploys them to `/usr/local/sbin/` (extension stripped) and `lib.sh` to `/usr/local/lib/vps-maintenance/lib.sh`; systemd timers come from `config/maintenance/systemd/`. These scripts are **self-contained at runtime**: they source the *installed* lib (`${VPS_MAINT_LIB:-/usr/local/lib/vps-maintenance/lib.sh}` — override the env var to test from a checkout) and read machine-specific settings from `/etc/vps-maintenance.conf` (template: `config/maintenance/vps-maintenance.conf`, deployed only if absent, never clobbered). Check commands exit `0` ok / `1` warnings / `2` critical. `scripts/home/` holds scripts for the operator's home machine (no root/OS guards).

### Setup script numbering

Numbers under `scripts/setup/` are grouped by category, and within each category the leading `N0` slot is **reserved for category-foundational / shared work** (the same role `00-security-hardening.sh` plays in the `0x` range). Individual scripts therefore start at `N1`.

- `0x` — initial setup / hardening (`00` = baseline hardening; `01` = maintenance toolkit)
- `1x` — accounts / users (`10` reserved for shared base)
- `2x` — communication / networking (`20` reserved; `21-caddy.sh` is the edge reverse proxy; the WireGuard scripts under `scripts/wireguard/` predate this convention)
- `3x` — application services (`30` reserved for a shared service-tier bootstrap such as a future `30-docker.sh`; no individual service scripts currently)

When adding a new setup script: pick the lowest free number ≥ `N1` in the matching category range. Do not take an `N0` slot unless the script genuinely installs shared infrastructure used by every other script in the range — when a second consumer of that infrastructure appears, extract the shared logic into the `N0` script then. Otherwise follow the same pattern as the existing scripts: number prefix, source `common.sh`, use the helpers rather than reinventing logging/backup/install logic.

## Conventions for shell scripts

- All scripts start with `set -euo pipefail`.
- Use the logging helpers (`log_info`, `log_success`, `log_warn`, `log_error`, `section`) from `common.sh` — do not call `echo` directly for status output.
- Use `backup_file` before any destructive write to `/etc/`. Capture the returned path if you may need to roll back.
- Reference configs via `${REPO_ROOT}/config/...`, never via relative paths.
- Add a `# shellcheck source=...` directive when sourcing, so shellcheck can follow it.
- Honour the `--ssh-port` flag pattern if the script touches anything SSH-related — both `sshd_config` and `fail2ban/jail.local` get patched in place when the port is non-default.

## Conventions for operational changes

- **Runbooks:** every operational workflow has a runbook in `docs/runbooks/` following the skeleton *When to use → Prerequisites → Steps → Verify → Rollback/Recovery* (index + convention: [docs/runbooks/README.md](docs/runbooks/README.md)). A change that adds or alters a workflow ships with its runbook in the same PR.
- **New deployed config file** ⇒ add a `repo-path:deployed-path` line to `CONFIG_MAP` in [scripts/maintenance/vps-audit.sh](scripts/maintenance/vps-audit.sh), or the weekly drift audit goes blind to it.
- **New machine-specific state/secret** (key files, generated configs) ⇒ add its path to `BACKUP_PATHS` in `config/maintenance/vps-maintenance.conf` (template) and remind the operator to update the live `/etc/vps-maintenance.conf` — otherwise rebuild-from-scratch silently loses it.
- Full checklist: [docs/runbooks/add-a-service.md](docs/runbooks/add-a-service.md).

## Commands

```bash
# Lint shell scripts (run on dev machine before committing).
# Keep sourced files in the same invocation or shellcheck reports SC1091.
shellcheck scripts/setup/*.sh scripts/utils/*.sh scripts/maintenance/*.sh scripts/home/*.sh scripts/wireguard/*.sh

# Run the hardening script on a fresh VPS (as root, on Debian Bookworm only)
sudo bash scripts/setup/00-security-hardening.sh
sudo bash scripts/setup/00-security-hardening.sh --ssh-port 2222

# Deploy the Caddy edge reverse proxy (parks any running Traefik to free 80/443)
sudo bash scripts/setup/21-caddy.sh

# Install/redeploy the maintenance toolkit (vps-* commands + timers); re-run after every git pull
sudo bash scripts/setup/01-maintenance.sh
```

There is no CI, no test framework, and no lint configured in-repo — `shellcheck` is the only validation. Do not invent build/test commands.

## Critical safety note

`00-security-hardening.sh` **disables SSH password authentication**. Any change to SSH config or firewall rules in this repo can lock the operator out of their VPS. When modifying `config/ssh/sshd_config`, `config/fail2ban/jail.local`, or the UFW section of the hardening script, preserve the existing pattern: validate config syntax before restart, allow the SSH port in UFW *before* enabling the firewall, and keep the backup-and-rollback flow intact.

`21-caddy.sh` is the public TLS edge. `agent.peterek.net` forwards unauthenticated traffic over WireGuard to `192.168.40.10:8811` — the backend is solely responsible for validating webhooks. Caddy uses Let's Encrypt **HTTP-01** (no Cloudflare), so ports 80 + 443 must stay open and the hostnames must resolve grey-cloud (DNS-only) to the VPS. Background and rejected alternatives: [docs/adr/0001-native-caddy-http01-reverse-proxy.md](docs/adr/0001-native-caddy-http01-reverse-proxy.md).

`plex.peterek.net` proxies Plex on the QNAP NAS (`192.168.60.10:32400`) with no edge auth — Plex validates every request with its own account tokens. Remote apps only find it because the NAS publishes the URL to plex.tv (*Custom server access URLs*, see [docs/runbooks/plex-remote-access.md](docs/runbooks/plex-remote-access.md)); the hostname must stay `https://…:443` there.

`llm.peterek.net` exposes Ollama on the Mac Studio (`192.168.40.10:11434`) with authentication **at the Caddy edge** (Ollama has none of its own): per-client `LLM_KEY_*` bearer keys living in `/etc/caddy/caddy.env` — **never commit key values**; the Caddyfile only carries `{$LLM_KEY_*}` placeholders. The site block's path allowlist is inference-only by design — do not add model-management paths (`/api/pull`, `/api/delete`, `/api/create`, `/api/push`, `/api/copy`). Rationale and rejected alternatives: [docs/adr/0002-authenticated-llm-endpoint.md](docs/adr/0002-authenticated-llm-endpoint.md).
