# shellcheck shell=bash
# media/sonarr.sh — Sonarr: TV root folder and login. Sourced by configure-media.sh.

setup_sonarr() {
  run_step sonarr "Sonarr" \
    "Configure Sonarr at https://sonarr.${DOMAIN}: root folder \`/data/media/tv\`. ${MEDIA_SEE_LOGIN}" \
    configure_arr Sonarr "${SONARR_PORT}" "${SONARR_API_KEY}" /data/media/tv
}
