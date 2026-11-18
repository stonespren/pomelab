# shellcheck shell=bash
# =============================================================================
# media/seerr.sh — Seerr: sign in with Jellyfin, enable its libraries and
# connect Sonarr and Radarr.
#
# Sourced by configure-media.sh. Runs after Jellyfin, Sonarr and Radarr.
# =============================================================================

# Print the profile to use by default: HD-1080p, or else the first one.
arr_default_profile() {
  local port="$1" API_HEADER="X-Api-Key: $2" profiles
  profiles="$(api GET "http://${MEDIA_HOST}:${port}/api/v3/qualityprofile")" || return 1
  jq -ce 'first(.[] | select(.name == "HD-1080p")) // first(.[]) // empty | {id, name}' <<<"${profiles}"
}

configure_seerr() {
  local base="http://${MEDIA_HOST}:${SEERR_PORT}/api/v1" API_COOKIES="${MEDIA_TMP}/seerr"
  local status payload libraries profile id
  : >"${API_COOKIES}"
  wait_for_http "${base}/settings/public" Seerr || return 1

  status="$(api GET "${base}/settings/public")" || return 1
  [[ "$(jq -r '.initialized' <<<"${status}")" == "true" ]] && return 0

  # serverType 2 is Jellyfin. Once a server is saved, Seerr rejects a login that
  # names a hostname, so an interrupted earlier run retries without one.
  payload="$(jq -n --arg user "${MEDIA_ADMIN_USER}" --arg pass "${MEDIA_ADMIN_PASSWORD}" '{
    username: $user, password: $pass, email: $user, serverType: 2,
    hostname: "jellyfin", port: 8096, useSsl: false, urlBase: ""
  }')" || return 1
  if ! api POST "${base}/auth/jellyfin" "${payload}" >/dev/null; then
    payload="$(jq 'del(.hostname, .port, .useSsl, .urlBase, .serverType)' <<<"${payload}")" || return 1
    api POST "${base}/auth/jellyfin" "${payload}" >/dev/null || return 1
  fi

  libraries="$(api POST "${base}/settings/jellyfin/library/sync")" || return 1
  while IFS= read -r id; do
    api PUT "${base}/settings/jellyfin/library/${id}" '{"enabled":true}' >/dev/null || return 1
  done < <(jq -r '.[].id' <<<"${libraries}")

  status="$(api GET "${base}/settings/sonarr")" || return 1
  if [[ "$(jq 'length' <<<"${status}")" == 0 ]]; then
    profile="$(arr_default_profile "${SONARR_PORT}" "${SONARR_API_KEY}")" || return 1
    payload="$(jq -n --argjson profile "${profile}" --arg key "${SONARR_API_KEY}" '{
      name: "Sonarr", hostname: "sonarr", port: 8989, apiKey: $key, useSsl: false,
      activeProfileId: $profile.id, activeProfileName: $profile.name,
      activeDirectory: "/data/media/tv", seriesType: "standard", animeSeriesType: "standard",
      tags: [], animeTags: [], is4k: false, isDefault: true, enableSeasonFolders: true,
      syncEnabled: true, preventSearch: false, tagRequests: false, monitorNewItems: "all"
    }')" || return 1
    api POST "${base}/settings/sonarr" "${payload}" >/dev/null || return 1
  fi

  status="$(api GET "${base}/settings/radarr")" || return 1
  if [[ "$(jq 'length' <<<"${status}")" == 0 ]]; then
    profile="$(arr_default_profile "${RADARR_PORT}" "${RADARR_API_KEY}")" || return 1
    payload="$(jq -n --argjson profile "${profile}" --arg key "${RADARR_API_KEY}" '{
      name: "Radarr", hostname: "radarr", port: 7878, apiKey: $key, useSsl: false,
      activeProfileId: $profile.id, activeProfileName: $profile.name,
      activeDirectory: "/data/media/movies", minimumAvailability: "released",
      tags: [], is4k: false, isDefault: true,
      syncEnabled: true, preventSearch: false, tagRequests: false
    }')" || return 1
    api POST "${base}/settings/radarr" "${payload}" >/dev/null || return 1
  fi

  api POST "${base}/settings/initialize" '{}' >/dev/null
}

setup_seerr() {
  run_step seerr "Seerr" \
    "Finish the Seerr wizard at https://seerr.${DOMAIN}: Jellyfin at \`http://jellyfin:8096\`, Sonarr at \`sonarr:8989\` with root \`/data/media/tv\`, Radarr at \`radarr:7878\` with root \`/data/media/movies\`." \
    configure_seerr
}
