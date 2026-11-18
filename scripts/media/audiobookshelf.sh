# shellcheck shell=bash
# =============================================================================
# media/audiobookshelf.sh — Audiobookshelf: create the root user and add the
# Audiobooks and Ebooks libraries.
#
# Sourced by configure-media.sh.
# =============================================================================

abs_add_library() {
  local base="$1" name="$2" path="$3" current payload
  current="$(api GET "${base}/api/libraries")" || return 1
  jq -e --arg name "${name}" 'any(.libraries[]; .name == $name)' <<<"${current}" >/dev/null && return 0
  payload="$(jq -n --arg name "${name}" --arg path "${path}" \
    '{name: $name, mediaType: "book", provider: "audible", folders: [{fullPath: $path}]}')" || return 1
  api POST "${base}/api/libraries" "${payload}" >/dev/null
}

configure_audiobookshelf() {
  local base="http://${MEDIA_HOST}:${AUDIOBOOKSHELF_PORT}" status payload token API_HEADER=""
  wait_for_http "${base}/ping" Audiobookshelf || return 1

  status="$(api GET "${base}/status")" || return 1
  if [[ "$(jq -r '.isInit' <<<"${status}")" != "true" ]]; then
    payload="$(jq -n --arg user "${MEDIA_ADMIN_USER}" --arg pass "${MEDIA_ADMIN_PASSWORD}" \
      '{newRoot: {username: $user, password: $pass}}')" || return 1
    api POST "${base}/init" "${payload}" >/dev/null || return 1
  fi

  payload="$(jq -n --arg user "${MEDIA_ADMIN_USER}" --arg pass "${MEDIA_ADMIN_PASSWORD}" \
    '{username: $user, password: $pass}')" || return 1
  token="$(api POST "${base}/login" "${payload}" | jq -re '.user.accessToken')" || return 1
  API_HEADER="Authorization: Bearer ${token}"

  abs_add_library "${base}" Audiobooks /data/media/audiobooks || return 1
  abs_add_library "${base}" Ebooks /data/media/books || return 1
}

setup_audiobookshelf() {
  run_step audiobookshelf "Audiobookshelf" \
    "Finish setup in Audiobookshelf at https://audiobookshelf.${DOMAIN}, then add the libraries \`/data/media/audiobooks\` and \`/data/media/books\`." \
    configure_audiobookshelf
}
