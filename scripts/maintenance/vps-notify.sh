#!/usr/bin/env bash
# vps-notify — send a notification by email (and optionally to a Home
# Assistant webhook).
#
# Usage:
#   vps-notify [--severity info|ok|warning|critical] [--title <title>] <message>
#
# Channels, read from /etc/vps-maintenance.conf:
#   email    — MAIL_TO + SMTP_URL + SMTP_USER + SMTP_PASS (curl smtps; the
#              primary channel: it does not depend on WireGuard, so it still
#              works when the tunnel itself is what broke)
#   webhook  — HA_WEBHOOK_URL (optional, reached over WireGuard)
# Every configured channel is tried. Exit codes: 0 at least one channel
# delivered, 1 usage error / no channel configured, 2 every channel failed.
# See docs/runbooks/health-monitoring.md.

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
HOST="$(hostname)"

email_configured() {
  [[ -n "${MAIL_TO}" && -n "${SMTP_URL}" && -n "${SMTP_USER}" && -n "${SMTP_PASS}" ]]
}
webhook_configured() { [[ -n "${HA_WEBHOOK_URL}" ]]; }

if [[ -n "${MAIL_TO}${SMTP_USER}${SMTP_PASS}" ]] && ! email_configured; then
  log_warn "Email channel partially configured — MAIL_TO, SMTP_URL, SMTP_USER and SMTP_PASS are all required; skipping email"
fi
if ! email_configured && ! webhook_configured; then
  log_error "No notification channel configured in ${VPS_MAINT_CONF} — set MAIL_TO/SMTP_* (and/or HA_WEBHOOK_URL)."
  exit 1
fi

# --- email -------------------------------------------------------------------
send_email() {
  local subject msg_file curl_cfg
  subject="[$(printf '%s' "${SEVERITY}" | tr '[:lower:]' '[:upper:]')] ${TITLE} (${HOST})"
  # Strip CR/LF from header values so a crafted title cannot inject headers.
  subject="${subject//$'\r'/}"; subject="${subject//$'\n'/ }"

  msg_file="$(mktemp)"
  curl_cfg="$(mktemp)"
  # shellcheck disable=SC2064  # expand now: the paths are fixed at this point
  trap "rm -f '${msg_file}' '${curl_cfg}'" RETURN
  chmod 600 "${msg_file}" "${curl_cfg}"

  {
    printf 'From: %s\r\n' "${MAIL_FROM:-${SMTP_USER}}"
    printf 'To: %s\r\n' "${MAIL_TO}"
    printf 'Subject: %s\r\n' "${subject}"
    printf 'Date: %s\r\n' "$(date -R)"
    printf 'Message-ID: <%s.%s@%s>\r\n' "$(date +%s)" "$$" "${HOST}"
    printf 'MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n'
    printf 'X-VPS-Severity: %s\r\n' "${SEVERITY}"
    printf '\r\n'
    printf '%s\r\n' "${MESSAGE//$'\n'/$'\r\n'}"
    printf '\r\n-- \r\nvps-notify on %s, %s\r\n' "${HOST}" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  } > "${msg_file}"

  # Credentials go through a config file, never argv (visible in `ps`).
  local user_esc="${SMTP_USER//\\/\\\\}" pass_esc="${SMTP_PASS//\\/\\\\}"
  user_esc="${user_esc//\"/\\\"}"; pass_esc="${pass_esc//\"/\\\"}"
  printf 'user = "%s:%s"\n' "${user_esc}" "${pass_esc}" > "${curl_cfg}"

  local rcpt_args=()
  local rcpt
  for rcpt in ${MAIL_TO//,/ }; do rcpt_args+=(--mail-rcpt "${rcpt}"); done

  if curl -sS -m 30 --ssl-reqd --url "${SMTP_URL}" \
       --config "${curl_cfg}" \
       --mail-from "${MAIL_FROM:-${SMTP_USER}}" "${rcpt_args[@]}" \
       --upload-file "${msg_file}" >/dev/null; then
    log_success "Email sent (${SEVERITY}) to ${MAIL_TO}: ${TITLE}"
    return 0
  fi
  log_error "Failed to send email via ${SMTP_URL}"
  return 1
}

# --- webhook -----------------------------------------------------------------
json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  printf '%s' "${s}"
}

send_webhook() {
  local payload
  payload=$(printf '{"title":"%s","message":"%s","severity":"%s","host":"%s"}' \
    "$(json_escape "${TITLE}")" \
    "$(json_escape "${MESSAGE}")" \
    "$(json_escape "${SEVERITY}")" \
    "$(json_escape "${HOST}")")
  if curl -fsS -m 10 -H 'Content-Type: application/json' \
       -d "${payload}" "${HA_WEBHOOK_URL}" >/dev/null; then
    log_success "Webhook notification sent (${SEVERITY}): ${TITLE}"
    return 0
  fi
  log_error "Failed to deliver webhook notification to ${HA_WEBHOOK_URL}"
  return 1
}

# --- dispatch ----------------------------------------------------------------
delivered=0
if email_configured;   then send_email   && delivered=1; fi
if webhook_configured; then send_webhook && delivered=1; fi

if [[ "${delivered}" -eq 1 ]]; then
  exit 0
fi
log_error "Notification not delivered on any channel"
exit 2
