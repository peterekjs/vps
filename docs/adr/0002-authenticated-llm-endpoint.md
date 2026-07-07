# 2. Public authenticated LLM endpoint (llm.peterek.net) with auth at the Caddy edge

Date: 2026-07-07

## Status

Accepted

## Context

Ollama runs on STUDIO (the Mac Studio; `192.168.40.10` on the home LAN,
`10.9.0.4` as its own WireGuard peer) and must be reachable by **third-party
hosted services and browser-based clients** that cannot join WireGuard.
Personal devices are all WireGuard peers already and never needed a public
endpoint — the public hostname exists solely for clients outside the tunnel.

Ollama has **no built-in authentication**, so the ADR 0001 pattern — no
proxy-level auth, the backend validates every request — is impossible here.
ADR 0001 anticipated this: "if that assumption ever breaks, revisit (add a
shared-secret check … at Caddy)."

## Decision

Add `llm.peterek.net` to the Caddyfile, proxying to
`http://192.168.40.10:11434` over the HOME peer's advertised
`192.168.40.0/24` — the same path as the agent endpoint, chosen over the
direct STUDIO peer (`10.9.0.4`) because reliability then depends on the
always-on router, not a desktop WireGuard client surviving sleep/wake.

Authentication happens **at the edge** (a deliberate divergence from ADR 0001,
forced by Ollama's lack of auth):

- **Per-client bearer keys**: clients send `Authorization: Bearer <key>`; a
  Caddy header matcher ORs the allowed keys; everything else gets a bare 401.
  Per-client (not shared) so a leak is attributable and revocable alone.
- **Keys live outside git**: the Caddyfile references `{$LLM_KEY_*}`
  placeholders; actual values sit in a root-only env file on the VPS
  (`/etc/caddy/caddy.env`), wired in via a systemd drop-in. The deploy script
  generates the first key and never overwrites the file.
- **Inference-only path allowlist**: `/v1/*` (OpenAI-compatible) plus native
  inference paths (`/api/chat`, `/api/generate`, `/api/embed`,
  `/api/embeddings`, `/api/tags`, `/api/show`). Model-management endpoints
  (`/api/pull`, `/api/delete`, `/api/create`, `/api/push`, `/api/copy`) are
  blocked so a leaked key can burn GPU time but cannot delete models or fill
  the Mac's disk.
- **CORS with pinned origins**: browser clients exist, so Caddy answers
  `OPTIONS` preflights unauthenticated (they reach nothing) and allows only an
  explicit origin list committed in the Caddyfile. Onboarding a new web app
  is a deliberate two-line change (origin pin + key).
- **Access log + fail2ban jail**: per-site access log (Caddy redacts
  `Authorization` by default) and a jail banning repeated 401/403s. The jail
  ships as a `jail.d/` drop-in deployed by `21-caddy.sh` — not in
  `jail.local` — so `00-security-hardening.sh` on a fresh box never references
  a Caddy log that does not exist yet.

## Consequences

- **Ollama binds beyond localhost** on the Mac (`OLLAMA_HOST=0.0.0.0` /
  the app's network toggle), so anyone on the home LAN can use it
  unauthenticated. Accepted — same LAN trust level as the agent backend.
- **Browser clients store keys in the browser** (e.g. localStorage of a chat
  UI). Keys are therefore treated as leakable; per-client keys and the
  inference-only allowlist bound the damage to attributable GPU-time burn.
- Two endpoints on the same box now follow two auth models: agent = backend
  validates, llm = edge validates. `CONTEXT.md` records both patterns
  (**Edge auth**) so the asymmetry reads as deliberate.
- Rejected alternatives:
  - *WireGuard-only access* — defeats the point; the clients cannot join.
  - *Routing via the STUDIO peer* (`10.9.0.4`) — end-to-end encrypted but
    hostage to a desktop VPN client's uptime.
  - *Full API passthrough* — a leaked key could pull/delete models.
  - *Wildcard CORS* — pinned origins chosen; slightly tighter against a
    stolen-key-in-browser rider at the cost of a Caddyfile edit per web app.
  - *Basic auth / mTLS* — LLM integrations expect an API-key field; hosted
    services cannot present client certs.
  - *Rate-limit plugin* — requires a custom xcaddy build, breaking ADR 0001's
    plain-apt Caddy with unattended upgrades.
