#!/usr/bin/env bash
# =============================================================================
# setup.sh — Set up or update the server: Nextcloud AIO, the media stack, the
# Cloudflare Tunnel that publishes them, and offsite backups. Debian 12.
#
# Fill in the "Required" section of .env first (copy .env.example), then:
#   sudo ./setup.sh
#
# Safe to run any number of times: it brings everything in line with .env, pulls
# newer images and leaves what is already right alone. Whatever still needs a
# person is written to NEXT_STEPS.md, which is rebuilt on every run.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[setup]${NC} $*"; }
warn()   { echo -e "${YELLOW}[setup]${NC} WARN: $*"; }
fail()   { echo -e "${RED}[setup]${NC} ERROR: $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

# Manual steps collected along the way and written to NEXT_STEPS.md at the end
NEXT_STEPS=()
note() { NEXT_STEPS+=("$1"); }

[[ "${EUID}" -eq 0 ]] || fail "Please run as root: sudo ./setup.sh"

# =============================================================================
# 1. Configuration
# =============================================================================
header "Configuration"

set_env_var() {
  local var_name="$1" value="$2" escaped
  export "${var_name}=${value}"
  if grep -q "^${var_name}=" "${ENV_FILE}"; then
    escaped="$(printf '%s' "${value}" | sed 's/[\\&|]/\\&/g')"
    sed -i "s|^${var_name}=.*|${var_name}=${escaped}|" "${ENV_FILE}"
  else
    # A file without a final newline would otherwise join this to its last line
    [[ -s "${ENV_FILE}" && -n "$(tail -c 1 "${ENV_FILE}")" ]] && echo "" >> "${ENV_FILE}"
    echo "${var_name}=${value}" >> "${ENV_FILE}"
  fi
}

# Write a value that needs no decision to .env, keeping any already there. This
# checks the file rather than the environment: sudo passes some variables, such
# as TZ, through, and they must still end up in .env for later `docker compose`.
# A value from the environment is kept in preference to the default.
default_var() {
  grep -q "^$1=." "${ENV_FILE}" || set_env_var "$1" "${!1:-$2}"
}

random_hex() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

detect_timezone() {
  local tz
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [[ -z "${tz}" && -r /etc/timezone ]] && tz="$(cat /etc/timezone)"
  echo "${tz:-UTC}"
}

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  fail "Created .env from .env.example. Fill in its \"Required\" section, then run setup.sh again."
fi
chmod 600 "${ENV_FILE}"
set -a; source "${ENV_FILE}"; set +a

missing=()
for var in DOMAIN CLOUDFLARE_API_TOKEN ACCESS_EMAIL \
           S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_REGION; do
  [[ -n "${!var:-}" ]] || missing+=("${var}")
done
[[ ${#missing[@]} -eq 0 ]] || fail "Set these in ${ENV_FILE}, then run setup.sh again: ${missing[*]}"

default_var NEXTCLOUD_DATADIR        /opt/nextcloud/data
default_var BORG_BACKUP_DIR          /opt/nextcloud/borg-backup
default_var S3_PREFIX                nextcloud-borg
default_var MEDIA_DATA_DIR           /opt/media/data
default_var MEDIA_CONFIG_DIR         /opt/media/config
default_var NEXTCLOUD_UPLOAD_LIMIT   16G
default_var NEXTCLOUD_MAX_TIME       3600
default_var NEXTCLOUD_MEMORY_LIMIT   512M
default_var MEDIA_BIND_IP            127.0.0.1
default_var DECLUTTARR_TEST_RUN      true
default_var QBITTORRENT_TORRENT_PORT 6881
default_var TUNNEL_NAME              "$(uname -n | cut -d. -f1)"
default_var PUID                     "${SUDO_UID:-1000}"
default_var PGID                     "${SUDO_GID:-1000}"
default_var TZ                       "$(detect_timezone)"
default_var MEDIA_ADMIN_USER         admin
default_var MEDIA_ADMIN_PASSWORD     "$(random_hex)"
default_var SONARR_API_KEY           "$(random_hex)"
default_var RADARR_API_KEY           "$(random_hex)"
default_var PROWLARR_API_KEY         "$(random_hex)"

# qBittorrent only runs under this profile, so it can't start without a VPN
set_env_var COMPOSE_PROFILES "$([[ -n "${VPN_SERVICE_PROVIDER:-}" ]] && echo vpn || true)"

# The apps' host ports. These must match compose.yaml.
PROWLARR_PORT=9696
QBITTORRENT_PORT=8090
SONARR_PORT=8989
RADARR_PORT=7878
SEERR_PORT=5055
JELLYFIN_PORT=8096
AUDIOBOOKSHELF_PORT=13378
READMEABOOK_PORT=3030

# Where this server, and cloudflared on its host network, reach the app ports
MEDIA_HOST="${MEDIA_BIND_IP}"
[[ "${MEDIA_HOST}" == "0.0.0.0" ]] && MEDIA_HOST="127.0.0.1"

log ".env is complete."

# =============================================================================
# 2. System packages
# =============================================================================
header "System Packages"

# Never stop to ask a package's configuration questions
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
PKGS_NEEDED=()
for pkg in curl ca-certificates jq rclone unattended-upgrades; do
  dpkg -s "${pkg}" &>/dev/null || PKGS_NEEDED+=("${pkg}")
done
if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
  log "Installing: ${PKGS_NEEDED[*]}"
  apt-get install -y -qq "${PKGS_NEEDED[@]}"
fi

# Daily security updates
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
log "Packages ready; automatic security updates on."

# =============================================================================
# 3. Docker
# =============================================================================
header "Docker"

if ! command -v docker &>/dev/null; then
  log "Installing Docker CE..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker >/dev/null
# The plugin only exists in Docker's repository, not Debian's docker.io packages
docker compose version &>/dev/null || apt-get install -y -qq docker-compose-plugin \
  || fail "Docker Compose v2 is missing. Remove Debian's docker.io package and re-run setup.sh, which then installs Docker from Docker's repository."
log "$(docker --version), Compose $(docker compose version --short)"

# =============================================================================
# 4. Directories
# =============================================================================
header "Directories"

# AIO takes over the data directory's owner and mode, so only set them on creation.
if [[ ! -d "${NEXTCLOUD_DATADIR}" ]]; then
  mkdir -p "${NEXTCLOUD_DATADIR}"
  chmod 750 "${NEXTCLOUD_DATADIR}"
fi
mkdir -p "${BORG_BACKUP_DIR}"

# Only these directories are chowned, never their contents: the apps manage their
# own files, and a recursive chown of a media library can take hours.
# readmeabook's directories are created and owned by its own entrypoint.
for dir in \
  "${MEDIA_CONFIG_DIR}" \
  "${MEDIA_CONFIG_DIR}"/{prowlarr,qbittorrent,sonarr,radarr,jellyfin,audiobookshelf} \
  "${MEDIA_CONFIG_DIR}"/audiobookshelf/{config,metadata} \
  "${MEDIA_DATA_DIR}" \
  "${MEDIA_DATA_DIR}"/{torrents,media} \
  "${MEDIA_DATA_DIR}"/torrents/{incomplete,complete} \
  "${MEDIA_DATA_DIR}"/media/{movies,tv,audiobooks,books}; do
  mkdir -p "${dir}"
  chown "${PUID}:${PGID}" "${dir}"
done

# The Seerr image always runs as UID 1000
mkdir -p "${MEDIA_CONFIG_DIR}/seerr"
chown 1000:1000 "${MEDIA_CONFIG_DIR}/seerr"
log "Ready: ${NEXTCLOUD_DATADIR}, ${BORG_BACKUP_DIR}, ${MEDIA_CONFIG_DIR}, ${MEDIA_DATA_DIR}"

# =============================================================================
# 5. Cloudflare Tunnel, routes, DNS and Access
# =============================================================================
header "Cloudflare"

source "${SCRIPT_DIR}/configure-cloudflare.sh"
configure_cloudflare

# =============================================================================
# 6. Start everything
# =============================================================================
header "Containers"

COMPOSE=(docker compose --project-directory "${SCRIPT_DIR}")
log "Pulling images..."
"${COMPOSE[@]}" pull --quiet
# gluetun stays unhealthy with bad VPN settings, which fails this command. That
# keeps qBittorrent stopped but shouldn't stop the rest of setup.
if "${COMPOSE[@]}" up -d --remove-orphans; then
  log "All containers started."
else
  warn "Not every container started."
  note "Some containers did not start. Check \`sudo docker compose ps\`. If gluetun is unhealthy, check \`sudo docker logs gluetun\` and the VPN settings in \`.env\`."
fi

# =============================================================================
# 7. Daily offsite backup
# =============================================================================
header "Offsite Backup"

BACKUP_UNIT=nextcloud-offsite-backup
chmod +x "${SCRIPT_DIR}/backup-to-s3.sh"

cat > "/etc/systemd/system/${BACKUP_UNIT}.service" <<EOF
# Managed by setup.sh
[Unit]
Description=Copy Nextcloud AIO backups to S3
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/backup-to-s3.sh
EOF

# After AIO's daily backup, which NEXT_STEPS.md suggests scheduling for 03:00
cat > "/etc/systemd/system/${BACKUP_UNIT}.timer" <<EOF
# Managed by setup.sh
[Unit]
Description=Daily offsite copy of Nextcloud AIO backups

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${BACKUP_UNIT}.timer" >/dev/null
log "Daily copy to s3://${S3_BUCKET}/${S3_PREFIX}/ scheduled for 04:00."

# =============================================================================
# 8. Configure the media apps
# =============================================================================
header "Media Apps"

source "${SCRIPT_DIR}/configure-media.sh"
configure_media

# =============================================================================
# 9. What is left for a person to do
# =============================================================================
ssh_target="${SUDO_USER:-your-user}@$(hostname -I | awk '{print $1}')"

NEXTCLOUD_STEPS=()
if [[ -z "$(docker ps -q --filter 'name=^nextcloud-aio-apache$')" ]]; then
  NEXTCLOUD_STEPS+=("Open the AIO interface and enter \`cloud.${DOMAIN}\` as the domain. AIO then starts Nextcloud. It is only reachable over SSH: run \`ssh -L 8080:127.0.0.1:8080 ${ssh_target}\`, browse to https://localhost:8080 and accept the certificate warning.")
fi
if [[ -z "$(find "${BORG_BACKUP_DIR}" -maxdepth 2 -type f -name config -print -quit 2>/dev/null)" ]]; then
  NEXTCLOUD_STEPS+=("In the AIO interface, set the backup directory to \`${BORG_BACKUP_DIR}\`, store the backup password in a password manager, schedule daily backups for 03:00 and create the first backup.")
fi
if [[ ! -f /var/lib/nextcloud-offsite-backup/last-success ]]; then
  NEXTCLOUD_STEPS+=("After the first AIO backup, test the offsite copy: \`sudo systemctl start ${BACKUP_UNIT}\`, then check \`journalctl -u ${BACKUP_UNIT}\` ends with \"Sync complete\".")
fi

write_list() { local item; for item in "$@"; do echo "- [ ] ${item}"; done; }

{
  echo "# Next steps"
  echo ""
  echo "Generated by setup.sh on $(date '+%Y-%m-%d %H:%M'). Re-run setup.sh to refresh this list."
  echo ""
  echo "## Addresses"
  echo ""
  echo "Media apps sign in with \`MEDIA_ADMIN_USER\` and \`MEDIA_ADMIN_PASSWORD\` from \`.env\`. The admin apps also ask for a Cloudflare Access code sent to \`${ACCESS_EMAIL}\`."
  echo ""
  echo "| App | Address |"
  echo "|---|---|"
  echo "| Nextcloud | https://cloud.${DOMAIN} |"
  for app in Jellyfin Seerr Audiobookshelf ReadMeABook Sonarr Radarr Prowlarr qBittorrent; do
    echo "| ${app} | https://${app,,}.${DOMAIN} |"
  done
  echo "| AIO interface | https://localhost:8080 over \`ssh -L 8080:127.0.0.1:8080 ${ssh_target}\` |"
  if [[ ${#NEXTCLOUD_STEPS[@]} -gt 0 ]]; then
    echo ""
    echo "## Nextcloud"
    echo ""
    write_list "${NEXTCLOUD_STEPS[@]}"
  fi
  if [[ ${#NEXT_STEPS[@]} -gt 0 ]]; then
    echo ""
    echo "## Media and Cloudflare"
    echo ""
    write_list "${NEXT_STEPS[@]}"
  fi
} > "${SCRIPT_DIR}/NEXT_STEPS.md"
chmod 600 "${SCRIPT_DIR}/NEXT_STEPS.md"

# =============================================================================
# 10. Summary
# =============================================================================
header "Done"

"${COMPOSE[@]}" ps
echo ""
cat "${SCRIPT_DIR}/NEXT_STEPS.md"
echo ""
echo -e "${YELLOW}Saved to ${SCRIPT_DIR}/NEXT_STEPS.md. See README.md for details.${NC}"
