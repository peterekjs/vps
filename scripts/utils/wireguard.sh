#!/usr/bin/env bash
# wireguard.sh — Shared helpers for the wireguard scripts.
# Source from a script that has already sourced common.sh:
#   source "${SCRIPT_DIR}/../utils/common.sh"
#   source "${SCRIPT_DIR}/../utils/wireguard.sh"

set -euo pipefail

WG_DIR="/etc/wireguard"

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

wg_config_path() { echo "${WG_DIR}/$1.conf"; }
wg_state_dir()   { echo "${WG_DIR}/$1.d"; }
wg_server_dir()  { echo "$(wg_state_dir "$1")/server"; }
wg_peers_dir()   { echo "$(wg_state_dir "$1")/peers"; }
wg_peer_dir()    { echo "$(wg_peers_dir "$1")/$2"; }

# Sanitize a free-form peer name into a safe filename component.
wg_sanitize_name() {
  echo "$1" | tr ' ' '_' | tr -cd 'A-Za-z0-9_.-'
}

# Resolve the WG instance to operate on. If a single state dir exists it is
# returned automatically, otherwise the caller must pass --config explicitly.
wg_resolve_instance() {
  local explicit="${1:-}"
  if [[ -n "${explicit}" ]]; then
    echo "${explicit}"
    return 0
  fi
  local found=()
  if [[ -d "${WG_DIR}" ]]; then
    while IFS= read -r -d '' d; do
      found+=("$(basename "${d%.d}")")
    done < <(find "${WG_DIR}" -mindepth 1 -maxdepth 1 -type d -name '*.d' -print0)
  fi
  case "${#found[@]}" in
    0) log_error "No WireGuard instance found in ${WG_DIR}. Run init first."; return 1 ;;
    1) echo "${found[0]}" ;;
    *) log_error "Multiple WireGuard instances found (${found[*]}). Pass --config <name>."; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

wg_require_tools() {
  if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
    log_error "wireguard-tools not installed. Run scripts/wireguard/init.sh first."
    exit 1
  fi
}

wg_require_instance() {
  local name="$1"
  if [[ ! -d "$(wg_state_dir "${name}")" ]]; then
    log_error "No state for instance '${name}' at $(wg_state_dir "${name}"). Run init first."
    exit 1
  fi
  if [[ ! -f "$(wg_config_path "${name}")" ]]; then
    log_error "Config $(wg_config_path "${name}") missing. Run init first."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Key generation
# ---------------------------------------------------------------------------

# Generate a keypair into <dir>/private.key and <dir>/public.key (mode 0600).
wg_gen_keypair() {
  local dir="$1"
  mkdir -p "${dir}"
  chmod 700 "${dir}"
  ( umask 077
    wg genkey | tee "${dir}/private.key" | wg pubkey > "${dir}/public.key" )
  chmod 600 "${dir}/private.key" "${dir}/public.key"
}

# ---------------------------------------------------------------------------
# IP allocation (IPv4 /24 only — keeps the bash side simple)
# ---------------------------------------------------------------------------

# Print the next free /32 IP within the server's /24 subnet, or empty string
# if the subnet is not /24 / is exhausted.
wg_next_peer_ip() {
  local name="$1"
  local cfg
  cfg="$(wg_config_path "${name}")"
  local addr
  addr="$(grep -E '^[[:space:]]*Address[[:space:]]*=' "${cfg}" | head -1 | sed -E 's/.*=[[:space:]]*//' | tr -d ' ')"
  local base_ip="${addr%%/*}"
  local prefix="${addr##*/}"
  if [[ "${prefix}" != "24" ]]; then
    return 0
  fi
  local prefix_24="${base_ip%.*}"
  local server_octet="${base_ip##*.}"

  declare -A used=()
  used["${server_octet}"]=1

  while IFS= read -r line; do
    local ips
    ips="$(echo "${line}" | sed -E 's/.*=[[:space:]]*//')"
    local IFS_BACKUP="${IFS}"
    IFS=','
    # shellcheck disable=SC2206
    local parts=( ${ips} )
    IFS="${IFS_BACKUP}"
    for p in "${parts[@]}"; do
      p="$(echo "${p}" | tr -d ' ')"
      local ip="${p%%/*}"
      if [[ "${ip%.*}" == "${prefix_24}" ]]; then
        used["${ip##*.}"]=1
      fi
    done
  done < <(grep -E '^[[:space:]]*AllowedIPs[[:space:]]*=' "${cfg}" || true)

  for octet in $(seq 2 254); do
    if [[ -z "${used[${octet}]:-}" ]]; then
      echo "${prefix_24}.${octet}/32"
      return 0
    fi
  done
}

# ---------------------------------------------------------------------------
# Apply changes to a running interface without disconnecting active peers.
# ---------------------------------------------------------------------------

wg_sync() {
  local name="$1"
  if systemctl is-active --quiet "wg-quick@${name}"; then
    wg syncconf "${name}" <(wg-quick strip "${name}")
    log_success "Live config synced on ${name}"
  else
    log_info "wg-quick@${name} is not running — start it with: systemctl start wg-quick@${name}"
  fi
}

# ---------------------------------------------------------------------------
# Render a client (peer) configuration block.
# Reads server + peer state; writes to stdout.
# ---------------------------------------------------------------------------

wg_render_client_config() {
  local name="$1" peer="$2"
  local sdir pdir
  sdir="$(wg_server_dir "${name}")"
  pdir="$(wg_peer_dir "${name}" "${peer}")"

  local server_pub endpoint listen_port peer_priv peer_addr client_routes dns_line=""
  server_pub="$(cat "${sdir}/public.key")"
  endpoint="$(cat "${sdir}/endpoint")"
  listen_port="$(cat "${sdir}/listen_port")"
  peer_priv="$(cat "${pdir}/private.key")"
  peer_addr="$(cat "${pdir}/address")"
  if [[ -f "${pdir}/client_allowed_ips" ]]; then
    client_routes="$(cat "${pdir}/client_allowed_ips")"
  else
    client_routes="0.0.0.0/0, ::/0"
  fi
  if [[ -f "${sdir}/dns" ]]; then
    dns_line="DNS = $(cat "${sdir}/dns")"
  fi

  cat <<EOF
[Interface]
PrivateKey = ${peer_priv}
Address = ${peer_addr}
${dns_line:+${dns_line}
}
[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint}:${listen_port}
AllowedIPs = ${client_routes}
PersistentKeepalive = 25
EOF
}
