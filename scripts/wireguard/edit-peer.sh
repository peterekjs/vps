#!/usr/bin/env bash
# edit-peer.sh — Edit an existing peer: re-render its client.conf from a
# template, rotate its keypair, or both.
#
# Without --rotate-keys the peer's stored keys and the server's [Peer] block
# are untouched — only <peer>/client.conf is re-rendered from --template.
# With --rotate-keys the peer's keypair is regenerated, the server config's
# [Peer] PublicKey for this peer is patched in place, and the running
# interface is synced. At least one of --template or --rotate-keys must be
# given.
#
# Usage:
#   sudo bash scripts/wireguard/edit-peer.sh [options]
#
# Options:
#   --config <name>     WG instance to modify (auto-detected if exactly one exists)
#   --name <peer>       Peer name to edit (required)
#   --template <path>   Client config template. Must contain
#                         [Interface] PrivateKey, [Peer] PublicKey and
#                         [Peer] Endpoint placeholder lines — their values
#                         are ignored and replaced from current peer/server
#                         state. Everything else (Address, DNS, MTU,
#                         AllowedIPs, PersistentKeepalive, comments,
#                         PreUp/PostDown, …) is preserved verbatim.
#   --rotate-keys       Rotate the peer's keypair and update the server-side
#                         [Peer] PublicKey + live interface. When given
#                         without --template, only the [Interface] PrivateKey
#                         line in the existing client.conf is updated; any
#                         other custom content in client.conf is preserved.
#   --no-print          Don't print the resulting client config to stdout.
#   -h, --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"
# shellcheck source=scripts/utils/wireguard.sh
source "${SCRIPT_DIR}/../utils/wireguard.sh"

NAME=""
PEER=""
TEMPLATE=""
ROTATE_KEYS=0
PRINT=1

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)       NAME="$2";     shift 2 ;;
    --name)         PEER="$2";     shift 2 ;;
    --template)     TEMPLATE="$2"; shift 2 ;;
    --rotate-keys)  ROTATE_KEYS=1; shift   ;;
    --no-print)     PRINT=0;       shift   ;;
    -h|--help)      usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

require_root
require_debian_supported
wg_require_tools

NAME="$(wg_resolve_instance "${NAME}")"
wg_require_instance "${NAME}"

if [[ -z "${PEER}" ]]; then
  log_error "Peer name is required (--name)"
  exit 1
fi
PEER="$(wg_sanitize_name "${PEER}")"

PDIR="$(wg_peer_dir "${NAME}" "${PEER}")"
if [[ ! -d "${PDIR}" ]]; then
  log_error "Peer '${PEER}' not found at ${PDIR}"
  exit 1
fi

if [[ -z "${TEMPLATE}" && "${ROTATE_KEYS}" -eq 0 ]]; then
  log_error "Nothing to do — pass --template, --rotate-keys, or both"
  exit 1
fi
if [[ -n "${TEMPLATE}" && ! -f "${TEMPLATE}" ]]; then
  log_error "Template not found: ${TEMPLATE}"
  exit 1
fi

section "Editing peer '${PEER}' on ${NAME}"

CFG="$(wg_config_path "${NAME}")"
SDIR="$(wg_server_dir "${NAME}")"
SERVER_PUB="$(cat "${SDIR}/public.key")"
SERVER_ENDPOINT="$(cat "${SDIR}/endpoint"):$(cat "${SDIR}/listen_port")"
TARGET="${PDIR}/client.conf"

if [[ -f "${SDIR}/dns" ]]; then
  DEFAULT_DNS="$(cat "${SDIR}/dns")"
else
  DEFAULT_DNS="${WG_DEFAULT_DNS}"
fi

# ---------------------------------------------------------------------------
# Optionally rotate the peer's keypair and patch the server config
# ---------------------------------------------------------------------------
if [[ "${ROTATE_KEYS}" -eq 1 ]]; then
  OLD_PEER_PUB="$(cat "${PDIR}/public.key")"
  if ! grep -qF "PublicKey = ${OLD_PEER_PUB}" "${CFG}"; then
    log_error "Peer '${PEER}' pubkey not found in ${CFG} — refusing to rotate"
    exit 1
  fi

  log_info "Rotating keypair for ${PEER}"
  wg_gen_keypair "${PDIR}"
  NEW_PEER_PUB="$(cat "${PDIR}/public.key")"

  backup_file "${CFG}" >/dev/null
  wg_replace_peer_pubkey "${CFG}" "${OLD_PEER_PUB}" "${NEW_PEER_PUB}"
  log_success "Server [Peer] PublicKey updated for ${PEER}"
fi

PEER_PRIV="$(cat "${PDIR}/private.key")"

# ---------------------------------------------------------------------------
# Update client.conf
# ---------------------------------------------------------------------------
if [[ -n "${TEMPLATE}" ]]; then
  # Render from the template, splicing in current state for the three keyed
  # lines. Preserve everything else verbatim.
  [[ -f "${TARGET}" ]] && backup_file "${TARGET}" >/dev/null

  TMP_OUT="$(mktemp)"
  trap 'rm -f "${TMP_OUT}"' EXIT

  template_has_dns=0
  if grep -qE '^[[:space:]]*DNS[[:space:]]*=' "${TEMPLATE}"; then
    template_has_dns=1
  fi

  current_section=""
  saw_priv=0; saw_pub=0; saw_ep=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[[:space:]]*\[Interface\][[:space:]]*$ ]]; then
      current_section="interface"
      printf '%s\n' "${line}" >> "${TMP_OUT}"
      if [[ "${template_has_dns}" -eq 0 ]]; then
        printf 'DNS = %s\n' "${DEFAULT_DNS}" >> "${TMP_OUT}"
      fi
      continue
    fi
    if [[ "${line}" =~ ^[[:space:]]*\[Peer\][[:space:]]*$ ]]; then
      current_section="peer"
      printf '%s\n' "${line}" >> "${TMP_OUT}"
      continue
    fi
    if [[ "${current_section}" == "interface" && "${line}" =~ ^[[:space:]]*PrivateKey[[:space:]]*= ]]; then
      printf 'PrivateKey = %s\n' "${PEER_PRIV}" >> "${TMP_OUT}"
      saw_priv=1
      continue
    fi
    if [[ "${current_section}" == "peer" && "${line}" =~ ^[[:space:]]*PublicKey[[:space:]]*= ]]; then
      printf 'PublicKey = %s\n' "${SERVER_PUB}" >> "${TMP_OUT}"
      saw_pub=1
      continue
    fi
    if [[ "${current_section}" == "peer" && "${line}" =~ ^[[:space:]]*Endpoint[[:space:]]*= ]]; then
      printf 'Endpoint = %s\n' "${SERVER_ENDPOINT}" >> "${TMP_OUT}"
      saw_ep=1
      continue
    fi
    printf '%s\n' "${line}" >> "${TMP_OUT}"
  done < "${TEMPLATE}"

  missing=()
  [[ "${saw_priv}" -eq 1 ]] || missing+=("[Interface] PrivateKey")
  [[ "${saw_pub}"  -eq 1 ]] || missing+=("[Peer] PublicKey")
  [[ "${saw_ep}"   -eq 1 ]] || missing+=("[Peer] Endpoint")
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Template missing required placeholder lines: ${missing[*]}"
    exit 1
  fi

  umask 077
  mv "${TMP_OUT}" "${TARGET}"
  trap - EXIT
  chmod 600 "${TARGET}"
  log_success "Wrote ${TARGET}"
elif [[ "${ROTATE_KEYS}" -eq 1 ]]; then
  # Keys-only path: patch [Interface] PrivateKey in the existing client.conf,
  # preserving everything else (custom routes, MTU, etc.).
  if [[ ! -f "${TARGET}" ]]; then
    log_warn "No existing ${TARGET} — skipped client config update."
    log_warn "Render one with: scripts/wireguard/edit-peer.sh --name ${PEER} --template <path>"
  else
    backup_file "${TARGET}" >/dev/null

    TMP_OUT="$(mktemp)"
    trap 'rm -f "${TMP_OUT}"' EXIT

    current_section=""
    matched=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
      if [[ "${line}" =~ ^[[:space:]]*\[Interface\][[:space:]]*$ ]]; then
        current_section="interface"
      elif [[ "${line}" =~ ^[[:space:]]*\[ ]]; then
        current_section="other"
      fi
      if [[ "${current_section}" == "interface" && "${line}" =~ ^[[:space:]]*PrivateKey[[:space:]]*= ]]; then
        printf 'PrivateKey = %s\n' "${PEER_PRIV}" >> "${TMP_OUT}"
        matched=$((matched + 1))
        continue
      fi
      printf '%s\n' "${line}" >> "${TMP_OUT}"
    done < "${TARGET}"

    if [[ "${matched}" -ne 1 ]]; then
      rm -f "${TMP_OUT}"
      trap - EXIT
      log_error "Expected 1 [Interface] PrivateKey line in ${TARGET}, found ${matched}"
      exit 1
    fi

    umask 077
    mv "${TMP_OUT}" "${TARGET}"
    trap - EXIT
    chmod 600 "${TARGET}"
    log_success "Updated PrivateKey in ${TARGET}"
  fi
fi

# ---------------------------------------------------------------------------
# Push the new server config to the running interface (only when keys rotated)
# ---------------------------------------------------------------------------
if [[ "${ROTATE_KEYS}" -eq 1 ]]; then
  wg_sync "${NAME}"
fi

# ---------------------------------------------------------------------------
# Print the rendered client config
# ---------------------------------------------------------------------------
if [[ "${PRINT}" -eq 1 && -f "${TARGET}" ]]; then
  section "Client configuration for '${PEER}' — copy/paste into the device"
  cat "${TARGET}"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    section "QR code (scan from the WireGuard mobile app)"
    qrencode -t ansiutf8 < "${TARGET}"
  fi
fi
