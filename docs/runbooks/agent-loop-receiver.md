# agent-loop webhook receiver

## When to use

Setting up, updating, or rotating secrets for the GitHub App webhook receiver
that drives the private agent-loop hub (`peterekjs/agent-loop`). The receiver
is a zero-dependency Node service on this VPS (`agent-loop-receiver.service`,
loopback port 8812) fronted by Caddy as `agent-loop.peterek.net`. It verifies
each delivery's HMAC and forwards matching label events as
`repository_dispatch` to the hub; it holds no state. Design:
[agent-loop ADR 0001](https://github.com/peterekjs/agent-loop/blob/main/docs/adr/0001-webhook-dispatch-hub.md).

## Prerequisites

- A GitHub App owned by `peterekjs` (created once, see *Steps — first install*).
- DNS: `agent-loop.peterek.net` A record → VPS IP, **grey-cloud / DNS-only**
  (ADR 0001 — HTTP-01).
- `scripts/setup/21-caddy.sh` already deployed once (Caddy running).

## Steps — first install

1. **Create the GitHub App** (Settings → Developer settings → GitHub Apps):
   - Webhook URL `https://agent-loop.peterek.net/webhook`; webhook secret:
     leave for step 4.
   - Repository permissions: Contents **write**, Issues **write**, Pull
     requests **write**, Workflows **write**, Metadata **read**,
     Administration **read**.
   - Subscribe to events: **Issues**, **Pull request**.
   - Where can it be installed: **Any account**.
   - Generate a private key (downloads `*.pem`). Note the **App ID**.
2. **Run the setup script** — the first run generates a deploy key and stops:

   ```bash
   sudo bash scripts/setup/31-agent-loop-receiver.sh
   ```

   Add the printed public key as a read-only *Deploy key* on
   `peterekjs/agent-loop` → Settings → Deploy keys. Re-run the script: it
   clones the hub to `/opt/agent-loop`, creates `/etc/agent-loop-receiver/env`
   with a fresh `WEBHOOK_SECRET`, and stops again asking for the App key.
3. **Install the App key and id:**

   ```bash
   sudo install -m 600 /path/to/downloaded.pem /etc/agent-loop-receiver/app.pem
   sudoedit /etc/agent-loop-receiver/env        # set APP_ID
   sudo bash scripts/setup/31-agent-loop-receiver.sh
   ```

   The service starts and `/health` answers.
4. **Webhook secret:** copy `WEBHOOK_SECRET` from `/etc/agent-loop-receiver/env`
   into the App's webhook settings.
5. **Expose through Caddy:** the site block is already in
   `config/caddy/Caddyfile`; deploy it:

   ```bash
   sudo bash scripts/setup/21-caddy.sh
   ```

6. **Install the App** on `peterekjs` (include `agent-loop`) and on
   `nexial-ventures` (all repositories, or the ones to cover).
7. **Ping:** App settings → Advanced → Recent deliveries → *Redeliver* the
   ping. The response body must be `pong`.
8. **Hub side** (secrets on `peterekjs/agent-loop`, runners): follow the hub
   README. Nothing else on the VPS.

## Steps — update the receiver code

```bash
sudo bash scripts/setup/31-agent-loop-receiver.sh            # main
sudo bash scripts/setup/31-agent-loop-receiver.sh --ref v1.2 # pinned
```

Tests run from the new checkout before the service restarts; a failing suite
leaves the running service untouched.

## Steps — rotate a secret

| Secret | Where | Then |
|---|---|---|
| Webhook secret | `WEBHOOK_SECRET` in `/etc/agent-loop-receiver/env` **and** the App's webhook settings | `sudo systemctl restart agent-loop-receiver` |
| App private key | generate a new one in the App settings, replace `/etc/agent-loop-receiver/app.pem`, revoke the old key; also update `APP_PRIVATE_KEY` on the hub repo | `sudo systemctl restart agent-loop-receiver` |
| Deploy key | delete `/etc/agent-loop-receiver/deploy_key*`, re-run the setup script, swap the key on GitHub | re-run the setup script |

## Verify

`vps-health` checks the unit is active and `/health` answers `ok` on every
daily run and pages a critical finding otherwise — see
[health-monitoring.md](health-monitoring.md). GitHub never retries a failed
delivery; labels applied during an outage are only recovered by the hub's
hourly sweep, so treat that alert as urgent.

```bash
curl -fsS http://127.0.0.1:8812/health                 # ok
curl -I https://agent-loop.peterek.net/health          # 200 with a LE cert
sudo journalctl -u agent-loop-receiver -n 20           # "listening on 127.0.0.1:8812"
sudo vps-audit; echo "rc=$?"                           # unit tracked in CONFIG_MAP
sudo vps-backup --dry-run                              # /etc/agent-loop-receiver listed
```

Add `agent:implement` to a test issue in a repo the App covers: the App's
Recent deliveries shows a `202 dispatched implement`, and a run appears in
`peterekjs/agent-loop` → Actions. A `502` means the hub rejected the dispatch
— check the journal; redeliver from the App page once fixed.

## Rollback / Recovery

```bash
sudo systemctl disable --now agent-loop-receiver
sudo rm /etc/systemd/system/agent-loop-receiver.service && sudo systemctl daemon-reload
```

Remove the `agent-loop.peterek.net` block from `config/caddy/Caddyfile` and
re-run `21-caddy.sh`; delete the DNS record. `/etc/agent-loop-receiver/`
(deploy key, env, App key) is in `BACKUP_PATHS`, so a rebuilt VPS restores it
with `vps-restore`; `/opt/agent-loop` is re-cloned by the setup script.
