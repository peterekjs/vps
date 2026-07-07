#!/usr/bin/env bash
# pull-backups.sh — mirror the VPS's encrypted snapshots to this machine.
#
# Usage:
#   scripts/home/pull-backups.sh [user@]host [dest-dir]
#
# Runs on a HOME machine (macOS or Linux) — deliberately no root or Debian
# guard. Requires ssh+rsync and that the remote user is in the vpsbackup
# group. No --delete: local copies intentionally outlive the VPS's retention
# window, they are your disaster-recovery history. Schedule via cron/launchd
# if wanted — see docs/runbooks/backup-and-restore.md.

set -euo pipefail

HOST="${1:?Usage: pull-backups.sh [user@]host [dest-dir]}"
DEST="${2:-${HOME}/Backups/vps}"
REMOTE_DIR="/var/backups/vps"

mkdir -p "${DEST}"
rsync -avz --itemize-changes "${HOST}:${REMOTE_DIR}/" "${DEST}/"

echo
shopt -s nullglob
snaps=("${DEST}"/vps-backup-*.tar.gz.age)   # name-sorted == chronological
shopt -u nullglob
if [[ ${#snaps[@]} -eq 0 ]]; then
  echo "No snapshots in ${DEST} yet."
  exit 0
fi
echo "Local snapshots (${#snaps[@]} total, newest last):"
printf '  %s\n' "${snaps[@]##*/}" | tail -5

newest="${snaps[$((${#snaps[@]} - 1))]}"
if [[ -f "${newest}.sha256" ]]; then
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${DEST}" && sha256sum -c "$(basename "${newest}").sha256")
  else
    (cd "${DEST}" && shasum -a 256 -c "$(basename "${newest}").sha256")
  fi
fi
