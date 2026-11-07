# shellcheck shell=bash
# =============================================================================
# configure-media.sh — Configure the media stack through each app's own API.
#
# Sourced by setup.sh, which provides log, warn, note and the values from .env.
# Nothing runs until setup.sh calls configure_media.
#
# Each step runs once. When it succeeds a marker is written to
# MEDIA_CONFIG_DIR/.setup-state, and later runs leave that app alone, so changes
# you make in an app's own UI are never overwritten. To run a step again, delete
# its marker and re-run setup.sh.
#
# A failed step adds a manual instruction to NEXT_STEPS.md instead of stopping
# setup. Steps run in `if` conditions, where `set -e` has no effect, so every
# call that can fail below needs its own `|| return 1`.
# =============================================================================

# Print a response body, or return non-zero and warn on an error status.
# Callers may set API_HEADER and API_COOKIES as locals.
api() {
  local method="$1" url="$2" body="${3:-}" response status
  local args=(-sS --max-time 120 -X "${method}" -w '\n%{http_code}')
  if [[ -n "${API_COOKIES:-}" ]]; then args+=(-b "${API_COOKIES}" -c "${API_COOKIES}"); fi
  if [[ -n "${body}" ]]; then args+=(-H 'Content-Type: application/json' --data-binary @-); fi

  # The header goes through a config file descriptor so API keys stay out of `ps`.
  response="$(curl "${args[@]}" \
    --config <(printf 'header = "%s"\n' "${API_HEADER:-Accept: */*}") \
    "${url}" <<<"${body}")" || return 1

  status="${response##*$'\n'}"
  response="${response%$'\n'*}"
  if [[ ! "${status}" =~ ^2 ]]; then
    # To stderr, because callers capture this function's stdout
    warn "${method} ${url} returned HTTP ${status}: ${response:0:300}" >&2
    return 1
  fi
  printf '%s' "${response}"
}

wait_for_http() {
  local url="$1" name="$2" code
  for _ in {1..150}; do
    code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "${url}" || true)"
    [[ "${code}" =~ ^[234] ]] && return 0
    sleep 2
  done
  warn "${name} did not respond at ${url} within 5 minutes."
  return 1
}

# run_step ID DESCRIPTION MANUAL_INSTRUCTION COMMAND [ARGS...]
run_step() {
  local id="$1" description="$2" manual="$3"
  shift 3
  if [[ -f "${MEDIA_STATE_DIR}/${id}" ]]; then
    log "${description}: already configured."
  elif "$@"; then
    touch "${MEDIA_STATE_DIR}/${id}"
    log "${description}: configured."
  else
    warn "${description}: could not be configured automatically."
    note "${manual}"
  fi
}

# jq: set the named entries of a Servarr schema's "fields" array.
JQ_WITH_FIELDS='def with_fields($v): .fields |= map(if $v[.name] != null then .value = $v[.name] else . end);'

# -----------------------------------------------------------------------------
# qBittorrent
# -----------------------------------------------------------------------------
qbit_login() {
  local url="$1" jar="$2" username="$3" password="$4" code
  rm -f "${jar}"
  printf '%s' "${password}" | curl -sS -o /dev/null --max-time 30 -c "${jar}" \
    -H "Referer: ${url}" --data-urlencode "username=${username}" \
    --data-urlencode "password@-" "${url}/api/v2/auth/login" || return 1
  code="$(curl -s -o /dev/null --max-time 30 -b "${jar}" -w '%{http_code}' \
    "${url}/api/v2/app/version")" || return 1
  [[ "${code}" == 200 ]]
}

configure_qbittorrent() {
  local url="http://${MEDIA_HOST}:${QBITTORRENT_PORT}" jar="${MEDIA_TMP}/qbit" temp_password prefs
  wait_for_http "${url}" qBittorrent || return 1

  if ! qbit_login "${url}" "${jar}" "${MEDIA_ADMIN_USER}" "${MEDIA_ADMIN_PASSWORD}"; then
    temp_password="$(docker logs qbittorrent 2>&1 \
      | sed -n 's/.*temporary password is provided for this session: //p' | tail -n 1)"
    if [[ -z "${temp_password}" ]]; then
      warn "qBittorrent's temporary password is not in its logs."
      return 1
    fi
    qbit_login "${url}" "${jar}" admin "${temp_password}" || return 1
  fi

  prefs="$(jq -n --arg user "${MEDIA_ADMIN_USER}" --arg pass "${MEDIA_ADMIN_PASSWORD}" '{
    save_path: "/data/torrents/complete",
    temp_path_enabled: true,
    temp_path: "/data/torrents/incomplete",
    bypass_local_auth: true,
    web_ui_username: $user,
    web_ui_password: $pass
  }')" || return 1
  printf '%s' "${prefs}" | curl -fsS -o /dev/null --max-time 30 -b "${jar}" \
    -H "Referer: ${url}" --data-urlencode "json@-" \
    "${url}/api/v2/app/setPreferences" || return 1

  sleep 2
  qbit_login "${url}" "${jar}" "${MEDIA_ADMIN_USER}" "${MEDIA_ADMIN_PASSWORD}" || return 1

  # Decluttarr started before these credentials existed.
  docker restart decluttarr >/dev/null || warn "Could not restart decluttarr."
}

# -----------------------------------------------------------------------------
# Sonarr, Radarr, Prowlarr
# -----------------------------------------------------------------------------
servarr_enable_login() {
  local base="$1" host_config payload
  host_config="$(api GET "${base}/config/host")" || return 1
  # Newer versions turn on forms login at first boot with a random password, so
  # always set the login here. The step's marker stops this overwriting it later.
  payload="$(jq --arg user "${MEDIA_ADMIN_USER}" --arg pass "${MEDIA_ADMIN_PASSWORD}" '
    .authenticationMethod = "forms" | .authenticationRequired = "enabled"
    | .username = $user | .password = $pass | .passwordConfirmation = $pass
  ' <<<"${host_config}")" || return 1
  api PUT "${base}/config/host" "${payload}" >/dev/null
}

# configure_arr NAME PORT API_KEY ROOT_FOLDER
configure_arr() {
  local name="$1" port="$2" key="$3" root="$4"
  local base="http://${MEDIA_HOST}:${port}/api/v3" API_HEADER="X-Api-Key: ${key}"
  local current payload
  wait_for_http "http://${MEDIA_HOST}:${port}/ping" "${name}" || return 1

  current="$(api GET "${base}/rootfolder")" || return 1
  if ! jq -e --arg path "${root}" 'any(.[]; (.path | rtrimstr("/")) == $path)' <<<"${current}" >/dev/null; then
    payload="$(jq -n --arg path "${root}" '{path: $path}')" || return 1
    api POST "${base}/rootfolder" "${payload}" >/dev/null || return 1
  fi

  servarr_enable_login "${base}"
}

# arr_add_qbittorrent PORT API_KEY CATEGORY_FIELD CATEGORY
arr_add_qbittorrent() {
  local port="$1" key="$2" category_field="$3" category="$4"
  local base="http://${MEDIA_HOST}:${port}/api/v3" API_HEADER="X-Api-Key: ${key}"
  local current schema fields payload
  current="$(api GET "${base}/downloadclient")" || return 1
  if ! jq -e 'any(.[]; .implementation == "QBittorrent")' <<<"${current}" >/dev/null; then
    schema="$(api GET "${base}/downloadclient/schema")" || return 1
    fields="$(jq -n --arg host qbittorrent --argjson port "${QBITTORRENT_PORT}" \
      --arg user "${MEDIA_ADMIN_USER}" --arg pass "${MEDIA_ADMIN_PASSWORD}" \
      --arg field "${category_field}" --arg category "${category}" \
      '{host: $host, port: $port, username: $user, password: $pass, ($field): $category}')" || return 1
    payload="$(jq --argjson v "${fields}" "${JQ_WITH_FIELDS}"'
      first(.[] | select(.implementation == "QBittorrent"))
      | .name = "qBittorrent" | .enable = true | with_fields($v)
    ' <<<"${schema}")" || return 1
    api POST "${base}/downloadclient" "${payload}" >/dev/null || return 1
  fi
}

# prowlarr_add_app IMPLEMENTATION INTERNAL_URL API_KEY
prowlarr_add_app() {
  local implementation="$1" app_url="$2" app_key="$3"
  local base="http://${MEDIA_HOST}:${PROWLARR_PORT}/api/v1" current schema fields payload
  current="$(api GET "${base}/applications")" || return 1
  jq -e --arg impl "${implementation}" 'any(.[]; .implementation == $impl)' <<<"${current}" >/dev/null && return 0
  schema="$(api GET "${base}/applications/schema")" || return 1
  fields="$(jq -n --arg app "${app_url}" --arg key "${app_key}" \
    '{prowlarrUrl: "http://prowlarr:9696", baseUrl: $app, apiKey: $key}')" || return 1
  payload="$(jq --arg impl "${implementation}" --argjson v "${fields}" "${JQ_WITH_FIELDS}"'
    first(.[] | select(.implementation == $impl))
    | .name = $impl | .syncLevel = "fullSync" | with_fields($v)
  ' <<<"${schema}")" || return 1
  api POST "${base}/applications" "${payload}" >/dev/null
}

configure_prowlarr() {
  local base="http://${MEDIA_HOST}:${PROWLARR_PORT}/api/v1" API_HEADER="X-Api-Key: ${PROWLARR_API_KEY}"
  wait_for_http "http://${MEDIA_HOST}:${PROWLARR_PORT}/ping" Prowlarr || return 1
  prowlarr_add_app Sonarr "http://sonarr:8989" "${SONARR_API_KEY}" || return 1
  prowlarr_add_app Radarr "http://radarr:7878" "${RADARR_API_KEY}" || return 1
  servarr_enable_login "${base}"
}

# Indexers that sit behind Cloudflare use this when given the flaresolverr tag.
configure_flaresolverr() {
  local base="http://${MEDIA_HOST}:${PROWLARR_PORT}/api/v1" API_HEADER="X-Api-Key: ${PROWLARR_API_KEY}"
  local current tag_id schema payload
  current="$(api GET "${base}/indexerProxy")" || return 1
  jq -e 'any(.[]; .implementation == "FlareSolverr")' <<<"${current}" >/dev/null && return 0

  current="$(api GET "${base}/tag")" || return 1
  tag_id="$(jq -r 'first(.[] | select(.label == "flaresolverr") | .id) // empty' <<<"${current}")" || return 1
  if [[ -z "${tag_id}" ]]; then
    current="$(api POST "${base}/tag" '{"label":"flaresolverr"}')" || return 1
    tag_id="$(jq -r '.id' <<<"${current}")" || return 1
  fi

  schema="$(api GET "${base}/indexerProxy/schema")" || return 1
  payload="$(jq --argjson tag "${tag_id}" "${JQ_WITH_FIELDS}"'
    first(.[] | select(.implementation == "FlareSolverr"))
    | .name = "FlareSolverr" | .tags = [$tag] | with_fields({host: "http://flaresolverr:8191/"})
  ' <<<"${schema}")" || return 1
  api POST "${base}/indexerProxy" "${payload}" >/dev/null
}

# -----------------------------------------------------------------------------
# Jellyfin
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Audiobookshelf
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Seerr
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# VPN: confirm on every run that qBittorrent is not using the home connection.
# -----------------------------------------------------------------------------
check_vpn() {
  local server_ip qbit_ip
  server_ip="$(curl -fsS --max-time 20 https://ipinfo.io/ip || true)"
  qbit_ip="$(docker exec qbittorrent curl -fsS --max-time 20 https://ipinfo.io/ip 2>/dev/null || true)"
  if [[ -z "${server_ip}" || -z "${qbit_ip}" ]]; then
    warn "Could not compare qBittorrent's public IP with the server's."
    note "Confirm qBittorrent is using the VPN: \`docker exec qbittorrent curl -s https://ipinfo.io/ip\` must differ from \`curl -s https://ipinfo.io/ip\` on the server. If gluetun is unhealthy, check \`docker logs gluetun\`."
  elif [[ "${server_ip}" == "${qbit_ip}" ]]; then
    warn "qBittorrent is using the server's own public IP. Stopping it."
    docker stop qbittorrent >/dev/null || warn "Could not stop qbittorrent. Stop it by hand."
    note "**qBittorrent was stopped because its traffic was not going through the VPN.** Check \`docker logs gluetun\` and your VPN settings in \`.env\`, then re-run setup.sh."
  else
    log "VPN: qBittorrent's public IP differs from the server's."
  fi
}

# -----------------------------------------------------------------------------
# Cloudflare: publish apps as <app>.MEDIA_DOMAIN on the existing tunnel.
#
# The tunnel's config is shared with Nextcloud and the API can only replace it
# whole, so this is strictly additive: existing rules and DNS records are never
# edited, a tunnel config it doesn't recognise is left alone, and the result is
# read back and rolled back if any existing rule changed. New rules name exact
# hostnames, so they can't catch traffic meant for another hostname.
# -----------------------------------------------------------------------------
# Pinned because the CLI is in beta and these commands were checked against this version.
CF_CLI_VERSION="1.0.0-beta.27"

# Runs in a container so the server doesn't need Node. Credentials come from the environment.
cf_cli() {
  docker run --rm -e CLOUDFLARE_API_TOKEN -e CLOUDFLARE_ACCOUNT_ID \
    -v pomelab_cf_cli_npm:/root/.npm node:22-slim \
    npx --yes "cf@${CF_CLI_VERSION}" "$@"
}

JQ_AS_LIST='if type == "array" then . else (.result // []) end'

# Print the hostname and service of every rule, for comparing configs.
tunnel_rules() { jq -c '[.ingress[] | {hostname, path, service}]' <<<"$1"; }

# Add rules to the front of the ingress list and confirm nothing else changed.
tunnel_add_rules() {
  local tunnel="$1" old_config="$2" new_rules="$3" new_config body current
  new_config="$(jq -c --argjson new "${new_rules}" '.ingress = $new + .ingress' <<<"${old_config}")" || return 1
  body="$(jq -c '{config: .}' <<<"${new_config}")" || return 1
  cf_cli tunnels config update "${tunnel}" --body "${body}" >/dev/null || return 1

  if current="$(cf_cli tunnels config get "${tunnel}" | jq -c '.result // . | .config')" \
    && [[ "$(tunnel_rules "${current}")" == "$(tunnel_rules "${new_config}")" ]]; then
    return 0
  fi
  warn "The tunnel config did not read back as expected. Restoring the previous config."
  body="$(jq -c '{config: .}' <<<"${old_config}")" || return 1
  cf_cli tunnels config update "${tunnel}" --body "${body}" >/dev/null \
    || warn "RESTORE FAILED. Check the tunnel's routes in the Cloudflare dashboard now."
  return 1
}

publish_media_hostnames() {
  local routes=(
    "jellyfin:${JELLYFIN_PORT}:open" "seerr:${SEERR_PORT}:open"
    "audiobookshelf:${AUDIOBOOKSHELF_PORT}:open" "readmeabook:${READMEABOOK_PORT}:open"
    "sonarr:${SONARR_PORT}:access" "radarr:${RADARR_PORT}:access"
    "prowlarr:${PROWLARR_PORT}:access" "qbittorrent:${QBITTORRENT_PORT}:access"
  )
  local route name port kind host pending=() manual=""
  for route in "${routes[@]}"; do
    IFS=: read -r name port kind <<<"${route}"
    [[ -f "${MEDIA_STATE_DIR}/hostname-${name}.${MEDIA_DOMAIN}" ]] && continue
    if [[ "${kind}" == "access" && -z "${MEDIA_ACCESS_EMAIL:-}" ]]; then
      note "\`${name}.${MEDIA_DOMAIN}\` was not published because its admin UI should sit behind Cloudflare Access. Set \`MEDIA_ACCESS_EMAIL\` in \`.env\` and re-run setup.sh."
      continue
    fi
    pending+=("${route}")
    manual+=$'\n'"    - \`${name}.${MEDIA_DOMAIN}\`: type \`HTTP\`, URL \`${MEDIA_HOST}:${port}\`"
  done
  [[ ${#pending[@]} -eq 0 ]] && return 0

  manual="Add these public hostnames to the tunnel in the Cloudflare Zero Trust dashboard:${manual}"
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    note "${manual}"$'\n'"    Or set \`CLOUDFLARE_API_TOKEN\` in \`.env\` and re-run setup.sh to do this automatically."
    return 0
  fi

  local token_json tunnel current old_config zone apps="" record new_rules='[]' add_dns=() done_hosts=()
  # A tunnel token is base64 JSON holding the account and tunnel IDs.
  local padded="${CLOUDFLARE_TUNNEL_TOKEN}==="
  padded="${padded:0:$(( (${#CLOUDFLARE_TUNNEL_TOKEN} + 3) / 4 * 4 ))}"
  if ! token_json="$(base64 -d <<<"${padded}" 2>/dev/null)" \
    || ! tunnel="$(jq -re '.t' <<<"${token_json}")" \
    || ! CLOUDFLARE_ACCOUNT_ID="$(jq -re '.a' <<<"${token_json}")"; then
    warn "Could not read the account and tunnel IDs from CLOUDFLARE_TUNNEL_TOKEN."
    note "${manual}"
    return 0
  fi
  export CLOUDFLARE_ACCOUNT_ID

  # Only continue with a remotely managed config that ends in its catch-all rule.
  if ! current="$(cf_cli tunnels config get "${tunnel}")" \
    || ! old_config="$(jq -ce '.result // . | .config
        | select((.ingress | type) == "array" and (.ingress | length) > 0 and .ingress[-1].hostname == null)' <<<"${current}")"; then
    warn "Left the tunnel unchanged: its current routes could not be read."
    note "${manual}"
    return 0
  fi
  if ! zone="$(cf_cli zones list --name "${MEDIA_DOMAIN}" | jq -re "${JQ_AS_LIST}"' | first(.[].id)')"; then
    warn "Left the tunnel unchanged: Cloudflare zone ${MEDIA_DOMAIN} was not found."
    note "${manual}"
    return 0
  fi

  for route in "${pending[@]}"; do
    IFS=: read -r name port kind <<<"${route}"
    host="${name}.${MEDIA_DOMAIN}"

    if ! record="$(cf_cli dns records list --zone "${zone}" --name "${host}" | jq -c "${JQ_AS_LIST}")"; then
      warn "Skipped ${host}: could not read its DNS records."
      note "Publish \`${host}\` by hand: type \`HTTP\`, URL \`${MEDIA_HOST}:${port}\`."
      continue
    fi
    if ! jq -e --arg target "${tunnel}.cfargotunnel.com" 'all(.[]; .content == $target)' <<<"${record}" >/dev/null; then
      warn "Skipped ${host}: it already has a DNS record pointing somewhere else."
      note "\`${host}\` already has a different DNS record, which setup.sh won't overwrite. Remove it and re-run setup.sh, or publish this app by hand."
      continue
    fi

    # Access goes on first, so an admin UI is never reachable without it.
    if [[ "${kind}" == "access" ]]; then
      if [[ -z "${apps}" ]] && ! apps="$(cf_cli zero-trust access applications list | jq -c "${JQ_AS_LIST}")"; then
        apps=""
        warn "Skipped ${host}: could not read Cloudflare Access applications."
        note "\`${host}\` was not published because Cloudflare Access could not be read. Check that the API token has the Access permission, then re-run setup.sh."
        continue
      fi
      if ! jq -e --arg host "${host}" 'any(.[]; .domain == $host)' <<<"${apps}" >/dev/null \
        && ! cf_cli zero-trust access applications create --body "$(jq -nc --arg host "${host}" --arg name "${name}" --arg email "${MEDIA_ACCESS_EMAIL}" '{
          name: $name, domain: $host, type: "self_hosted", session_duration: "24h",
          policies: [{name: "owner", decision: "allow", include: [{email: {email: $email}}]}]
        }')" >/dev/null; then
        warn "Skipped ${host}: could not create its Cloudflare Access application."
        note "\`${host}\` was not published because its Cloudflare Access application could not be created. Check that the API token has the Access permission, then re-run setup.sh."
        continue
      fi
    fi

    if ! jq -e --arg host "${host}" 'any(.ingress[]; .hostname == $host)' <<<"${old_config}" >/dev/null; then
      new_rules="$(jq -c --arg host "${host}" --arg service "http://${MEDIA_HOST}:${port}" \
        '. + [{hostname: $host, service: $service}]' <<<"${new_rules}")" || return 1
    fi
    [[ "$(jq 'length' <<<"${record}")" == 0 ]] && add_dns+=("${host}")
    done_hosts+=("${host}")
  done

  if [[ "$(jq 'length' <<<"${new_rules}")" != 0 ]]; then
    if ! tunnel_add_rules "${tunnel}" "${old_config}" "${new_rules}"; then
      note "${manual}"
      return 0
    fi
  fi
  for host in ${add_dns[@]+"${add_dns[@]}"}; do
    if ! cf_cli dns records create --zone "${zone}" --body "$(jq -nc --arg host "${host}" --arg target "${tunnel}.cfargotunnel.com" \
      '{type: "CNAME", name: $host, content: $target, proxied: true}')" >/dev/null; then
      warn "Could not create the DNS record for ${host}."
      note "Create a proxied CNAME for \`${host}\` pointing to the tunnel, or re-publish it in the dashboard."
      done_hosts=("${done_hosts[@]/#${host}/}")
    fi
  done
  for host in ${done_hosts[@]+"${done_hosts[@]}"}; do
    [[ -n "${host}" ]] && touch "${MEDIA_STATE_DIR}/hostname-${host}" && log "Published https://${host}"
  done
  return 0
}

# -----------------------------------------------------------------------------
# Things only a person can decide or do; re-checked on every run.
# -----------------------------------------------------------------------------
check_media_pending() {
  local count status

  count="$(API_HEADER="X-Api-Key: ${PROWLARR_API_KEY}" api GET \
    "http://${MEDIA_HOST}:${PROWLARR_PORT}/api/v1/indexer" | jq 'length' || true)"
  if [[ "${count}" == "0" ]]; then
    note "Add indexers in Prowlarr (http://localhost:${PROWLARR_PORT} > Indexers > Add Indexer). They sync to Sonarr and Radarr automatically. For an indexer behind Cloudflare, add the \`flaresolverr\` tag."
  fi

  status="$(api GET "http://${MEDIA_HOST}:${READMEABOOK_PORT}/api/setup/status" | jq -r '.setupComplete' || true)"
  if [[ "${status}" != "true" ]]; then
    note "After adding indexers, finish the ReadMeABook wizard at http://localhost:${READMEABOOK_PORT}. It needs choices only you can make, such as which indexers to use and your Audible region. Use these values:
    - Backend: Audiobookshelf, \`http://audiobookshelf:13378\`, library \`Audiobooks\`. Create the API token in Audiobookshelf under Settings > Users > ${MEDIA_ADMIN_USER}.
    - Prowlarr: \`http://prowlarr:9696\`, API key \`PROWLARR_API_KEY\` from \`.env\`.
    - qBittorrent: \`http://qbittorrent:${QBITTORRENT_PORT}\`, user \`${MEDIA_ADMIN_USER}\`, password \`MEDIA_ADMIN_PASSWORD\` from \`.env\`.
    - Download directory: \`/data/torrents/complete\`. Media directory: \`/data/media/audiobooks\`."
  fi

  if [[ -n "${VPN_SERVICE_PROVIDER:-}" && "${DECLUTTARR_TEST_RUN}" == "true" ]]; then
    note "Decluttarr is in test mode, so it only logs what it would remove. Review \`docker logs decluttarr\`, then set \`DECLUTTARR_TEST_RUN=false\` in \`.env\` and re-run setup.sh."
  fi
}

configure_media() {
  MEDIA_HOST="${MEDIA_BIND_IP}"
  [[ "${MEDIA_HOST}" == "0.0.0.0" ]] && MEDIA_HOST="127.0.0.1"
  MEDIA_STATE_DIR="${MEDIA_CONFIG_DIR}/.setup-state"
  MEDIA_TMP="$(mktemp -d)"
  mkdir -p "${MEDIA_STATE_DIR}"

  local see_login="Sign in with \`MEDIA_ADMIN_USER\` and \`MEDIA_ADMIN_PASSWORD\` from \`.env\` where the app already has them."

  run_step sonarr "Sonarr" \
    "Configure Sonarr at http://localhost:${SONARR_PORT}: root folder \`/data/media/tv\`. ${see_login}" \
    configure_arr Sonarr "${SONARR_PORT}" "${SONARR_API_KEY}" /data/media/tv
  run_step radarr "Radarr" \
    "Configure Radarr at http://localhost:${RADARR_PORT}: root folder \`/data/media/movies\`. ${see_login}" \
    configure_arr Radarr "${RADARR_PORT}" "${RADARR_API_KEY}" /data/media/movies

  if [[ -n "${VPN_SERVICE_PROVIDER:-}" ]]; then
    run_step qbittorrent "qBittorrent" \
      "Configure qBittorrent at http://localhost:${QBITTORRENT_PORT}: its temporary password is in \`docker logs qbittorrent\`. Set the save path to \`/data/torrents/complete\`, the incomplete path to \`/data/torrents/incomplete\`, and the login from \`.env\`. If it isn't responding, check \`docker logs gluetun\`." \
      configure_qbittorrent
    run_step sonarr-client "qBittorrent in Sonarr" \
      "In Sonarr, add a qBittorrent download client: host \`qbittorrent\`, port \`${QBITTORRENT_PORT}\`, category \`tv\`." \
      arr_add_qbittorrent "${SONARR_PORT}" "${SONARR_API_KEY}" tvCategory tv
    run_step radarr-client "qBittorrent in Radarr" \
      "In Radarr, add a qBittorrent download client: host \`qbittorrent\`, port \`${QBITTORRENT_PORT}\`, category \`movies\`." \
      arr_add_qbittorrent "${RADARR_PORT}" "${RADARR_API_KEY}" movieCategory movies
    check_vpn
  else
    note "Set up the VPN: fill in \`VPN_SERVICE_PROVIDER\` and its credentials in \`.env\`, then re-run setup.sh. qBittorrent and Decluttarr stay stopped until then, so nothing can download over your home connection."
  fi

  run_step prowlarr "Prowlarr" \
    "Configure Prowlarr at http://localhost:${PROWLARR_PORT}: under Settings > Apps add Sonarr (\`http://sonarr:8989\`) and Radarr (\`http://radarr:7878\`) with the API keys from \`.env\`, using \`http://prowlarr:9696\` as the Prowlarr server. ${see_login}" \
    configure_prowlarr
  run_step flaresolverr "FlareSolverr in Prowlarr" \
    "In Prowlarr under Settings > Indexers, add a FlareSolverr proxy with host \`http://flaresolverr:8191/\` and the tag \`flaresolverr\`." \
    configure_flaresolverr
  run_step jellyfin "Jellyfin" \
    "Finish the Jellyfin wizard at http://localhost:${JELLYFIN_PORT}, then add the libraries \`/data/media/movies\` and \`/data/media/tv\`." \
    configure_jellyfin
  run_step audiobookshelf "Audiobookshelf" \
    "Finish setup in Audiobookshelf at http://localhost:${AUDIOBOOKSHELF_PORT}, then add the libraries \`/data/media/audiobooks\` and \`/data/media/books\`." \
    configure_audiobookshelf
  run_step seerr "Seerr" \
    "Finish the Seerr wizard at http://localhost:${SEERR_PORT}: Jellyfin at \`http://jellyfin:8096\`, Sonarr at \`sonarr:8989\` with root \`/data/media/tv\`, Radarr at \`radarr:7878\` with root \`/data/media/movies\`." \
    configure_seerr

  if [[ -n "${MEDIA_DOMAIN:-}" ]]; then
    publish_media_hostnames || warn "Publishing hostnames stopped early. Re-run setup.sh to retry."
  fi

  check_media_pending
  rm -rf "${MEDIA_TMP}"
}
