#!/usr/bin/env bash
# add-peer.sh — Add a new peer to an existing WireGuard server.
#
# Usage:
#   sudo bash scripts/wireguard/add-peer.sh [options]
#
# Options:
#   --config <name>     WG instance to modify (auto-detected if exactly one exists)
#   --name <peer>       Peer name (used for filenames and config comments)
#   --ip <CIDR>         Peer's VPN address, e.g. 10.9.0.5/32 (default: next free)
#   --routes <list>     Client-side AllowedIPs (default: 0.0.0.0/0, ::/0 — full tunnel)
#   --no-print          Don't print the resulting client config to stdout
#   -h, --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"
# shellcheck source=scripts/utils/wireguard.sh
source "${SCRIPT_DIR}/../utils/wireguard.sh"

NAME=""
PEER=""
PEER_IP=""
ROUTES=""
PRINT=1

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)   NAME="$2";    shift 2 ;;
    --name)     PEER="$2";    shift 2 ;;
    --ip)       PEER_IP="$2"; shift 2 ;;
    --routes)   ROUTES="$2";  shift 2 ;;
    --no-print) PRINT=0;      shift   ;;
    -h|--help)  usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

require_root
require_debian_bookworm
wg_require_tools

NAME="$(wg_resolve_instance "${NAME}")"
wg_require_instance "${NAME}"

section "Adding peer to ${NAME}"

# ---------------------------------------------------------------------------
# Peer name
# ---------------------------------------------------------------------------
if [[ -z "${PEER}" ]]; then
  read -r -p "Peer name (e.g. laptop, phone): " PEER
fi
PEER="$(wg_sanitize_name "${PEER}")"
if [[ -z "${PEER}" ]]; then
  log_error "Peer name is required"
  exit 1
fi

PDIR="$(wg_peer_dir "${NAME}" "${PEER}")"
if [[ -d "${PDIR}" ]]; then
  log_error "Peer '${PEER}' already exists at ${PDIR}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Peer IP
# ---------------------------------------------------------------------------
suggested="$(wg_next_peer_ip "${NAME}" || true)"
if [[ -z "${PEER_IP}" ]]; then
  if [[ -n "${suggested}" ]]; then
    read -r -p "Peer VPN address [${suggested}]: " input
    PEER_IP="${input:-${suggested}}"
  else
    read -r -p "Peer VPN address (e.g. 10.9.0.5/32): " PEER_IP
  fi
fi
if [[ -z "${PEER_IP}" ]]; then
  log_error "Peer IP is required"
  exit 1
fi
[[ "${PEER_IP}" == */* ]] || PEER_IP="${PEER_IP}/32"

# Refuse duplicate AllowedIPs already in the server config
ip_no_mask="${PEER_IP%%/*}"
if grep -E '^[[:space:]]*AllowedIPs[[:space:]]*=' "$(wg_config_path "${NAME}")" \
    | grep -qE "(^|[[:space:],])${ip_no_mask//./\\.}/"; then
  log_error "${ip_no_mask} is already assigned to another peer."
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate keys & metadata
# ---------------------------------------------------------------------------
wg_gen_keypair "${PDIR}"
echo "${PEER_IP}" > "${PDIR}/address"
chmod 600 "${PDIR}/address"
if [[ -n "${ROUTES}" ]]; then
  echo "${ROUTES}" > "${PDIR}/client_allowed_ips"
  chmod 600 "${PDIR}/client_allowed_ips"
fi
PEER_PUB="$(cat "${PDIR}/public.key")"

# ---------------------------------------------------------------------------
# Append the [Peer] block to the server config
# ---------------------------------------------------------------------------
CFG="$(wg_config_path "${NAME}")"
backup_file "${CFG}" >/dev/null

{
  printf '\n# %s\n' "${PEER}"
  printf '[Peer]\n'
  printf 'PublicKey = %s\n' "${PEER_PUB}"
  printf 'AllowedIPs = %s\n' "${PEER_IP}"
} >> "${CFG}"
chmod 600 "${CFG}"
log_success "Appended [Peer] ${PEER} (${PEER_IP}) to ${CFG}"

# ---------------------------------------------------------------------------
# Render client config & sync running interface
# ---------------------------------------------------------------------------
wg_render_client_config "${NAME}" "${PEER}" > "${PDIR}/client.conf"
chmod 600 "${PDIR}/client.conf"
log_success "Client config saved to ${PDIR}/client.conf"

wg_sync "${NAME}"

# ---------------------------------------------------------------------------
# Print the client config
# ---------------------------------------------------------------------------
if [[ "${PRINT}" -eq 1 ]]; then
  section "Client configuration for '${PEER}' — copy/paste into the device"
  cat "${PDIR}/client.conf"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    section "QR code (scan from the WireGuard mobile app)"
    qrencode -t ansiutf8 < "${PDIR}/client.conf"
  fi
fi
