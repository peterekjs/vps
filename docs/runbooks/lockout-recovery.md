# Lockout recovery

## When to use

You can't SSH into the VPS. Don't panic-reinstall — most lockouts are one of
four causes, and three of them are fixable in minutes via the provider
console.

## Prerequisites

- Provider console credentials stored somewhere that is **not** behind the
  VPN or on the VPS (password manager). If you don't have console access
  ready, sort that *now*, while things work.

## Steps — diagnose first (from home)

```bash
ping -c 3 <vps-ip>            # box up at all?
nc -zv <vps-ip> 22            # SSH port reachable?
ssh -v <user>@<vps-ip>        # where does the handshake stop?
```

Interpretation:

| Symptom | Likely cause | Go to |
|---|---|---|
| ping dead, console shows box down | provider/host issue | provider status page, reboot from panel |
| port 22 times out from *your* IP but works from another (phone hotspot) | **fail2ban self-ban** | fix 1 |
| port open, `Permission denied (publickey)` | **key/auth problem** | fix 2 |
| port open, connection drops immediately | **sshd config broken** | fix 3 |
| port 22 unreachable from everywhere, box up | **firewall mistake** | fix 4 |

### Fix 1 — fail2ban banned your IP

From another IP (phone hotspot) or the provider console:

```bash
sudo fail2ban-client status sshd            # is your IP in the list?
sudo fail2ban-client set sshd unbanip <your-ip>
```

Bans expire after 24 h anyway (`bantime` in `config/fail2ban/jail.local`).

### Fix 2 — key loss / auth failure

Log in through the provider console (VNC/serial). Note: console login is
local PAM, **not** sshd — a root password still works there even though SSH
password auth is disabled. No root password ever set? Use the provider's
rescue mode / root-password-reset feature.

```bash
ls -la ~<user>/.ssh/authorized_keys      # present? owned by the user? mode 600?
cat >> ~<user>/.ssh/authorized_keys      # paste your current public key
chmod 700 ~<user>/.ssh && chmod 600 ~<user>/.ssh/authorized_keys
```

### Fix 3 — sshd config broken

Provider console:

```bash
sudo sshd -t                             # shows the exact config error
ls /etc/ssh/sshd_config.bak.*            # every deploy left a backup
sudo cp /etc/ssh/sshd_config.bak.<newest> /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart ssh
```

### Fix 4 — firewall mistake

Provider console:

```bash
sudo ufw status numbered                 # is 22/tcp (or your SSH port) allowed?
sudo ufw allow 22/tcp comment "SSH"
# nuclear option while you sort it out:
sudo ufw disable                         # re-enable immediately after fixing
```

## Verify

From home, in a **new** terminal: `ssh <user>@<vps-ip>` works. Then
`sudo vps-audit` — it flags anything the emergency surgery left drifted
(e.g. a temporary ufw rule or restored sshd_config), and
[drift-audit.md](drift-audit.md) says how to reconcile.

## Rollback / Recovery — prevention habits

- **The second-session rule:** after *any* change to sshd, UFW, or fail2ban,
  verify a fresh SSH login in a second terminal **before** closing the one
  that made the change. Every script in this repo warns about this; the
  habit is yours to keep.
- Keep provider console credentials outside the VPN.
- Don't remove the `.bak.<ts>` files the deploy scripts create — they're the
  fix-3 escape hatch.
- Total loss of access (console included) →
  [rebuild-from-scratch.md](rebuild-from-scratch.md).
