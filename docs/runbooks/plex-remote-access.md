# Plex remote access

## When to use

Setting up (or repairing) remote access to the Plex Media Server on the QNAP
NAS (`192.168.60.10:32400`) through the VPS. The home connection cannot
accept inbound port forwards, so remote Plex clients reach the server via
`https://plex.peterek.net`, which Caddy proxies over WireGuard to the NAS.
Plex calls this the "custom server access URL" method: the NAS publishes the
URL to plex.tv, and every Plex app receives it as a connection candidate
alongside the (unreachable) direct one.

## Prerequisites

- HOME WireGuard peer up (it advertises `192.168.60.0/24` — same route Home
  Assistant already uses).
- DNS: `plex.peterek.net` A record → VPS public IP, **grey-cloud / DNS-only**
  (ADR 0001 — HTTP-01 breaks behind the Cloudflare proxy).
- Admin access to the Plex web UI on the NAS and to QTS (QNAP firewall).
- Repo checkout on the VPS at `/opt/vps` (or wherever `REPO_DIR` points).

## Steps

1. **Reachability from the VPS** (before touching Caddy):

   ```bash
   curl -s --max-time 5 http://192.168.60.10:32400/identity | head -c 200
   ```

   Expect an XML `<MediaContainer ... machineIdentifier=...>`. A timeout means
   the QNAP firewall (QuFirewall) or Plex's own network filter rejects the VPS.
   In QTS → QuFirewall add an allow rule for source `10.9.0.1/32` (the VPS's
   WireGuard address) to TCP 32400, then retry.

2. **Deploy the Caddy site block** (already in `config/caddy/Caddyfile`):

   ```bash
   cd /opt/vps && git pull
   sudo bash scripts/setup/21-caddy.sh
   journalctl -u caddy -n 50 --no-pager      # watch the plex.peterek.net cert issue
   ```

3. **Point Plex at the public URL** — Plex web UI on the NAS →
   *Settings → Network* (click *Show Advanced*):

   - **Custom server access URLs:** `https://plex.peterek.net:443`
     (the `:443` is required — Plex otherwise assumes port 32400).
   - **Secure connections:** `Preferred`. `Required` also works because the
     custom URL is HTTPS, but leaves LAN clients without a fallback if the
     plex.direct certificate ever fails to renew.
   - **LAN Networks:** leave as is. Clients arriving through the VPS appear as
     `10.9.0.1`, i.e. *remote*, so remote-quality limits apply to them —
     which is the intent.
   - Save.

4. **Remote Access page** (*Settings → Remote Access*): leave it *disabled*.
   Enabling it makes plex.tv probe the home WAN IP, which fails and paints the
   page red, but has no effect on clients — they use the custom URL either
   way. Enable it only if a real home port forward exists later.

## Verify

```bash
# On the VPS — TLS + Caddy + tunnel + NAS in one call:
curl -s https://plex.peterek.net/identity | head -c 200

# Health/audit pick the new hostname up automatically:
sudo vps-health            # "cert plex.peterek.net: N days until expiry"
sudo vps-audit; echo "rc=$?"
```

End-to-end: on a phone with Wi-Fi off, open the Plex app → the server shows
as available; while playing something, *Settings → Dashboard* on the NAS
lists the stream as **Remote**. The HTTPS certificate of the connection in
the Plex web app (`app.plex.tv` → server → *Settings → Network* → the
connection list) should be the Let's Encrypt one for `plex.peterek.net`.

## Rollback / Recovery

- Client can't find the server remotely: check
  `curl https://plex.peterek.net/identity` first. `502` = tunnel or NAS side
  (`sudo vps-health`, then step 1). `404`/timeout on the hostname = DNS or
  Caddy (`systemctl status caddy`, `journalctl -u caddy`).
- To withdraw: clear *Custom server access URLs* on the NAS, remove the
  `plex.peterek.net` block from `config/caddy/Caddyfile`, re-run
  `scripts/setup/21-caddy.sh`, delete the DNS record.
