#!/usr/bin/env bash
# =============================================================================
# setup.sh — Idempotent Nextcloud AIO + Cloudflare Tunnel setup for Debian
#
# Safe to run multiple times. Skips steps that are already done.
# Run as root (or with sudo).
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

  export "${var_name}=${input_val}"
  if grep -q "^${var_name}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${var_name}=.*|${var_name}=${input_val}|" "${ENV_FILE}"
  else
    echo "${var_name}=${input_val}" >> "${ENV_FILE}"
  fi
}

if [[ ! -f "${ENV_FILE}" ]]; then
  [[ -f "${SCRIPT_DIR}/.env.example" ]] && cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}" || touch "${ENV_FILE}"
  log "Created .env"
fi

set -a; source "${ENV_FILE}"; set +a

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
for pkg in curl ca-certificates gnupg lsb-release unzip; do
  dpkg -s "${pkg}" &>/dev/null || PKGS_NEEDED+=("${pkg}")
done
if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
  log "Installing: ${PKGS_NEEDED[*]}"
  apt-get install -y -qq "${PKGS_NEEDED[@]}"
else
  log "Required packages already installed."
fi

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

# =============================================================================
# 6. Pull images and start the stack
# =============================================================================
header "Starting Nextcloud AIO Stack"

log "Pulling latest images..."
docker compose -f "${SCRIPT_DIR}/compose.yaml" pull

log "Starting containers..."
docker compose -f "${SCRIPT_DIR}/compose.yaml" up -d --remove-orphans

log "Stack started."

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
# 8. Summary
# =============================================================================
header "Setup Complete"

echo ""
echo -e "${BOLD}Running containers:${NC}"
docker compose -f "${SCRIPT_DIR}/compose.yaml" ps

echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo "  1. Open the AIO admin interface in your browser (use IP, NOT domain):"
echo "       https://$(hostname -I | awk '{print $1}'):8080"
echo "       (Accept the self-signed certificate warning)"
echo ""
echo "  2. Enter your domain: ${NEXTCLOUD_DOMAIN:-cloud.yourdomain.com}"
echo "     Then click 'Submit' — AIO will start all sub-containers automatically."
echo ""
echo "  3. Once Nextcloud is running, configure Borg backup in the AIO interface:"
echo "       Backup directory: ${BORG_BACKUP_DIR}"
echo "       Set a strong backup password and save it somewhere safe!"
echo "       Enable 'Daily backup' and set a backup time (e.g. 03:00)."
echo ""
echo "  4. Run a test S3 sync (after AIO has run its first backup):"
echo "       sudo ${SYNC_SCRIPT}"
echo ""
echo "  5. In the Cloudflare Zero Trust dashboard, verify the tunnel ingress:"
echo "       Public hostname: your-domain.com"
echo "       Type: HTTP   URL: localhost:11000"
echo ""
echo "  6. Disable Cloudflare's Rocket Loader for your domain:"
echo "       Cloudflare Dashboard > your domain > Speed > Optimization"
echo "       > Content Optimization > Rocket Loader → OFF"
echo ""
echo -e "${YELLOW}See README.md for full documentation.${NC}"
