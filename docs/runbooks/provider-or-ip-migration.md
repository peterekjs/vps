# Provider / IP migration

## When to use

Moving to a new VPS provider, or the existing VPS got a new public IP.
For a provider move, first complete
[rebuild-from-scratch.md](rebuild-from-scratch.md) on the new box — this
runbook is the cutover that follows. For an in-place IP change, start here
directly.

## Prerequisites

- New box rebuilt and healthy (provider move), or new IP known (in-place).
- Access to the DNS zone (Cloudflare dashboard — records are **grey-cloud /
  DNS-only** per ADR 0001; keep them that way).
- List of WireGuard peers: `sudo bash scripts/wireguard/info.sh list`.

## Steps

1. **Lower DNS TTLs ahead of time** (ideally a day before): set the A
   records for `home.peterek.net`, `agent.peterek.net`, `llm.peterek.net`
   to TTL 300.

2. **Run old and new in parallel** (provider move): keep the old box up
   until every peer and DNS record points at the new one.

3. **Update DNS**: point all three A records at the new IP. Confirm:

   ```bash
   dig +short home.peterek.net agent.peterek.net llm.peterek.net
   ```

4. **Update every WireGuard peer's endpoint** — peers dial the VPS, so each
   peer config needs `Endpoint = <new-ip>:51830`:

   | Peer | Where its config lives |
   |---|---|
   | HOME (UniFi) | UniFi Network → VPN Client for the site-to-site tunnel |
   | STUDIO | its local wg config / WireGuard app |
   | phones etc. | re-issue: `sudo bash scripts/wireguard/info.sh <peer> --qr` after updating the server endpoint (next step) |

   Update the endpoint the server records for newly generated peer configs:

   ```bash
   echo '<new-ip>:51830' | sudo tee /etc/wireguard/wg0.d/server/endpoint
   ```

5. **Certificates re-issue themselves**: once DNS resolves to the new box,
   Caddy's HTTP-01 renewals just work. If `/var/lib/caddy` was restored,
   existing certs remain valid regardless of IP — nothing to do. Watch:

   ```bash
   journalctl -u caddy -f
   ```

6. **Decommission the old box** (provider move) once Verify passes:
   final `scripts/home/pull-backups.sh` against the old IP, then destroy it
   at the provider (its disk holds WireGuard keys — use the provider's
   secure-delete if offered).

## Verify

```bash
dig +short home.peterek.net        # → new IP (repeat for all three)
sudo wg show                        # handshakes from HOME + STUDIO resume
curl -I https://home.peterek.net && curl -I https://agent.peterek.net
sudo vps-health; echo "rc=$?"       # 0
```

From home: VPN routes to `192.168.40.0/24` / `192.168.60.0/24` work, Home
Assistant reachable via `https://home.peterek.net`.

## Rollback / Recovery

While the old box still runs, rollback is cheap: point the A records back at
the old IP and revert each peer's `Endpoint`. That window is why
decommissioning is the **last** step — never destroy the old box before
Verify passes on the new one.
