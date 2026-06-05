# 1. Native Caddy with HTTP-01, replacing Traefik and removing Cloudflare from the path

Date: 2026-06-05

## Status

Accepted

## Context

The VPS ran **Traefik** in Docker as the edge reverse proxy, obtaining
Let's Encrypt certs via the **DNS-01** challenge using a **Cloudflare API token**.
Traefik was never tracked in this repo — it was unmanaged drift.

Only two routes ever mattered: `home.peterek.net` → `192.168.60.20:8123`
(Home Assistant, via the file provider) and a new requirement,
`agent.peterek.net` → `192.168.40.10:8811` (webhooks to a home-LAN host reached
over WireGuard via the HOME peer's advertised `192.168.40.0/24`).
n8n did not use Traefik (direct `:5678` over WireGuard) and is being
decommissioned. The remaining Traefik-routed services have no value.

The operator wants to **completely break away from Cloudflare for this VPS** —
no API token, no Cloudflare proxy (orange cloud) in the request path. The DNS
zone may remain hosted at Cloudflare, but must not be relied upon at runtime.

## Decision

Replace Traefik with **Caddy installed natively from the official apt repo**,
managed by systemd, deployed by `scripts/setup/21-caddy.sh` from a
version-controlled `config/caddy/Caddyfile`.

- Certificates via Let's Encrypt using the **HTTP-01** challenge (port 80
  publicly reachable). ACME contact: `jiri@peterek.net`.
- DNS records are **grey-cloud / DNS-only**; Caddy terminates TLS on the VPS.
- Two static routes: `home.peterek.net` and `agent.peterek.net`.
  `agent.peterek.net` is a plain `reverse_proxy` to `http://10.9.0.4:8811`.
- UFW explicitly allows `80,443/tcp` (replacing Traefik's Docker iptables
  bypass with an auditable firewall rule).
- Cutover: open UFW 80/443 → install Caddy with both routes → **park** Traefik
  (stop, don't delete) → start Caddy → verify both routes issue certs and
  serve → then remove Traefik. Traefik stays available as a warm rollback
  during the verification window.

## Consequences

- **Lost:** Traefik's Docker-label auto-discovery. New web services must be
  added to the Caddyfile explicitly (acceptable — services are added via this
  repo and rarely).
- **Gained:** dramatically simpler, auditable config; no Cloudflare API token;
  TLS owned end-to-end on the VPS; firewall rules that match the repo's
  "default-deny, allow explicitly" philosophy.
- **Trade-off accepted:** HTTP-01 requires port 80 reachable and cannot issue
  wildcards. Neither is needed here.
- **Load-bearing security assumption:** `agent.peterek.net` is public and
  forwards over WireGuard with **no proxy-level authentication** — the service
  on `192.168.40.10:8811` MUST validate every webhook (signature/secret).
  If that assumption ever breaks, revisit (add a shared-secret check or source
  IP allowlist at Caddy).
- **Backend availability:** the agent backend (`192.168.40.10`) is treated as
  always-on; if it is offline, webhooks return 502 and may be lost. A buffering
  layer is explicitly out of scope for now.
- Considered and rejected: keeping Traefik (heavier config the operator wanted
  to leave); Caddy in Docker (reintroduces the UFW bypass); `caddy-docker-proxy`
  (only worth it with many dockerized web services); DNS-01 on Caddy (needs a
  custom build with the cloudflare plugin and keeps the Cloudflare dependency).
