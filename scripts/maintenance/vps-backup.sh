#!/usr/bin/env bash
# vps-backup — encrypted snapshot of state not reproducible from the repo.
#
# Usage:
#   vps-backup [--dry-run] [--notify]
#
# Tars BACKUP_PATHS, verifies the tar, encrypts with age to AGE_RECIPIENT
# (public key — the private key lives at home, never on this VPS), writes
# BACKUP_DIR/vps-backup-<ts>.tar.gz.age + .sha256, prunes snapshots older
# than BACKUP_RETENTION_DAYS. Snapshots are 640 root:vpsbackup so a non-root
# home machine can rsync them off (content is age-encrypted).
# See docs/runbooks/backup-and-restore.md.

set -euo pipefail
# shellcheck source=scripts/maintenance/lib.sh
source "${VPS_MAINT_LIB:-/usr/local/lib/vps-maintenance/lib.sh}"

DRY_RUN=0
NOTIFY=0
usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --notify)  NOTIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

require_root
load_conf

if [[ -z "${AGE_RECIPIENT}" ]]; then
  log_error "AGE_RECIPIENT not set in ${VPS_MAINT_CONF} — generate a key at home (age-keygen) first."
  exit 2
fi
command -v age >/dev/null 2>&1 || { log_error "age not installed — run scripts/setup/01-maintenance.sh"; exit 2; }

# Resolve BACKUP_PATHS to what actually exists; warn about the rest.
existing=()
for p in "${BACKUP_PATHS[@]}"; do
  if [[ -e "${p}" ]]; then
    existing+=("${p}")
  else
    log_warn "Skipping missing backup path: ${p}"
  fi
done
if [[ ${#existing[@]} -eq 0 ]]; then
  log_error "None of the configured BACKUP_PATHS exist — nothing to back up."
  exit 2
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "Dry run — would snapshot the following into ${BACKUP_DIR}:"
  printf '  %s\n' "${existing[@]}"
  exit 0
fi

tmpdir=$(mktemp -d)
chmod 700 "${tmpdir}"
# On any failure: notify (if asked) and clean up the staging dir.
cleanup() {
  local rc=$?
  if [[ "${rc}" -ne 0 && "${NOTIFY}" -eq 1 ]]; then
    notify critical "vps-backup failed" \
      "vps-backup exited with code ${rc} on $(hostname) — journalctl -u vps-backup"
  fi
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

install -d -m 750 -o root -g vpsbackup "${BACKUP_DIR}"

ts=$(date +%Y%m%d-%H%M%S)
archive="${tmpdir}/backup.tar.gz"
dest="${BACKUP_DIR}/vps-backup-${ts}.tar.gz.age"

log_info "Creating tar of ${#existing[@]} path(s) …"
tar -czf "${archive}" -C / "${existing[@]#/}"
tar -tzf "${archive}" >/dev/null
log_success "Tar created and verified ($(du -h "${archive}" | cut -f1))"

age -r "${AGE_RECIPIENT}" -o "${dest}" "${archive}"
chown root:vpsbackup "${dest}"
chmod 640 "${dest}"
(cd "${BACKUP_DIR}" && sha256sum "$(basename "${dest}")" > "$(basename "${dest}").sha256")
chown root:vpsbackup "${dest}.sha256"
chmod 640 "${dest}.sha256"
log_success "Encrypted snapshot: ${dest}"

pruned=$(find "${BACKUP_DIR}" -maxdepth 1 -name 'vps-backup-*' \
  -mtime +"${BACKUP_RETENTION_DAYS}" -print -delete | wc -l)
log_info "Pruned ${pruned} file(s) older than ${BACKUP_RETENTION_DAYS} days"

log_success "vps-backup complete"
