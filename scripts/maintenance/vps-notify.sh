#!/usr/bin/env bash
# vps-notify — send a JSON notification to the Home Assistant webhook.
#
# Usage:
#   vps-notify [--severity info|ok|warning|critical] [--title <title>] <message>
#
# Reads HA_WEBHOOK_URL from /etc/vps-maintenance.conf. The webhook is reached
# over WireGuard; the HA-side automation is documented in
# docs/runbooks/health-monitoring.md. Exit codes: 0 sent, 1 usage/config
# error, 2 delivery failure.

set -euo pipefail
# shellcheck source=scripts/maintenance/lib.sh
source "${VPS_MAINT_LIB:-/usr/local/lib/vps-maintenance/lib.sh}"

SEVERITY="info"
TITLE="VPS notification"
MESSAGE=""

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --severity) SEVERITY="$2"; shift 2 ;;
    --title)    TITLE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          MESSAGE="$1"; shift ;;
  esac
done

if [[ -z "${MESSAGE}" ]]; then
  log_error "No message given."
  usage
  exit 1
fi

load_conf
if [[ -z "${HA_WEBHOOK_URL}" ]]; then
  log_error "HA_WEBHOOK_URL is not set in ${VPS_MAINT_CONF} — cannot notify."
  exit 1
fi

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  printf '%s' "${s}"
}

payload=$(printf '{"title":"%s","message":"%s","severity":"%s","host":"%s"}' \
  "$(json_escape "${TITLE}")" \
  "$(json_escape "${MESSAGE}")" \
  "$(json_escape "${SEVERITY}")" \
  "$(json_escape "$(hostname)")")

if curl -fsS -m 10 -H 'Content-Type: application/json' \
     -d "${payload}" "${HA_WEBHOOK_URL}" >/dev/null; then
  log_success "Notification sent (${SEVERITY}): ${TITLE}"
else
  log_error "Failed to deliver notification to ${HA_WEBHOOK_URL}"
  exit 2
fi
