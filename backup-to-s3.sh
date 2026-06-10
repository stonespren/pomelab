#!/usr/bin/env bash
# =============================================================================
# backup-to-s3.sh — Sync Nextcloud AIO's Borg backup directory to S3
#
# AIO creates consistent, encrypted Borg archives in BORG_BACKUP_DIR.
# This script syncs that directory offsite to an S3-compatible bucket.
#
# Run manually:   sudo ./backup-to-s3.sh
# Scheduled via:  /etc/cron.d/nextcloud-s3-sync (set up by setup.sh)
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: .env not found at ${ENV_FILE}" >&2
  exit 1
fi

set -a; source "${ENV_FILE}"; set +a

# Validate required variables
for VAR in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY S3_REGION S3_BUCKET \
           S3_BACKUP_PREFIX BORG_BACKUP_DIR; do
  if [[ -z "${!VAR:-}" ]]; then
    echo "ERROR: ${VAR} is not set in .env" >&2
    exit 1
  fi
done

if ! command -v aws &>/dev/null; then
  echo "ERROR: aws CLI not found. Run setup.sh to install it." >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="${S3_REGION}"

S3_ENDPOINT_ARG=""
[[ -n "${S3_ENDPOINT_URL:-}" ]] && S3_ENDPOINT_ARG="--endpoint-url ${S3_ENDPOINT_URL}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== Nextcloud AIO → S3 Backup Sync ==="

# Verify backup directory exists and contains something
if [[ ! -d "${BORG_BACKUP_DIR}" ]]; then
  log "ERROR: Borg backup directory does not exist: ${BORG_BACKUP_DIR}"
  log "Configure and run AIO's built-in backup at least once before syncing."
  exit 1
fi

if [[ -z "$(ls -A "${BORG_BACKUP_DIR}" 2>/dev/null)" ]]; then
  log "WARN: Borg backup directory is empty: ${BORG_BACKUP_DIR}"
  log "Run a backup from the AIO interface first, then re-run this script."
  exit 0
fi

BACKUP_SIZE="$(du -sh "${BORG_BACKUP_DIR}" | cut -f1)"
log "Syncing ${BORG_BACKUP_DIR} (${BACKUP_SIZE}) → s3://${S3_BUCKET}/${S3_BACKUP_PREFIX}/"

aws s3 sync ${S3_ENDPOINT_ARG} \
  "${BORG_BACKUP_DIR}/" \
  "s3://${S3_BUCKET}/${S3_BACKUP_PREFIX}/" \
  --storage-class STANDARD_IA \
  --no-progress

log "Sync complete."
log "S3 destination: s3://${S3_BUCKET}/${S3_BACKUP_PREFIX}/"
