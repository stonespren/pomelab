# shellcheck shell=bash
# media/radarr.sh — Radarr: movies root folder and login. Sourced by configure-media.sh.

setup_radarr() {
  run_step radarr "Radarr" \
    "Configure Radarr at https://radarr.${DOMAIN}: root folder \`/data/media/movies\`. ${MEDIA_SEE_LOGIN}" \
    configure_arr Radarr "${RADARR_PORT}" "${RADARR_API_KEY}" /data/media/movies
}
