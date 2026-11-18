#!/usr/bin/env bash
# =============================================================================
# backup-to-s3.sh — Copy Nextcloud AIO's Borg backups to S3-compatible storage.
#
# AIO writes consistent, encrypted Borg archives to BORG_BACKUP_DIR. This mirrors
# that directory to s3://S3_BUCKET/S3_PREFIX/ with rclone.
#
# Scheduled daily by the nextcloud-offsite-backup systemd timer (see setup.sh).
# Run by hand:  sudo systemctl start nextcloud-offsite-backup
# Logs:         journalctl -u nextcloud-offsite-backup
# Restore:      sudo ./scripts/backup-to-s3.sh restore   (copies the archives back from S3)
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_DIR}/.env"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: ${ENV_FILE} not found" >&2; exit 1; }
set -a; source "${ENV_FILE}"; set +a

for var in S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_REGION S3_PREFIX BORG_BACKUP_DIR; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: ${var} is not set in .env" >&2; exit 1; }
done

# rclone reads the remote "offsite" from these variables, so no config file is needed.
export RCLONE_CONFIG_OFFSITE_TYPE=s3
if [[ -n "${S3_ENDPOINT_URL:-}" ]]; then
  export RCLONE_CONFIG_OFFSITE_PROVIDER=Other RCLONE_CONFIG_OFFSITE_ENDPOINT="${S3_ENDPOINT_URL}"
else
  export RCLONE_CONFIG_OFFSITE_PROVIDER=AWS
fi
export RCLONE_CONFIG_OFFSITE_REGION="${S3_REGION}"
export RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}"
export RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}"
# The bucket already exists, and a key limited to it may not be allowed to check.
export RCLONE_CONFIG_OFFSITE_NO_CHECK_BUCKET=true

REMOTE="offsite:${S3_BUCKET}/${S3_PREFIX}/"

# Disaster recovery: bring the archives back before restoring them in AIO.
if [[ "${1:-}" == restore ]]; then
  mkdir -p "${BORG_BACKUP_DIR}"
  echo "Copying ${REMOTE} to ${BORG_BACKUP_DIR}"
  rclone copy "${REMOTE}" "${BORG_BACKUP_DIR}/" --fast-list --stats-one-line --stats-log-level NOTICE --stats 1m
  echo "Restore complete. Now choose \"Restore former AIO instance from backup\" in the AIO interface."
  exit 0
fi

# The sync deletes what isn't in the source, so never mirror a directory that
# doesn't hold a Borg repository: an empty or wrong path would wipe the copy.
if [[ -z "$(find "${BORG_BACKUP_DIR}" -maxdepth 2 -type f -name config -print -quit 2>/dev/null)" ]]; then
  echo "No Borg repository in ${BORG_BACKUP_DIR} yet. Set up backups in the AIO interface first."
  exit 0
fi

# Don't copy a backup that is still being written.
borg_running() { [[ -n "$(docker ps -q --filter 'name=^nextcloud-aio-borgbackup$')" ]]; }
for _ in {1..48}; do
  borg_running || break
  echo "AIO backup still running; waiting 5 minutes..."
  sleep 300
done
if borg_running; then
  echo "ERROR: AIO backup still running after 4 hours; skipping." >&2
  exit 1
fi

echo "Syncing ${BORG_BACKUP_DIR} ($(du -sh "${BORG_BACKUP_DIR}" | cut -f1)) to ${REMOTE}"
rclone sync "${BORG_BACKUP_DIR}/" "${REMOTE}" \
  --fast-list --stats-one-line --stats-log-level NOTICE --stats 5m
# setup.sh checks this to know the copy works; it outlives journal rotation.
mkdir -p /var/lib/nextcloud-offsite-backup
date -Is > /var/lib/nextcloud-offsite-backup/last-success
echo "Sync complete."
