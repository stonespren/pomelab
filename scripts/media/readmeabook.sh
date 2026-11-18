# shellcheck shell=bash
# =============================================================================
# media/readmeabook.sh — ReadMeABook: its wizard needs choices only a person
# can make, so this only checks whether it is done and lists the values to use.
#
# Sourced by configure-media.sh. Re-checked on every run.
# =============================================================================

readmeabook_pending() {
  local status
  status="$(api GET "http://${MEDIA_HOST}:${READMEABOOK_PORT}/api/setup/status" | jq -r '.setupComplete' || true)"
  if [[ "${status}" != "true" ]]; then
    note "After adding indexers, finish the ReadMeABook wizard at https://readmeabook.${DOMAIN}. It needs choices only you can make, such as which indexers to use and your Audible region. Use these values:
    - Backend: Audiobookshelf, \`http://audiobookshelf:13378\`, library \`Audiobooks\`. Create the API token in Audiobookshelf under Settings > Users > ${MEDIA_ADMIN_USER}.
    - Prowlarr: \`http://prowlarr:9696\`, API key \`PROWLARR_API_KEY\` from \`.env\`.
    - qBittorrent: \`http://qbittorrent:${QBITTORRENT_PORT}\`, user \`${MEDIA_ADMIN_USER}\`, password \`MEDIA_ADMIN_PASSWORD\` from \`.env\`.
    - Download directory: \`/data/torrents/complete\`. Media directory: \`/data/media/audiobooks\`."
  fi
}
