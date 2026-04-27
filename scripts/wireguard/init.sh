#!/usr/bin/env bash
# init.sh — Initialize this VPS as a WireGuard server.
#
# Usage:
#   sudo bash scripts/wireguard/init.sh [options]
#
# Options:
#   --name <name>           Config name (default: derived from --template, else wg0).
#                           Becomes /etc/wireguard/<name>.conf and interface name.
#   --address <CIDR>        Server VPN address, e.g. 10.9.0.1/24
#   --port <port>           UDP listen port (default: 51820)
#   --endpoint <host>       Public hostname/IP peers will dial (auto-detected if omitted)
#   --dns <ip>              DNS server(s) pushed to clients
#                           (default: 1.1.1.1, 8.8.8.8)
#   --template <path>       Use a template config; freshly generate keys for the server
#                           and every [Peer] in it. Comment line directly above each
#                           [Peer] is used as the peer name (e.g. "# HOME").
#   -h, --help              Show this help.
#
# The script is idempotent — re-running prompts to overwrite, with backups.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"
# shellcheck source=scripts/utils/wireguard.sh
source "${SCRIPT_DIR}/../utils/wireguard.sh"

NAME=""
ADDRESS=""
PORT=""
ENDPOINT=""
DNS=""
TEMPLATE=""

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)     NAME="$2";     shift 2 ;;
    --address)  ADDRESS="$2";  shift 2 ;;
    --port)     PORT="$2";     shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --dns)      DNS="$2";      shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------
section "0. Prerequisites"
require_root
require_debian_bookworm
log_success "Running as root on Debian Bookworm"

# ---------------------------------------------------------------------------
# 1. Install packages
# ---------------------------------------------------------------------------
section "1. Installing wireguard packages"
apt_install wireguard wireguard-tools qrencode curl

# ---------------------------------------------------------------------------
# 2. Gather configuration
# ---------------------------------------------------------------------------
section "2. Gathering configuration"

# Default --name from template filename if a template was provided.
if [[ -z "${NAME}" && -n "${TEMPLATE}" ]]; then
  NAME="$(basename "${TEMPLATE}" .conf)"
fi

if [[ -z "${NAME}" ]]; then
  read -r -p "Config name [wg0]: " input
  NAME="${input:-wg0}"
fi

if [[ ${#NAME} -gt 15 ]]; then
  log_error "Interface name '${NAME}' exceeds 15 characters (Linux limit)."
  exit 1
fi

CFG="$(wg_config_path "${NAME}")"
STATE="$(wg_state_dir "${NAME}")"

# Pre-fill from template if provided
if [[ -n "${TEMPLATE}" ]]; then
  if [[ ! -f "${TEMPLATE}" ]]; then
    log_error "Template not found: ${TEMPLATE}"
    exit 1
  fi
  if [[ -z "${ADDRESS}" ]]; then
    ADDRESS="$(grep -E '^[[:space:]]*Address[[:space:]]*=' "${TEMPLATE}" | head -1 | sed -E 's/.*=[[:space:]]*//' | tr -d ' ' || true)"
  fi
  if [[ -z "${PORT}" ]]; then
    PORT="$(grep -E '^[[:space:]]*ListenPort[[:space:]]*=' "${TEMPLATE}" | head -1 | sed -E 's/.*=[[:space:]]*//' | tr -d ' ' || true)"
  fi
fi

if [[ -z "${ADDRESS}" ]]; then
  read -r -p "Server VPN address (CIDR), e.g. 10.9.0.1/24: " ADDRESS
fi
if [[ -z "${ADDRESS}" ]]; then
  log_error "Address is required"; exit 1
fi

if [[ -z "${PORT}" ]]; then
  read -r -p "Listen UDP port [51820]: " input
  PORT="${input:-51820}"
fi

if [[ -z "${ENDPOINT}" ]]; then
  detected="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "${detected}" ]]; then
    read -r -p "Server public hostname/IP [${detected}]: " input
    ENDPOINT="${input:-${detected}}"
  else
    read -r -p "Server public hostname/IP: " ENDPOINT
  fi
fi
if [[ -z "${ENDPOINT}" ]]; then
  log_error "Endpoint is required"; exit 1
fi

if [[ -z "${DNS}" ]]; then
  read -r -p "DNS for clients [${WG_DEFAULT_DNS}]: " input
  DNS="${input:-${WG_DEFAULT_DNS}}"
fi

log_info "Name:     ${NAME}"
log_info "Config:   ${CFG}"
log_info "State:    ${STATE}"
log_info "Address:  ${ADDRESS}"
log_info "Port:     ${PORT}/udp"
log_info "Endpoint: ${ENDPOINT}"
log_info "DNS:      ${DNS}"
log_info "Template: ${TEMPLATE:-<none>}"

# ---------------------------------------------------------------------------
# 3. Backup any existing config / state
# ---------------------------------------------------------------------------
if [[ -f "${CFG}" || -d "${STATE}" ]]; then
  section "3. Existing instance found — confirming overwrite"
  log_warn "An instance named '${NAME}' already exists."
  if ! confirm "Overwrite (existing files will be backed up)?"; then
    log_info "Aborted."; exit 0
  fi
  if [[ -f "${CFG}" ]]; then
    backup_file "${CFG}"
  fi
  if [[ -d "${STATE}" ]]; then
    backup="${STATE}.bak.$(date +%Y%m%d%H%M%S)"
    mv "${STATE}" "${backup}"
    log_info "Backed up state ${STATE} → ${backup}"
  fi
  if systemctl is-active --quiet "wg-quick@${NAME}"; then
    systemctl stop "wg-quick@${NAME}"
    log_info "Stopped wg-quick@${NAME}"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Build state directory + server keypair
# ---------------------------------------------------------------------------
section "4. Generating server keypair"

mkdir -p "$(wg_server_dir "${NAME}")" "$(wg_peers_dir "${NAME}")"
chmod 700 "${STATE}" "$(wg_server_dir "${NAME}")" "$(wg_peers_dir "${NAME}")"

wg_gen_keypair "$(wg_server_dir "${NAME}")"
SERVER_PRIV="$(cat "$(wg_server_dir "${NAME}")/private.key")"
SERVER_PUB="$(cat "$(wg_server_dir "${NAME}")/public.key")"

echo "${ADDRESS}"  > "$(wg_server_dir "${NAME}")/address"
echo "${PORT}"     > "$(wg_server_dir "${NAME}")/listen_port"
echo "${ENDPOINT}" > "$(wg_server_dir "${NAME}")/endpoint"
echo "${DNS}" > "$(wg_server_dir "${NAME}")/dns"
chmod 600 "$(wg_server_dir "${NAME}")"/*

log_success "Server keypair stored under $(wg_server_dir "${NAME}")"

# ---------------------------------------------------------------------------
# 5. Build the server config (from template or from scratch)
# ---------------------------------------------------------------------------
section "5. Writing ${CFG}"

umask 077
if [[ -n "${TEMPLATE}" ]]; then
  log_info "Rendering from template ${TEMPLATE}"

  : > "${CFG}"

  current_section=""
  pending_comment=""
  current_peer=""
  peer_index=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[[:space:]]*\[Interface\][[:space:]]*$ ]]; then
      current_section="interface"
      pending_comment=""
      printf '%s\n' "${line}" >> "${CFG}"
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]*\[Peer\][[:space:]]*$ ]]; then
      current_section="peer"
      peer_index=$((peer_index + 1))
      if [[ -n "${pending_comment}" ]]; then
        current_peer="$(wg_sanitize_name "${pending_comment}")"
      else
        current_peer=""
      fi
      if [[ -z "${current_peer}" ]]; then
        current_peer="peer${peer_index}"
      fi
      pdir="$(wg_peer_dir "${NAME}" "${current_peer}")"
      if [[ -d "${pdir}" ]]; then
        log_warn "Duplicate peer name '${current_peer}' in template — appending index"
        current_peer="${current_peer}_${peer_index}"
        pdir="$(wg_peer_dir "${NAME}" "${current_peer}")"
      fi
      wg_gen_keypair "${pdir}"
      pending_comment=""
      printf '%s\n' "${line}" >> "${CFG}"
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*(.+)$ ]]; then
      pending_comment="${BASH_REMATCH[1]}"
      printf '%s\n' "${line}" >> "${CFG}"
      continue
    fi

    if [[ "${current_section}" == "interface" && "${line}" =~ ^[[:space:]]*PrivateKey[[:space:]]*= ]]; then
      printf 'PrivateKey = %s\n' "${SERVER_PRIV}" >> "${CFG}"
      continue
    fi

    if [[ "${current_section}" == "peer" && "${line}" =~ ^[[:space:]]*PublicKey[[:space:]]*= ]]; then
      pub="$(cat "$(wg_peer_dir "${NAME}" "${current_peer}")/public.key")"
      printf 'PublicKey = %s\n' "${pub}" >> "${CFG}"
      continue
    fi

    if [[ "${current_section}" == "peer" && "${line}" =~ ^[[:space:]]*AllowedIPs[[:space:]]*= ]]; then
      val="$(echo "${line}" | sed -E 's/.*=[[:space:]]*//')"
      first_ip="$(echo "${val}" | cut -d',' -f1 | tr -d ' ')"
      [[ "${first_ip}" == */* ]] || first_ip="${first_ip}/32"
      pdir="$(wg_peer_dir "${NAME}" "${current_peer}")"
      printf '%s\n' "${first_ip}" > "${pdir}/address"
      chmod 600 "${pdir}/address"
    fi

    printf '%s\n' "${line}" >> "${CFG}"
  done < "${TEMPLATE}"
else
  WAN_IFACE="$(ip -4 route show default | awk 'NR==1{print $5}')"
  WAN_IFACE="${WAN_IFACE:-eth0}"
  log_info "Detected WAN interface for MASQUERADE: ${WAN_IFACE}"
  cat > "${CFG}" <<EOF
[Interface]
Address = ${ADDRESS}
ListenPort = ${PORT}
PrivateKey = ${SERVER_PRIV}

PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IFACE} -j MASQUERADE
EOF
fi

chmod 600 "${CFG}"
log_success "Wrote ${CFG}"

# ---------------------------------------------------------------------------
# 6. Render client configs for any peers created from the template
# ---------------------------------------------------------------------------
if [[ -n "${TEMPLATE}" ]]; then
  section "6. Rendering peer client configs"
  for pdir in "$(wg_peers_dir "${NAME}")"/*/; do
    [[ -d "${pdir}" ]] || continue
    peer_name="$(basename "${pdir}")"
    if [[ ! -f "${pdir}/address" ]]; then
      log_warn "Peer ${peer_name}: no AllowedIPs in template — skipping client config"
      continue
    fi
    wg_render_client_config "${NAME}" "${peer_name}" > "${pdir}/client.conf"
    chmod 600 "${pdir}/client.conf"
    log_success "Peer ${peer_name} → ${pdir}client.conf"
  done
fi

# ---------------------------------------------------------------------------
# 7. Enable IP forwarding
# ---------------------------------------------------------------------------
section "7. Enabling IP forwarding"

FORWARD_CONF="/etc/sysctl.d/99-wireguard-forward.conf"
cat > "${FORWARD_CONF}" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
chmod 644 "${FORWARD_CONF}"
sysctl -p "${FORWARD_CONF}" > /dev/null
log_success "IP forwarding enabled (${FORWARD_CONF})"

# ---------------------------------------------------------------------------
# 8. Open the WireGuard port in UFW (if UFW is active)
# ---------------------------------------------------------------------------
section "8. Firewall"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${PORT}/udp" comment "WireGuard ${NAME}"
  log_success "UFW: allowed ${PORT}/udp"
else
  log_warn "UFW not active — open ${PORT}/udp manually if you use another firewall"
fi

# ---------------------------------------------------------------------------
# 9. Bring up the interface
# ---------------------------------------------------------------------------
section "9. Starting wg-quick@${NAME}"

systemctl enable "wg-quick@${NAME}"
if systemctl is-active --quiet "wg-quick@${NAME}"; then
  systemctl restart "wg-quick@${NAME}"
else
  systemctl start "wg-quick@${NAME}"
fi
log_success "wg-quick@${NAME} is running"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "WireGuard server initialized"

cat <<EOF

  Instance: ${NAME}
  Config:   ${CFG}
  State:    ${STATE}
  Public:   ${SERVER_PUB}
  Endpoint: ${ENDPOINT}:${PORT}

  Add a new peer:
    sudo bash scripts/wireguard/add-peer.sh --config ${NAME}

  List peers:
    sudo bash scripts/wireguard/info.sh list --config ${NAME}

  Show a peer's client config:
    sudo bash scripts/wireguard/info.sh <peer-name> --config ${NAME}

  Re-render a peer's client config from a template, or rotate its keypair:
    sudo bash scripts/wireguard/edit-peer.sh --config ${NAME} --name <peer-name> --template <path>
    sudo bash scripts/wireguard/edit-peer.sh --config ${NAME} --name <peer-name> --rotate-keys

EOF
