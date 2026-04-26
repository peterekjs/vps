# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Bash scripts and drop-in config files for hardening and maintaining a personal VPS running **Debian Bookworm (12)**. There is no build system, package manager, or test suite — just shell scripts that deploy files from `config/` to system paths and configure services.

Scripts are intended to run **as root on the target VPS**, not on the developer machine. They will refuse to run elsewhere (`require_root` + `require_debian_bookworm` guards in [scripts/utils/common.sh](scripts/utils/common.sh)).

## Architecture

Two-layer structure:

1. **`config/`** — canonical, version-controlled configuration files. Each subdirectory mirrors the system path it targets (`config/ssh/sshd_config` → `/etc/ssh/sshd_config`, `config/sysctl/hardening.conf` → `/etc/sysctl.d/99-hardening.conf`, etc.). Edit these files to change deployed configuration; do not embed config in the scripts.

2. **`scripts/setup/NN-*.sh`** — numbered, idempotent setup scripts. Each script:
   - sources [scripts/utils/common.sh](scripts/utils/common.sh) for shared helpers
   - resolves `REPO_ROOT` from `BASH_SOURCE` so it works regardless of cwd
   - calls `require_root` and `require_debian_bookworm` first
   - calls `backup_file` before overwriting any existing system file (creates `<file>.bak.<timestamp>`)
   - validates config before restarting services (e.g. `sshd -t` before `service_enable_restart ssh`, with rollback to the backup on failure)
   - is **safe to re-run** — uses `apt_install` (skips already-installed packages), `service_enable_restart` (start or restart depending on current state), and `sed` in-place edits with idempotent patterns

### Setup script numbering

Numbers under `scripts/setup/` are grouped by category, and within each category the leading `N0` slot is **reserved for category-foundational / shared work** (the same role `00-security-hardening.sh` plays in the `0x` range). Individual scripts therefore start at `N1`.

- `0x` — initial setup / hardening (`00` = baseline hardening)
- `1x` — accounts / users (`10` reserved for shared base)
- `2x` — communication / networking (`20` reserved; the WireGuard scripts under `scripts/wireguard/` predate this convention)
- `3x` — application services (`30` reserved for a shared service-tier bootstrap such as a future `30-docker.sh`; `31-n8n.sh` is the first individual service)

When adding a new setup script: pick the lowest free number ≥ `N1` in the matching category range. Do not take an `N0` slot unless the script genuinely installs shared infrastructure used by every other script in the range — when a second consumer of that infrastructure appears, extract the shared logic into the `N0` script then. Otherwise follow the same pattern as the existing scripts: number prefix, source `common.sh`, use the helpers rather than reinventing logging/backup/install logic.

## Conventions for shell scripts

- All scripts start with `set -euo pipefail`.
- Use the logging helpers (`log_info`, `log_success`, `log_warn`, `log_error`, `section`) from `common.sh` — do not call `echo` directly for status output.
- Use `backup_file` before any destructive write to `/etc/`. Capture the returned path if you may need to roll back.
- Reference configs via `${REPO_ROOT}/config/...`, never via relative paths.
- Add a `# shellcheck source=...` directive when sourcing, so shellcheck can follow it.
- Honour the `--ssh-port` flag pattern if the script touches anything SSH-related — both `sshd_config` and `fail2ban/jail.local` get patched in place when the port is non-default.

## Commands

```bash
# Lint shell scripts (run on dev machine before committing)
shellcheck scripts/setup/*.sh scripts/utils/*.sh

# Run the hardening script on a fresh VPS (as root, on Debian Bookworm only)
sudo bash scripts/setup/00-security-hardening.sh
sudo bash scripts/setup/00-security-hardening.sh --ssh-port 2222
```

There is no CI, no test framework, and no lint configured in-repo — `shellcheck` is the only validation. Do not invent build/test commands.

## Critical safety note

`00-security-hardening.sh` **disables SSH password authentication**. Any change to SSH config or firewall rules in this repo can lock the operator out of their VPS. When modifying `config/ssh/sshd_config`, `config/fail2ban/jail.local`, or the UFW section of the hardening script, preserve the existing pattern: validate config syntax before restart, allow the SSH port in UFW *before* enabling the firewall, and keep the backup-and-rollback flow intact.
