#!/usr/bin/env bash
# info.sh — Inspect a WireGuard instance.
#
# Usage:
#   sudo bash scripts/wireguard/info.sh list [--config <name>]
#   sudo bash scripts/wireguard/info.sh <peer-name> [--config <name>] [--qr]
#
# Options:
#   --config <name>     WG instance (auto-detected if exactly one exists)
#   --qr                Also print the client config as a QR code
#   -h, --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"
# shellcheck source=scripts/utils/wireguard.sh
source "${SCRIPT_DIR}/../utils/wireguard.sh"

NAME=""
QR=0
TARGET=""

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  NAME="$2"; shift 2 ;;
    --qr)      QR=1;      shift   ;;
    -h|--help) usage; exit 0 ;;
    -*)        log_error "Unknown option: $1"; usage; exit 1 ;;
    *)
      if [[ -z "${TARGET}" ]]; then
        TARGET="$1"
      else
        log_error "Unexpected argument: $1"; usage; exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "${TARGET}" ]]; then
  log_error "Specify either 'list' or a peer name."
  usage; exit 1
fi

require_root

NAME="$(wg_resolve_instance "${NAME}")"
wg_require_instance "${NAME}"

if [[ "${TARGET}" == "list" ]]; then
  section "WireGuard instance: ${NAME}"
  if [[ -f "$(wg_server_dir "${NAME}")/address" ]]; then
    log_info "Address:  $(cat "$(wg_server_dir "${NAME}")/address")"
  fi
  if [[ -f "$(wg_server_dir "${NAME}")/endpoint" && -f "$(wg_server_dir "${NAME}")/listen_port" ]]; then
    log_info "Endpoint: $(cat "$(wg_server_dir "${NAME}")/endpoint"):$(cat "$(wg_server_dir "${NAME}")/listen_port")"
  fi
  if systemctl is-active --quiet "wg-quick@${NAME}"; then
    log_info "Status:   active"
  else
    log_warn "Status:   inactive"
  fi

  echo
  printf '  %-24s  %-20s  %s\n' "PEER" "ADDRESS" "LATEST HANDSHAKE"
  printf '  %-24s  %-20s  %s\n' "----" "-------" "----------------"

  # Build a "pubkey -> handshake" map from `wg show` if the interface is up
  declare -A handshakes=()
  if command -v wg >/dev/null 2>&1 && systemctl is-active --quiet "wg-quick@${NAME}"; then
    while read -r pub _ts hs_human; do
      [[ -n "${pub}" ]] && handshakes["${pub}"]="${hs_human}"
    done < <(wg show "${NAME}" latest-handshakes 2>/dev/null \
             | awk '{ if ($2 == 0) print $1, 0, "never"
                      else { cmd="date -d @"$2" +\"%Y-%m-%d %H:%M:%S\""; cmd | getline d; close(cmd); print $1, $2, d } }')
  fi

  shopt -s nullglob
  for pdir in "$(wg_peers_dir "${NAME}")"/*/; do
    peer="$(basename "${pdir}")"
    addr="$(cat "${pdir}address" 2>/dev/null || echo "?")"
    pub="$(cat "${pdir}public.key" 2>/dev/null || echo "")"
    hs="${handshakes[${pub}]:--}"
    printf '  %-24s  %-20s  %s\n' "${peer}" "${addr}" "${hs}"
  done
  echo
  exit 0
fi

# Single-peer mode
PEER="$(wg_sanitize_name "${TARGET}")"
PDIR="$(wg_peer_dir "${NAME}" "${PEER}")"
if [[ ! -d "${PDIR}" ]]; then
  log_error "No peer named '${PEER}' under $(wg_peers_dir "${NAME}")"
  exit 1
fi

CLIENT_CONF="${PDIR}/client.conf"
if [[ ! -f "${CLIENT_CONF}" ]]; then
  # Older state directory may pre-date client.conf — render on demand.
  wg_render_client_config "${NAME}" "${PEER}" > "${CLIENT_CONF}"
  chmod 600 "${CLIENT_CONF}"
fi

section "Client configuration for '${PEER}'"
cat "${CLIENT_CONF}"
echo

if [[ "${QR}" -eq 1 ]]; then
  if command -v qrencode >/dev/null 2>&1; then
    section "QR code"
    qrencode -t ansiutf8 < "${CLIENT_CONF}"
  else
    log_warn "qrencode not installed — install with: apt install qrencode"
  fi
fi
