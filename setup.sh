#!/usr/bin/env bash
# =============================================================================
# setup.sh — Idempotent server setup for Debian: Nextcloud AIO, Cloudflare Tunnel
# and the media stack.
#
# Safe to run multiple times. Skips steps that are already done.
# Run as root (or with sudo).
#
# Whatever still needs a person is written to NEXT_STEPS.md, which is rebuilt on
# every run so it only lists what is still outstanding.
#
# Usage:
#   sudo ./setup.sh
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[setup]${NC} $*"; }
warn()   { echo -e "${YELLOW}[setup]${NC} WARN: $*"; }
info()   { echo -e "${CYAN}[setup]${NC} $*"; }
fail()   { echo -e "${RED}[setup]${NC} ERROR: $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

# =============================================================================
# 0. Privilege check
# =============================================================================
if [[ "${EUID}" -ne 0 ]]; then
  fail "Please run as root: sudo ./setup.sh"
fi

# =============================================================================
# 1. Load or interactively build .env
# =============================================================================
header "Environment Configuration"

prompt_var() {
  local var_name="$1"
  local prompt_text="$2"
  local default_val="${3:-}"
  local secret="${4:-false}"
  local current_val="${!var_name:-}"

  [[ -n "${current_val}" ]] && return 0

  if [[ "${secret}" == "true" ]]; then
    read -rsp "  ${prompt_text} [${default_val:-(required)}]: " input_val
    echo ""
  else
    read -rp "  ${prompt_text} [${default_val:-(required)}]: " input_val
  fi

  input_val="${input_val:-${default_val}}"
  [[ -z "${input_val}" ]] && fail "${var_name} is required."

  set_env_var "${var_name}" "${input_val}"
}

set_env_var() {
  local var_name="$1" value="$2" escaped
  export "${var_name}=${value}"
  if grep -q "^${var_name}=" "${ENV_FILE}" 2>/dev/null; then
    escaped="$(printf '%s' "${value}" | sed 's/[\\&|]/\\&/g')"
    sed -i "s|^${var_name}=.*|${var_name}=${escaped}|" "${ENV_FILE}"
  else
    # A file without a final newline would otherwise join this to its last line
    [[ -s "${ENV_FILE}" && -n "$(tail -c 1 "${ENV_FILE}")" ]] && echo "" >> "${ENV_FILE}"
    echo "${var_name}=${value}" >> "${ENV_FILE}"
  fi
}

# Fill in a value that needs no decision from the user, keeping any existing one
default_var() {
  local var_name="$1" default_val="$2"
  [[ -n "${!var_name:-}" ]] && return 0
  set_env_var "${var_name}" "${default_val}"
}

random_hex() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

detect_timezone() {
  local tz
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [[ -z "${tz}" && -r /etc/timezone ]] && tz="$(cat /etc/timezone)"
  echo "${tz:-UTC}"
}

if [[ ! -f "${ENV_FILE}" ]]; then
  [[ -f "${SCRIPT_DIR}/.env.example" ]] && cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}" || touch "${ENV_FILE}"
  log "Created .env"
fi

set -a; source "${ENV_FILE}"; set +a

# Manual steps collected along the way and written to NEXT_STEPS.md at the end
NEXT_STEPS=()
note() { NEXT_STEPS+=("$1"); }

info "Checking required configuration values..."

prompt_var "CLOUDFLARE_TUNNEL_TOKEN"  "Cloudflare Tunnel token"                   ""
prompt_var "NEXTCLOUD_DATADIR"        "Nextcloud data directory on host"           "/opt/nextcloud/data"
prompt_var "NEXTCLOUD_UPLOAD_LIMIT"   "Max upload size"                            "16G"
prompt_var "NEXTCLOUD_MAX_TIME"       "PHP max execution time (seconds)"           "3600"
prompt_var "NEXTCLOUD_MEMORY_LIMIT"   "PHP memory limit per process"               "512M"
prompt_var "BORG_BACKUP_DIR"          "Local Borg backup directory (for S3 sync)"  "/opt/nextcloud/borg-backup"
prompt_var "AWS_ACCESS_KEY_ID"        "AWS/S3 Access Key ID"                       ""
prompt_var "AWS_SECRET_ACCESS_KEY"    "AWS/S3 Secret Access Key"                   "" "true"
prompt_var "S3_REGION"                "S3 region"                                  "us-east-1"
prompt_var "S3_BUCKET"                "S3 bucket name for backups"                 ""
prompt_var "S3_BACKUP_PREFIX"         "S3 key prefix / folder"                     "nextcloud-borg"
prompt_var "MEDIA_DATA_DIR"           "Media and downloads directory on host"      "/opt/media/data"

# Everything below has a sensible value, so it is filled in without asking.
# Change any of these in .env and re-run setup.sh.
default_var "MEDIA_CONFIG_DIR"         "/opt/media/config"
default_var "MEDIA_BIND_IP"            "127.0.0.1"
default_var "PUID"                     "${SUDO_UID:-1000}"
default_var "PGID"                     "${SUDO_GID:-1000}"
default_var "TZ"                       "$(detect_timezone)"
default_var "PROWLARR_PORT"            "8109"
default_var "QBITTORRENT_PORT"         "8133"
default_var "QBITTORRENT_TORRENT_PORT" "6881"
default_var "SONARR_PORT"              "8098"
default_var "RADARR_PORT"              "8088"
default_var "SEERR_PORT"               "5055"
default_var "JELLYFIN_PORT"            "8091"
default_var "AUDIOBOOKSHELF_PORT"      "13378"
default_var "READMEABOOK_PORT"         "3030"
default_var "DECLUTTARR_TEST_RUN"      "true"
default_var "VPN_TYPE"                 "wireguard"
default_var "VPN_PORT_FORWARDING"      "off"
default_var "MEDIA_ADMIN_USER"         "admin"
default_var "MEDIA_ADMIN_PASSWORD"     "$(random_hex)"
default_var "SONARR_API_KEY"           "$(random_hex)"
default_var "RADARR_API_KEY"           "$(random_hex)"
default_var "PROWLARR_API_KEY"         "$(random_hex)"

# qBittorrent only runs under this profile, so it can't start without a VPN
if [[ -n "${VPN_SERVICE_PROVIDER:-}" ]]; then
  set_env_var "COMPOSE_PROFILES" "vpn"
else
  set_env_var "COMPOSE_PROFILES" ""
fi

set -a; source "${ENV_FILE}"; set +a
chmod 600 "${ENV_FILE}"
log ".env configured (chmod 600)"

# =============================================================================
# 2. System packages
# =============================================================================
header "System Packages"

log "Updating apt..."
apt-get update -qq

PKGS_NEEDED=()
for pkg in curl ca-certificates gnupg jq lsb-release unzip cron; do
  dpkg -s "${pkg}" &>/dev/null || PKGS_NEEDED+=("${pkg}")
done
if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
  log "Installing: ${PKGS_NEEDED[*]}"
  apt-get install -y -qq "${PKGS_NEEDED[@]}"
else
  log "Required packages already installed."
fi

log "Ensuring cron service is enabled and running..."
systemctl enable --now cron

# =============================================================================
# 3. Docker
# =============================================================================
header "Docker"

install_docker() {
  log "Installing Docker CE..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker
  log "Docker installed."
}

if ! command -v docker &>/dev/null; then
  install_docker
else
  log "Docker already installed: $(docker --version)"
fi

if ! docker compose version &>/dev/null; then
  apt-get install -y -qq docker-compose-plugin
fi
log "Docker Compose: $(docker compose version --short)"

# Add the invoking user to the docker group
if [[ -n "${SUDO_USER:-}" ]] && ! groups "${SUDO_USER}" | grep -q docker; then
  usermod -aG docker "${SUDO_USER}"
  warn "Added ${SUDO_USER} to the docker group. Log out and back in for this to take effect."
fi

# =============================================================================
# 4. AWS CLI v2
# =============================================================================
header "AWS CLI"

install_awscli() {
  local arch url tmp_dir
  arch="$(uname -m)"
  case "${arch}" in
    x86_64)  url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"   ;;
    aarch64) url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"  ;;
    *)       fail "Unsupported architecture for AWS CLI: ${arch}" ;;
  esac
  log "Downloading AWS CLI v2 (${arch})..."
  tmp_dir="$(mktemp -d)"
  curl -fsSL "${url}" -o "${tmp_dir}/awscliv2.zip"
  unzip -q "${tmp_dir}/awscliv2.zip" -d "${tmp_dir}"
  "${tmp_dir}/aws/install" --update
  rm -rf "${tmp_dir}"
  log "AWS CLI installed: $(aws --version 2>&1 | head -1)"
}

if ! command -v aws &>/dev/null; then
  install_awscli
else
  log "AWS CLI already installed: $(aws --version 2>&1 | head -1)"
fi

# =============================================================================
# 5. Create data/backup directories
# =============================================================================
header "Directories"

for dir in "${NEXTCLOUD_DATADIR}" "${BORG_BACKUP_DIR}"; do
  if [[ ! -d "${dir}" ]]; then
    mkdir -p "${dir}"
    log "Created: ${dir}"
  else
    log "Exists:  ${dir}"
  fi
done
# The data dir needs to be writable by the AIO containers (they'll set perms internally)
chmod 750 "${NEXTCLOUD_DATADIR}"

# Only these directories are chowned, never their contents: the apps manage their
# own files, and a recursive chown of a media library can take hours.
# readmeabook's directories are created and owned by its own entrypoint.
for dir in \
  "${MEDIA_CONFIG_DIR}" \
  "${MEDIA_CONFIG_DIR}"/{prowlarr,qbittorrent,sonarr,radarr,jellyfin} \
  "${MEDIA_CONFIG_DIR}"/audiobookshelf/{config,metadata} \
  "${MEDIA_DATA_DIR}" \
  "${MEDIA_DATA_DIR}"/torrents/{incomplete,complete} \
  "${MEDIA_DATA_DIR}"/media/{movies,tv,audiobooks,books}; do
  mkdir -p "${dir}"
  chown "${PUID}:${PGID}" "${dir}"
done
chown "${PUID}:${PGID}" "${MEDIA_CONFIG_DIR}/audiobookshelf" "${MEDIA_DATA_DIR}/torrents" "${MEDIA_DATA_DIR}/media"

# The Seerr image always runs as UID 1000
mkdir -p "${MEDIA_CONFIG_DIR}/seerr"
chown 1000:1000 "${MEDIA_CONFIG_DIR}/seerr"
log "Media directories ready under ${MEDIA_CONFIG_DIR} and ${MEDIA_DATA_DIR}"

# =============================================================================
# 6. Pull images and start the stack
# =============================================================================
header "Starting Nextcloud AIO Stack"

log "Pulling latest images..."
docker compose -f "${SCRIPT_DIR}/compose.yaml" pull

log "Starting containers..."
docker compose -f "${SCRIPT_DIR}/compose.yaml" up -d --remove-orphans

log "Stack started."

header "Starting Media Stack"

log "Pulling latest images..."
docker compose -f "${SCRIPT_DIR}/compose.media.yaml" pull

log "Starting containers..."
# gluetun stays unhealthy with bad VPN settings, which fails this command. That
# keeps qBittorrent stopped but shouldn't stop the rest of setup.
if docker compose -f "${SCRIPT_DIR}/compose.media.yaml" up -d --remove-orphans; then
  log "Media stack started."
else
  warn "Not every media container started."
  note "Some media containers did not start. Check \`docker compose -f compose.media.yaml ps\`. If gluetun is unhealthy, check \`docker logs gluetun\` and your VPN settings in \`.env\`."
fi

# =============================================================================
# 7. Cron job: sync AIO's Borg backup to S3
# =============================================================================
header "S3 Backup Sync Cron"

SYNC_SCRIPT="${SCRIPT_DIR}/backup-to-s3.sh"
chmod +x "${SYNC_SCRIPT}"

# Sync to S3 daily at 04:00 (after AIO's typical 03:xx backup window)
CRON_LINE="0 4 * * * root ${SYNC_SCRIPT} >> /var/log/nextcloud-s3-sync.log 2>&1"
CRON_FILE="/etc/cron.d/nextcloud-s3-sync"

cat > "${CRON_FILE}" <<CRONEOF
# Sync Nextcloud AIO Borg backup to S3 — managed by setup.sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${CRON_LINE}
CRONEOF
chmod 644 "${CRON_FILE}"
log "S3 sync cron job written to ${CRON_FILE}"

touch /var/log/nextcloud-s3-sync.log
chmod 640 /var/log/nextcloud-s3-sync.log

cat > /etc/logrotate.d/nextcloud-s3-sync <<ROTEOF
/var/log/nextcloud-s3-sync.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
}
ROTEOF

# =============================================================================
# 8. Configure the media apps
# =============================================================================
header "Configuring Media Apps"

source "${SCRIPT_DIR}/configure-media.sh"
configure_media

# =============================================================================
# 9. Work out what is left for a person to do
# =============================================================================
ssh_target="${SUDO_USER:-your-user}@$(hostname -I | awk '{print $1}')"
media_forwards=""
for port in "${PROWLARR_PORT}" "${QBITTORRENT_PORT}" "${SONARR_PORT}" "${RADARR_PORT}" \
            "${SEERR_PORT}" "${JELLYFIN_PORT}" "${AUDIOBOOKSHELF_PORT}" "${READMEABOOK_PORT}"; do
  media_forwards+=" -L ${port}:${MEDIA_BIND_IP/#0.0.0.0/127.0.0.1}:${port}"
done

NEXTCLOUD_STEPS=()
if [[ -z "$(docker ps -q --filter 'name=^nextcloud-aio-apache$')" ]]; then
  NEXTCLOUD_STEPS+=("In the Cloudflare Zero Trust dashboard, add a public hostname to the tunnel for Nextcloud: type \`HTTP\`, URL \`localhost:11000\`.")
  NEXTCLOUD_STEPS+=("Turn off Rocket Loader for your domain: Cloudflare Dashboard > your domain > Speed > Optimization > Content Optimization. Nextcloud's login page breaks without this.")
  NEXTCLOUD_STEPS+=("Open the AIO interface and enter your domain. AIO then starts the Nextcloud containers. Tunnel: \`ssh -L 8080:127.0.0.1:8080 ${ssh_target}\`, then browse to https://localhost:8080 and accept the certificate warning.")
fi
if [[ -z "$(find "${BORG_BACKUP_DIR}" -maxdepth 2 -type f -name config -print -quit 2>/dev/null)" ]]; then
  NEXTCLOUD_STEPS+=("In the AIO interface, set the backup directory to \`${BORG_BACKUP_DIR}\`, store the backup password somewhere safe, enable daily backups (e.g. 03:00) and create the first backup.")
fi
if ! grep -q "Sync complete" /var/log/nextcloud-s3-sync.log 2>/dev/null; then
  NEXTCLOUD_STEPS+=("After the first AIO backup, test the offsite sync: \`sudo ${SYNC_SCRIPT}\`")
fi

write_list() {
  local item
  for item in "$@"; do echo "- [ ] ${item}"; done
}

{
  echo "# Next steps"
  echo ""
  echo "Generated by setup.sh on $(date '+%Y-%m-%d %H:%M'). Re-run setup.sh to refresh this list."
  echo ""
  echo "## Reaching the media apps"
  echo ""
  echo "Their ports are only bound to ${MEDIA_BIND_IP}. From your own computer:"
  echo ""
  echo "    ssh${media_forwards} ${ssh_target}"
  echo ""
  echo "Then use the \`http://localhost:<port>\` addresses below. Sign in with \`MEDIA_ADMIN_USER\` and \`MEDIA_ADMIN_PASSWORD\` from \`.env\`."
  echo ""
  echo "| App | Address |"
  echo "|---|---|"
  echo "| Jellyfin | http://localhost:${JELLYFIN_PORT} |"
  echo "| Seerr | http://localhost:${SEERR_PORT} |"
  echo "| Audiobookshelf | http://localhost:${AUDIOBOOKSHELF_PORT} |"
  echo "| ReadMeABook | http://localhost:${READMEABOOK_PORT} |"
  echo "| Sonarr | http://localhost:${SONARR_PORT} |"
  echo "| Radarr | http://localhost:${RADARR_PORT} |"
  echo "| Prowlarr | http://localhost:${PROWLARR_PORT} |"
  echo "| qBittorrent | http://localhost:${QBITTORRENT_PORT} |"
  if [[ ${#NEXTCLOUD_STEPS[@]} -gt 0 ]]; then
    echo ""
    echo "## Nextcloud"
    echo ""
    write_list "${NEXTCLOUD_STEPS[@]}"
  fi
  if [[ ${#NEXT_STEPS[@]} -gt 0 ]]; then
    echo ""
    echo "## Media stack"
    echo ""
    write_list "${NEXT_STEPS[@]}"
  fi
  echo ""
  if [[ -z "${MEDIA_DOMAIN:-}" ]]; then
    echo "## Optional"
    echo ""
    echo "- [ ] To reach the apps at \`<app>.yourdomain.com\`, set \`MEDIA_DOMAIN\` and \`CLOUDFLARE_API_TOKEN\` in \`.env\` and re-run setup.sh. See README.md."
  fi
} > "${SCRIPT_DIR}/NEXT_STEPS.md"
chmod 600 "${SCRIPT_DIR}/NEXT_STEPS.md"

# =============================================================================
# 10. Summary
# =============================================================================
header "Setup Complete"

echo ""
echo -e "${BOLD}Running containers:${NC}"
docker compose -f "${SCRIPT_DIR}/compose.yaml" ps
docker compose -f "${SCRIPT_DIR}/compose.media.yaml" ps

echo ""
cat "${SCRIPT_DIR}/NEXT_STEPS.md"
echo ""
echo -e "${YELLOW}Saved to ${SCRIPT_DIR}/NEXT_STEPS.md. See README.md for full documentation.${NC}"
