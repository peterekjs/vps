# Debian release upgrade

## When to use

A new Debian stable is out (e.g. Bookworm → Trixie) and you want on it. No
rush: oldstable receives security support for roughly a year after a
release, so pick a calm weekend. **Always read the official release notes
first** (`https://www.debian.org/releases/<codename>/releasenotes`) — some
releases add mandatory extra steps this generic runbook can't anticipate.

## Prerequisites

- Fresh snapshot pulled home ([backup-and-restore.md](backup-and-restore.md)).
- `sudo vps-health` and `sudo vps-audit` both exit 0 — don't upgrade a
  drifted or unhealthy system.
- ~2 GB free on `/` (`df -h /`).
- Provider console access ready ([lockout-recovery.md](lockout-recovery.md))
  in case SSH dies mid-upgrade. Run the upgrade inside `tmux`/`screen` so a
  dropped SSH connection doesn't kill apt.

## Steps

1. **Patch current release fully:** `sudo vps-update` (reboot if asked).

2. **Point apt at the new release** (example: bookworm → trixie):

   ```bash
   sudo sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
   grep -rn 'bookworm' /etc/apt/sources.list.d/ || true
   ```

   Third-party lists: the Caddy repo uses `any-version` — no change needed.
   Anything else that names the codename gets the same sed treatment.

3. **Two-stage upgrade** (per Debian release notes, inside tmux):

   ```bash
   sudo apt update
   sudo apt upgrade --without-new-pkgs -y
   sudo apt full-upgrade -y
   sudo reboot
   ```

   When prompted about changed config files: our repo-managed files are
   *deliberately* modified — keep the local version (option `N`), the drift
   audit will confirm afterwards.

4. **Re-validate the hardening** on the new release:

   ```bash
   sudo sshd -t                        # sshd_config still valid for the new OpenSSH
   sudo ufw status verbose             # firewall survived
   sudo fail2ban-client status sshd    # jail parses logs on the new fail2ban
   journalctl -u caddy -n 30           # caddy healthy
   sudo vps-health                     # NB: exits before the audit's OS-specific bits
   sudo vps-audit
   ```

   The setup scripts will refuse to run right now — that's the OS guard
   doing its job until you bless the new release.

5. **Bless the new release** — one line in `scripts/utils/common.sh`:

   ```bash
   SUPPORTED_CODENAMES=(bookworm trixie)
   ```

   Commit it, and update the "Debian Bookworm" references in `README.md` and
   `CLAUDE.md` in the same commit. Then re-run the deploy scripts once so
   everything is verified end-to-end on the new release:

   ```bash
   sudo bash scripts/setup/00-security-hardening.sh
   sudo bash scripts/setup/21-caddy.sh
   sudo bash scripts/setup/01-maintenance.sh
   ```

## Verify

- `cat /etc/os-release` shows the new codename; `uname -r` the new kernel.
- `sudo vps-health` and `sudo vps-audit` both exit 0.
- From home: SSH, `https://home.peterek.net`, and the VPN all work.

## Rollback / Recovery

Debian has **no supported in-place downgrade**. The escape hatch is
[rebuild-from-scratch.md](rebuild-from-scratch.md) on an image of the *old*
release, restoring the pre-upgrade snapshot — which is why the snapshot pull
is a hard prerequisite. For a single misbehaving service, check whether the
new release changed its config format (release notes) before suspecting the
upgrade as a whole.
