#!/usr/bin/env bash
# =============================================================================
# prepare-existing-server.sh — Get a server set up by an earlier version of this
# repo (Nextcloud AIO and cloudflared only) ready for the current setup.sh.
#
# Pull the new version, fill in the "Required" section of .env, then:
#   sudo ./scripts/prepare-existing-server.sh
#   sudo ./setup.sh
#
# What it does:
#   - renames the old S3 settings in .env to the names setup.sh uses
#   - sets TUNNEL_NAME to the existing tunnel's name, so setup.sh reuses that
#     tunnel and its routes instead of creating a new one
#   - removes the old cron job, which runs a script that has moved
#   - removes the containers of the old Compose project "nextcloud-aio", so the
#     new project can create them again. Volumes and data are left alone, and
#     the Nextcloud containers that AIO itself runs keep running.
#
# Nextcloud is offline from the last step until setup.sh starts cloudflared
# again, so run setup.sh straight afterwards. Safe to run more than once.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_DIR}/.env"
OLD_PROJECT=nextcloud-aio

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[prepare]${NC} $*"; }
warn() { echo -e "${YELLOW}[prepare]${NC} WARN: $*"; }
fail() { echo -e "${RED}[prepare]${NC} ERROR: $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fail "Please run as root: sudo ./scripts/prepare-existing-server.sh"
[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found. This script is for a server that already has one."
chmod 600 "${ENV_FILE}"
command -v docker &>/dev/null || fail "Docker is not installed, so this is not an existing server. Run setup.sh instead."
command -v jq &>/dev/null || { log "Installing jq..."; apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq; }

# -----------------------------------------------------------------------------
# 1. .env names
# -----------------------------------------------------------------------------
# Rename OLD to NEW. A blank NEW line, as left by copying in the new
# .env.example, is replaced. If both have values they must agree: a different
# S3_PREFIX, for example, would start a second offsite copy.
rename_var() {
  local old="$1" new="$2" old_line new_line
  grep -q "^${old}=" "${ENV_FILE}" || return 0
  if grep -q "^${new}=." "${ENV_FILE}"; then
    old_line="$(grep -m1 "^${old}=" "${ENV_FILE}")"
    new_line="$(grep -m1 "^${new}=" "${ENV_FILE}")"
    [[ "${old_line#*=}" == "${new_line#*=}" ]] \
      || fail "${ENV_FILE} has both ${old} and ${new} with different values. Keep the right value in ${new}, delete the ${old} line, and run this again."
    sed -i "/^${old}=/d" "${ENV_FILE}"
    log "Removed ${old} from .env; ${new} already has the same value."
    return 0
  fi
  sed -i "/^${new}=\$/d" "${ENV_FILE}"
  sed -i "s/^${old}=/${new}=/" "${ENV_FILE}"
  log "Renamed ${old} to ${new} in .env."
}
rename_var AWS_ACCESS_KEY_ID     S3_ACCESS_KEY_ID
rename_var AWS_SECRET_ACCESS_KEY S3_SECRET_ACCESS_KEY
rename_var S3_BACKUP_PREFIX      S3_PREFIX

set -a; source "${ENV_FILE}"; set +a

# -----------------------------------------------------------------------------
# 2. Tunnel name
# -----------------------------------------------------------------------------
# setup.sh finds its tunnel by name and creates one if none matches, which would
# leave the existing routes on a tunnel nothing runs any more.
if [[ -n "${TUNNEL_NAME:-}" ]]; then
  log "TUNNEL_NAME is already set to ${TUNNEL_NAME}."
elif [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
  # The token is base64 JSON holding the account ID (a) and tunnel ID (t).
  token_json="$(printf '%s' "${CLOUDFLARE_TUNNEL_TOKEN}" | base64 -d 2>/dev/null || true)"
  account_id="$(jq -r '.a // empty' <<<"${token_json}" 2>/dev/null || true)"
  tunnel_id="$(jq -r '.t // empty' <<<"${token_json}" 2>/dev/null || true)"
  [[ -n "${account_id}" && -n "${tunnel_id}" ]] \
    || fail "Could not read CLOUDFLARE_TUNNEL_TOKEN. Set TUNNEL_NAME in .env to the existing tunnel's name (Zero Trust > Networks > Tunnels), then run this again."
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] \
    || fail "Set CLOUDFLARE_API_TOKEN in .env (see .env.example) so the tunnel's name can be looked up, or set TUNNEL_NAME to the name of tunnel ${tunnel_id} yourself. Then run this again."

  # The header goes through a config file descriptor so the token stays out of `ps`.
  response="$(curl -sS --max-time 30 \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${CLOUDFLARE_API_TOKEN}") \
    "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}")" \
    || fail "Could not reach the Cloudflare API."
  jq -e '.success' <<<"${response}" >/dev/null \
    || fail "Cloudflare would not return tunnel ${tunnel_id}: $(jq -c '.errors' <<<"${response}" 2>/dev/null || echo "${response:0:300}"). Check the API token's Tunnel permission, or set TUNNEL_NAME yourself."
  [[ "$(jq -r '.result.deleted_at // empty' <<<"${response}")" == "" ]] \
    || fail "Tunnel ${tunnel_id} has been deleted in Cloudflare. Remove CLOUDFLARE_TUNNEL_TOKEN from .env and let setup.sh create a new tunnel."
  name="$(jq -r '.result.name // empty' <<<"${response}")"
  [[ -n "${name}" ]] || fail "Cloudflare returned no name for tunnel ${tunnel_id}. Set TUNNEL_NAME yourself."

  # Shell-quoted, because .env is sourced and a tunnel name may contain spaces.
  line="TUNNEL_NAME=$(printf '%q' "${name}")"
  if grep -q '^TUNNEL_NAME=' "${ENV_FILE}"; then
    sed -i "s|^TUNNEL_NAME=.*|$(printf '%s' "${line}" | sed 's/[\\&|]/\\&/g')|" "${ENV_FILE}"
  else
    [[ -n "$(tail -c 1 "${ENV_FILE}")" ]] && echo "" >> "${ENV_FILE}"
    echo "${line}" >> "${ENV_FILE}"
  fi
  log "Set TUNNEL_NAME to ${name}, the tunnel this server already uses."
else
  warn "No CLOUDFLARE_TUNNEL_TOKEN in .env, so setup.sh will create a new tunnel."
fi

# -----------------------------------------------------------------------------
# 3. Nextcloud's domain
# -----------------------------------------------------------------------------
# setup.sh publishes Nextcloud at cloud.DOMAIN. It keeps the tunnel's routes for
# other hostnames, so an existing address keeps working either way.
aio_volume="$(docker volume inspect -f '{{.Mountpoint}}' nextcloud_aio_mastercontainer 2>/dev/null || true)"
aio_domain=""
if [[ -n "${aio_volume}" && -f "${aio_volume}/data/configuration.json" ]]; then
  aio_domain="$(jq -r '.domain // empty' "${aio_volume}/data/configuration.json" 2>/dev/null || true)"
fi
if [[ -n "${aio_domain}" && "${aio_domain}" != "cloud.${DOMAIN:-}" ]]; then
  warn "Nextcloud is set up for ${aio_domain}, but setup.sh also publishes it at cloud.${DOMAIN:-DOMAIN}."
  warn "${aio_domain} keeps working. cloud.${DOMAIN:-DOMAIN} will show Nextcloud's \"untrusted domain\" page unless you add it to trusted_domains, or delete its route and DNS record in Cloudflare."
fi

# -----------------------------------------------------------------------------
# 4. Old offsite backup schedule
# -----------------------------------------------------------------------------
# The cron job runs ./backup-to-s3.sh, which is now scripts/backup-to-s3.sh and
# scheduled by a systemd timer that setup.sh creates.
for file in /etc/cron.d/nextcloud-s3-sync /etc/logrotate.d/nextcloud-s3-sync; do
  if [[ -f "${file}" ]]; then
    rm -f "${file}"
    log "Removed ${file}."
  fi
done
if [[ -n "${S3_PREFIX:-}" ]]; then
  log "Offsite copies stay at s3://${S3_BUCKET:-S3_BUCKET}/${S3_PREFIX}/. The first rclone run may upload them all again."
fi

# -----------------------------------------------------------------------------
# 5. Old Compose project
# -----------------------------------------------------------------------------
# Removed by label rather than `docker compose down`, which would read the new
# compose.yaml from this directory. AIO's own containers (nextcloud-aio-apache
# and the rest) are not part of the project and keep running.
old_containers=()
for service in nextcloud-aio-mastercontainer cloudflared; do
  mapfile -t -O "${#old_containers[@]}" old_containers < <(docker ps -aq \
    --filter "label=com.docker.compose.project=${OLD_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}")
done
if [[ ${#old_containers[@]} -gt 0 ]]; then
  log "Removing the old ${OLD_PROJECT} project's containers (volumes are kept)..."
  docker stop "${old_containers[@]}" >/dev/null
  docker rm "${old_containers[@]}" >/dev/null
  log "Removed ${#old_containers[@]} container(s). Nextcloud is offline until setup.sh starts cloudflared."
else
  log "No containers from the old ${OLD_PROJECT} project."
fi

echo ""
log "Done. Now run: sudo ./setup.sh"
