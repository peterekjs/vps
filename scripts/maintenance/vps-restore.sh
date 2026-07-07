#!/usr/bin/env bash
# vps-restore — restore files from a vps-backup snapshot.
#
# Usage:
#   vps-restore [--dry-run] [--identity <age-key-file>] [--yes] <archive>
#
# <archive> is either a vps-backup-*.tar.gz.age (requires --identity or
# AGE_IDENTITY_FILE pointing at the age private key, brought from home for
# the occasion) or an already-decrypted .tar.gz. Existing files are backed up
# with a .bak.<timestamp> suffix before being overwritten. --dry-run only
# lists what would happen. See docs/runbooks/backup-and-restore.md and
# docs/runbooks/rebuild-from-scratch.md.

set -euo pipefail
# shellcheck source=scripts/maintenance/lib.sh
source "${VPS_MAINT_LIB:-/usr/local/lib/vps-maintenance/lib.sh}"

DRY_RUN=0
ASSUME_YES=0
IDENTITY="${AGE_IDENTITY_FILE:-}"
ARCHIVE=""

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --yes)      ASSUME_YES=1; shift ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         log_error "Unknown option: $1"; usage; exit 1 ;;
    *)          ARCHIVE="$1"; shift ;;
  esac
done

[[ -n "${ARCHIVE}" ]] || { log_error "No archive given."; usage; exit 1; }
[[ -f "${ARCHIVE}" ]] || { log_error "Archive not found: ${ARCHIVE}"; exit 1; }
require_root

tmpdir=$(mktemp -d)
chmod 700 "${tmpdir}"
trap 'rm -rf "${tmpdir}"' EXIT
tarball="${tmpdir}/backup.tar.gz"

case "${ARCHIVE}" in
  *.age)
    if [[ -z "${IDENTITY}" || ! -f "${IDENTITY}" ]]; then
      log_error "Encrypted archive needs the age private key: --identity <file> (or AGE_IDENTITY_FILE)."
      log_error "The key lives at home — copy it here temporarily, or decrypt at home and pass the .tar.gz."
      exit 1
    fi
    log_info "Decrypting with ${IDENTITY} …"
    age -d -i "${IDENTITY}" -o "${tarball}" "${ARCHIVE}"
    ;;
  *.tar.gz)
    cp "${ARCHIVE}" "${tarball}"
    ;;
  *)
    log_error "Unsupported archive type: ${ARCHIVE} (expected .tar.gz.age or .tar.gz)"
    exit 1
    ;;
esac

mapfile -t members < <(tar -tzf "${tarball}")
log_info "Snapshot contains ${#members[@]} entries."

if [[ "${DRY_RUN}" -eq 1 ]]; then
  for m in "${members[@]}"; do
    if [[ -e "/${m}" && ! -d "/${m}" ]]; then
      echo "would OVERWRITE /${m}"
    elif [[ ! -e "/${m}" ]]; then
      echo "would create   /${m}"
    fi
  done
  log_info "Dry run — nothing changed."
  exit 0
fi

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  log_warn "This overwrites live system files (WireGuard keys, SSH host keys, Caddy state …)."
  read -r -p "Type 'restore' to continue: " answer
  [[ "${answer}" == "restore" ]] || { log_info "Aborted."; exit 1; }
fi

# Back up every regular file we are about to overwrite (one timestamp per run).
ts=$(date +%Y%m%d%H%M%S)
for m in "${members[@]}"; do
  if [[ -f "/${m}" && ! -L "/${m}" ]]; then
    cp --preserve=all "/${m}" "/${m}.bak.${ts}"
  fi
done
log_info "Existing files backed up with suffix .bak.${ts}"

tar -xpzf "${tarball}" -C /
log_success "Snapshot restored."

cat <<'EOF'

  Next steps (see docs/runbooks/backup-and-restore.md):
    systemctl restart ssh          # if SSH host keys were restored
    systemctl restart wg-quick@wg0 # for each restored WireGuard interface
    systemctl restart caddy        # if Caddy state / caddy.env was restored
    vps-health                     # verify everything came back
  If you copied the age private key onto this machine, DELETE it now:
    shred -u <keyfile>
EOF
