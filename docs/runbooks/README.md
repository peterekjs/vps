# Runbooks

Operational guides for this VPS. Every workflow that touches the running
server has one — if you're about to do something and there's no runbook for
it, write one as part of the change (repo convention, see `CLAUDE.md`).

## The maintenance model on one page

- **The repo is the configuration.** Anything in `config/` + `scripts/` is
  reproducible: deploy scripts copy it to system paths, the drift audit
  verifies it stayed there. Never hand-edit deployed configs without
  reconciling the repo.
- **Snapshots are identity & secrets.** `vps-backup` captures only what the
  repo *cannot* regenerate (WireGuard keys, SSH host keys, ACME state, LLM
  API keys), encrypted to an age public key whose private half lives only at
  home. Home pulls them; the VPS holds no credentials to anything else.
- **Timers watch, HA pages.** `vps-health` (daily), `vps-audit` (weekly) and
  `vps-backup` (daily) run via systemd timers and push findings to Home
  Assistant over WireGuard. Quiet means healthy — mostly. Check in manually
  once in a while.
- **One deliberate routine:** `vps-update`, run by a human, roughly monthly.
  Everything else is automatic.
- Exit codes everywhere: `0` ok · `1` warnings · `2` critical.

## Which runbook do I need?

| Situation | Runbook |
|---|---|
| HA alert / want to check on the box | [health-monitoring.md](health-monitoring.md) |
| Snapshots, pulling them home, restoring | [backup-and-restore.md](backup-and-restore.md) |
| Audit reported DRIFT / I changed something by hand | [drift-audit.md](drift-audit.md) |
| Monthly patching, reboot-required warning | [updates-and-patching.md](updates-and-patching.md) |
| Can't SSH in | [lockout-recovery.md](lockout-recovery.md) |
| VPS died / compromised / starting fresh | [rebuild-from-scratch.md](rebuild-from-scratch.md) |
| New Debian release is out | [debian-release-upgrade.md](debian-release-upgrade.md) |
| New provider or public IP | [provider-or-ip-migration.md](provider-or-ip-migration.md) |
| Exposing a new service / adding a WG peer | [add-a-service.md](add-a-service.md) |
| Plex on the NAS not reachable from outside | [plex-remote-access.md](plex-remote-access.md) |

## Runbook skeleton (the convention)

Every runbook has exactly these sections:

```
When to use → Prerequisites → Steps → Verify → Rollback/Recovery
```

Steps are copy-pasteable commands, not prose descriptions of commands.
