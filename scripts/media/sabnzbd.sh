# shellcheck shell=bash
# =============================================================================
# media/sabnzbd.sh — SABnzbd: login, download paths and categories, its
# download client in Sonarr and Radarr, and a reminder to add a Usenet server.
#
# Sourced by configure-media.sh. Runs after Sonarr and Radarr are set up. Like
# qBittorrent, it only runs once a VPN is set up.
# =============================================================================

# SABnzbd makes its own API key on first start and keeps it in sabnzbd.ini.
sabnzbd_api_key() {
  local ini="${MEDIA_CONFIG_DIR}/sabnzbd/sabnzbd.ini" key
  key="$(sed -n 's/^api_key = //p' "${ini}" 2>/dev/null | head -n 1)"
  [[ -n "${key}" ]] || { warn "SABnzbd's API key is not in ${ini}." >&2; return 1; }
  printf '%s' "${key}"
}

# sabnzbd_api NAME=VALUE... — print the JSON response. Every parameter, the API
# key included, goes in the POST body through a curl config file descriptor, so
# none of them show up in `ps`.
sabnzbd_api() {
  local key response status pair
  key="$(sabnzbd_api_key)" || return 1
  response="$(curl -sS --max-time 60 --config <(
    for pair in "apikey=${key}" output=json "$@"; do
      pair="${pair//\\/\\\\}"
      printf 'data-urlencode = "%s"\n' "${pair//\"/\\\"}"
    done
  ) -w '\n%{http_code}' "http://${MEDIA_HOST}:${SABNZBD_PORT}/api")" || return 1

  status="${response##*$'\n'}"
  response="${response%$'\n'*}"
  if [[ ! "${status}" =~ ^2 ]] || jq -e '.status? == false' <<<"${response}" >/dev/null 2>&1; then
    warn "SABnzbd's API returned HTTP ${status}: ${response:0:300}" >&2
    return 1
  fi
  printf '%s' "${response}"
}

sabnzbd_set() { sabnzbd_api mode=set_config section=misc "keyword=$1" "value=$2" >/dev/null; }

configure_sabnzbd() {
  local current whitelist
  wait_for_http "http://${MEDIA_HOST}:${SABNZBD_PORT}/api?mode=version" SABnzbd || return 1

  sabnzbd_set download_dir /data/usenet/incomplete || return 1
  sabnzbd_set complete_dir /data/usenet/complete || return 1
  # Sonarr and Radarr check these categories exist. Their folders are relative
  # to complete_dir.
  sabnzbd_api mode=set_config section=categories keyword=tv dir=tv >/dev/null || return 1
  sabnzbd_api mode=set_config section=categories keyword=movies dir=movies >/dev/null || return 1

  # SABnzbd refuses hostnames it doesn't know, to stop DNS rebinding. Keep what
  # is there and add the Docker name and the public hostname.
  current="$(sabnzbd_api mode=get_config section=misc)" || return 1
  whitelist="$(jq -r --arg public "sabnzbd.${DOMAIN}" '
    (.config.misc.host_whitelist // []) | if type == "string" then split(",") else . end
    | map(gsub("^\\s+|\\s+$"; "")) + ["sabnzbd", $public]
    | map(select(. != "")) | unique | join(", ")
  ' <<<"${current}")" || return 1
  sabnzbd_set host_whitelist "${whitelist}" || return 1

  sabnzbd_set username "${MEDIA_ADMIN_USER}" || return 1
  sabnzbd_set password "${MEDIA_ADMIN_PASSWORD}"
}

# SABnzbd only serves private addresses by default, and requests through the
# tunnel can look external to it ("External internet access denied"). 4 is the
# full web interface, which still shows everyone the login screen. Only done
# once a login is set, so this never opens SABnzbd without one.
sabnzbd_allow_tunnel() {
  local current
  current="$(sabnzbd_api mode=get_config section=misc)" || return 1
  if ! jq -e '(.config.misc.username // "") != "" and (.config.misc.password // "") != ""' \
      <<<"${current}" >/dev/null; then
    warn "SABnzbd has no login yet, so external access was left off." >&2
    return 1
  fi
  sabnzbd_set inet_exposure 4
}

# arr_add_sabnzbd PORT API_KEY CATEGORY_FIELD CATEGORY
arr_add_sabnzbd() {
  local port="$1" key="$2" category_field="$3" category="$4"
  local base="http://${MEDIA_HOST}:${port}/api/v3" API_HEADER="X-Api-Key: ${key}"
  local current schema sab_key fields payload
  current="$(api GET "${base}/downloadclient")" || return 1
  jq -e 'any(.[]; .implementation == "Sabnzbd")' <<<"${current}" >/dev/null && return 0
  sab_key="$(sabnzbd_api_key)" || return 1
  schema="$(api GET "${base}/downloadclient/schema")" || return 1
  # Inside the Docker network SABnzbd is reached through gluetun, on port 8080.
  fields="$(jq -n --arg key "${sab_key}" --arg field "${category_field}" --arg category "${category}" \
    '{host: "sabnzbd", port: 8080, apiKey: $key, ($field): $category}')" || return 1
  payload="$(jq --argjson v "${fields}" "${JQ_WITH_FIELDS}"'
    first(.[] | select(.implementation == "Sabnzbd"))
    | .name = "SABnzbd" | .enable = true | with_fields($v)
  ' <<<"${schema}")" || return 1
  api POST "${base}/downloadclient" "${payload}" >/dev/null
}

setup_sabnzbd() {
  # setup_qbittorrent already asks for a VPN.
  [[ -n "${VPN_SERVICE_PROVIDER:-}" ]] || return 0
  run_step sabnzbd "SABnzbd" \
    "Configure SABnzbd at https://sabnzbd.${DOMAIN}: under Config > Folders set the temporary folder to \`/data/usenet/incomplete\` and the completed folder to \`/data/usenet/complete\`; under Config > Categories make sure \`tv\` and \`movies\` exist; under Config > General add \`sabnzbd\` and \`sabnzbd.${DOMAIN}\` to the host whitelist and set the login from \`.env\`. If it isn't responding, check \`docker logs gluetun\`." \
    configure_sabnzbd
  # Its own step, so servers that already ran the one above get it too.
  run_step sabnzbd-access "SABnzbd access through the tunnel" \
    "In SABnzbd, set a username and password under Config > General > Security, then set External internet access to \`Full Web Interface\` there. Until then, use it over SSH: \`ssh -L 8085:127.0.0.1:8085 you@server\` and browse to http://localhost:8085." \
    sabnzbd_allow_tunnel
  run_step sonarr-sabnzbd "SABnzbd in Sonarr" \
    "In Sonarr, add a SABnzbd download client: host \`sabnzbd\`, port \`8080\`, the API key from SABnzbd's Config > General, category \`tv\`." \
    arr_add_sabnzbd "${SONARR_PORT}" "${SONARR_API_KEY}" tvCategory tv
  run_step radarr-sabnzbd "SABnzbd in Radarr" \
    "In Radarr, add a SABnzbd download client: host \`sabnzbd\`, port \`8080\`, the API key from SABnzbd's Config > General, category \`movies\`." \
    arr_add_sabnzbd "${RADARR_PORT}" "${RADARR_API_KEY}" movieCategory movies
}

# Re-checked on every run.
sabnzbd_pending() {
  local count
  [[ -n "${VPN_SERVICE_PROVIDER:-}" ]] || return 0
  count="$(sabnzbd_api mode=get_config section=servers 2>/dev/null | jq '.config.servers | length' || true)"
  if [[ "${count}" == "0" ]]; then
    note "To download from Usenet, add your provider in SABnzbd (https://sabnzbd.${DOMAIN} > Config > Servers), using its SSL port, and add Usenet indexers in Prowlarr. Skip this if you only use torrents."
  fi
}
