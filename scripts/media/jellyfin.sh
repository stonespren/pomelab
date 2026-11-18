# shellcheck shell=bash
# =============================================================================
# media/jellyfin.sh — Jellyfin: run the startup wizard and add the Movies and
# Shows libraries.
#
# Sourced by configure-media.sh.
# =============================================================================

jellyfin_add_library() {
  local base="$1" name="$2" type="$3" path="$4" current
  current="$(api GET "${base}/Library/VirtualFolders")" || return 1
  jq -e --arg name "${name}" 'any(.[]; .Name == $name)' <<<"${current}" >/dev/null && return 0
  api POST "${base}/Library/VirtualFolders?name=${name}&collectionType=${type}&paths=${path}&refreshLibrary=false" \
    '{"LibraryOptions":{}}' >/dev/null
}

configure_jellyfin() {
  local base="http://${MEDIA_HOST}:${JELLYFIN_PORT}" info payload token
  # The quotes are escaped because this header passes through a curl config file.
  local API_HEADER='Authorization: MediaBrowser Client=\"setup\", Device=\"setup\", DeviceId=\"setup\", Version=\"1\"'
  wait_for_http "${base}/health" Jellyfin || return 1

  info="$(api GET "${base}/System/Info/Public")" || return 1
  if [[ "$(jq -r '.StartupWizardCompleted' <<<"${info}")" != "true" ]]; then
    api POST "${base}/Startup/Configuration" \
      '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null || return 1
    # The first user only exists after this GET.
    api GET "${base}/Startup/User" >/dev/null || return 1
    payload="$(jq -n --arg name "${MEDIA_ADMIN_USER}" --arg pass "${MEDIA_ADMIN_PASSWORD}" \
      '{Name: $name, Password: $pass}')" || return 1
    api POST "${base}/Startup/User" "${payload}" >/dev/null || return 1
    api POST "${base}/Startup/RemoteAccess" \
      '{"EnableRemoteAccess":true}' >/dev/null || return 1
    api POST "${base}/Startup/Complete" '{}' >/dev/null || return 1
  fi

  payload="$(jq -n --arg name "${MEDIA_ADMIN_USER}" --arg pass "${MEDIA_ADMIN_PASSWORD}" \
    '{Username: $name, Pw: $pass}')" || return 1
  token="$(api POST "${base}/Users/AuthenticateByName" "${payload}" | jq -re '.AccessToken')" || return 1
  API_HEADER="X-Emby-Token: ${token}"

  jellyfin_add_library "${base}" Movies movies /data/media/movies || return 1
  jellyfin_add_library "${base}" Shows tvshows /data/media/tv || return 1
}

setup_jellyfin() {
  run_step jellyfin "Jellyfin" \
    "Finish the Jellyfin wizard at https://jellyfin.${DOMAIN}, then add the libraries \`/data/media/movies\` and \`/data/media/tv\`." \
    configure_jellyfin
}
