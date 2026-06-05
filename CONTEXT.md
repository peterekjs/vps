# Context — Glossary

Canonical terms for this VPS infrastructure repo. Definitions only; no implementation details.

## Certificates & ACME

- **CA (Certificate Authority)** — who signs TLS certs. This repo uses **Let's Encrypt**. This is *not* an alternative to "Cloudflare"; the Cloudflare resolver already used Let's Encrypt as its CA.
- **DNS-01 challenge** — proving domain ownership to the CA by creating a DNS TXT record (via the Cloudflare API, in the old Traefik setup). Works without exposing port 80; supports wildcards. Being retired here.
- **HTTP-01 challenge** — proving domain ownership by serving a token over **port 80**, which must be publicly reachable. The chosen method going forward. No Cloudflare API token required.
- **No-Cloudflare-in-path** — design goal: records are grey-cloud (DNS-only), TLS is terminated by Caddy on the VPS itself, and cert issuance uses HTTP-01. Cloudflare may still host the DNS zone, but is never in the request path nor relied on via API.

## Network entities

- **VPS** — the Debian Bookworm host. WireGuard server at `10.9.0.1/24`, public endpoint `37.205.10.203:51830`.
- **Reverse proxy** — the edge HTTP(S) router on the VPS that terminates TLS and forwards to backends. Currently Traefik (unmanaged, not in repo).
- **STUDIO** — the WireGuard peer at `10.9.0.4`; the user's "main computer". Backend for `agent.peterek.net`.
- **HOME** — the WireGuard peer at `10.9.0.2` that advertises the home LAN subnets (incl. `192.168.60.0/24`), making Home Assistant reachable from the VPS.
- **Agent endpoint** — `agent.peterek.net`; public hostname that proxies (currently webhooks) to `10.9.0.4:8811` over WireGuard.
