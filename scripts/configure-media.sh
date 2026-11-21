# shellcheck shell=bash
# =============================================================================
# configure-media.sh — Configure the media stack through each app's own API.
#
# Sourced by setup.sh, which provides log, warn, note, MEDIA_HOST, the app ports
# and the values from .env. Nothing runs until setup.sh calls configure_media.
# Each app's steps live in media/<app>.sh; shared helpers are in media/common.sh.
#
# Each step runs once. When it succeeds a marker is written to
# MEDIA_CONFIG_DIR/.setup-state, and later runs leave that app alone, so changes
# you make in an app's own UI are never overwritten. To run a step again, delete
# its marker and re-run setup.sh.
#
# A failed step adds a manual instruction to NEXT_STEPS.md instead of stopping
# setup.
# =============================================================================

MEDIA_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/media" && pwd)"

# shellcheck source=media/common.sh
source "${MEDIA_SCRIPTS_DIR}/common.sh"
for app in sonarr radarr qbittorrent sabnzbd prowlarr flaresolverr jellyfin audiobookshelf seerr readmeabook decluttarr libation; do
  # shellcheck source=/dev/null
  source "${MEDIA_SCRIPTS_DIR}/${app}.sh"
done
unset app

configure_media() {
  MEDIA_STATE_DIR="${MEDIA_CONFIG_DIR}/.setup-state"
  MEDIA_TMP="$(mktemp -d)"
  # Holds login cookies, so remove it even if setup stops early.
  trap 'rm -rf "${MEDIA_TMP}"' EXIT
  mkdir -p "${MEDIA_STATE_DIR}"

  # Order matters: each app connects to the ones set up before it.
  setup_sonarr
  setup_radarr
  setup_qbittorrent
  setup_sabnzbd
  check_vpn
  setup_prowlarr
  setup_flaresolverr
  setup_jellyfin
  setup_audiobookshelf
  setup_seerr

  # Things only a person can decide or do; re-checked on every run.
  prowlarr_pending
  sabnzbd_pending
  readmeabook_pending
  decluttarr_pending
  libation_pending
}
