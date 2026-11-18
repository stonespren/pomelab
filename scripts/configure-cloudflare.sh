# shellcheck shell=bash
# =============================================================================
# configure-cloudflare.sh — Publish the server through a Cloudflare Tunnel.
#
# Sourced by setup.sh, which provides log, warn, fail, note, set_env_var,
# MEDIA_HOST, SSH_ADDRESS, the app ports and the values from .env. Nothing runs until
# setup.sh calls configure_cloudflare.
#
# Every run brings Cloudflare back in line with ROUTES below:
#   - the tunnel TUNNEL_NAME exists, and its token is in .env
#   - each route is in the tunnel's config, ahead of a catch-all 404. Routes for
#     other hostnames, such as ones added in the dashboard, are kept.
#   - each admin route has a Cloudflare Access app, created before its hostname
#     is published and allowing only ACCESS_EMAIL. An existing app is left as it
#     is, so changes made to it in the dashboard are kept.
#   - each hostname has a proxied CNAME to the tunnel. An existing record that
#     points elsewhere is never changed: that hostname is skipped instead.
# =============================================================================

# subdomain:service:policy. "access" puts the app behind Cloudflare Access.
# Nextcloud stays outside Access because its desktop and mobile clients can't
# sign in through it.
cloudflare_routes() {
  ROUTES=(
    "cloud:http://localhost:11000:open"
    "jellyfin:http://${MEDIA_HOST}:${JELLYFIN_PORT}:open"
    "seerr:http://${MEDIA_HOST}:${SEERR_PORT}:open"
    "audiobookshelf:http://${MEDIA_HOST}:${AUDIOBOOKSHELF_PORT}:open"
    "readmeabook:http://${MEDIA_HOST}:${READMEABOOK_PORT}:open"
    "sonarr:http://${MEDIA_HOST}:${SONARR_PORT}:access"
    "radarr:http://${MEDIA_HOST}:${RADARR_PORT}:access"
    "prowlarr:http://${MEDIA_HOST}:${PROWLARR_PORT}:access"
    "qbittorrent:http://${MEDIA_HOST}:${QBITTORRENT_PORT}:access"
    # Clients connect with `cloudflared access ssh` as their ProxyCommand.
    "ssh:ssh://${SSH_ADDRESS}:access"
  )
}

# Pinned because the CLI is in beta and these commands were checked against this version.
CF_CLI_VERSION="1.0.0-beta.27"

# Runs in a container so the server doesn't need Node. Credentials pass through
# the environment, which keeps them out of `ps`.
cf_cli() {
  docker run --rm -e CLOUDFLARE_API_TOKEN -e CLOUDFLARE_ACCOUNT_ID \
    -v pomelab_cf_cli_npm:/root/.npm node:22-slim \
    npx --yes "cf@${CF_CLI_VERSION}" "$@"
}

# The CLI may print the API's whole response or just its "result".
JQ_RESULT='(.result? // .)'
JQ_LIST="${JQ_RESULT}"' | if type == "array" then . else [] end'

# Hostname and service of every rule, for comparing configs.
tunnel_rules() { jq -c '[(.ingress // [])[] | {hostname, path, service}]' <<<"$1"; }

# Print the tunnel's ID, creating the tunnel if it doesn't exist.
cloudflare_tunnel() {
  local tunnels id
  tunnels="$(cf_cli tunnels list --name "${TUNNEL_NAME}" --is-deleted false)" || return 1
  id="$(jq -r --arg name "${TUNNEL_NAME}" "${JQ_LIST}"' | first(.[] | select(.name == $name) | .id) // empty' <<<"${tunnels}")" || return 1
  if [[ -z "${id}" ]]; then
    log "Creating tunnel ${TUNNEL_NAME}..." >&2
    id="$(cf_cli tunnels create --body "$(jq -nc --arg name "${TUNNEL_NAME}" '{name: $name, config_src: "cloudflare"}')" \
      | jq -re "${JQ_RESULT}"' | .id')" || return 1
  fi
  printf '%s' "${id}"
}

# Make sure an admin hostname has an Access app. Looked up by exact domain, so
# the answer doesn't depend on how many other apps the account has.
cloudflare_access_app() {
  local host="$1" name="$2" apps body
  apps="$(cf_cli zero-trust access applications list --domain "${host}" --exact | jq -c "${JQ_LIST}")" || return 1
  jq -e --arg host "${host}" 'any(.[]; .domain == $host)' <<<"${apps}" >/dev/null && return 0
  body="$(jq -nc --arg host "${host}" --arg name "${name}" --arg email "${ACCESS_EMAIL}" '{
    name: $name, domain: $host, type: "self_hosted", session_duration: "24h",
    policies: [{name: "owner", decision: "allow", include: [{email: {email: $email}}]}]
  }')" || return 1
  cf_cli zero-trust access applications create --body "${body}" >/dev/null
}

# Cloudflare couldn't be read or changed. The first run can't continue without a
# tunnel token; later runs keep the tunnel as it is and carry on.
cloudflare_unavailable() {
  [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]] || fail "$1"
  warn "$1 Left the tunnel, routes and DNS as they are."
  note "$1 Re-run setup.sh once that is fixed."
}

# Put the managed rules first, keep other hostnames' rules, and end in a 404.
cloudflare_ingress() {
  local tunnel="$1" managed="$2" response old new
  if ! response="$(cf_cli tunnels config get "${tunnel}")" \
    || ! old="$(jq -ce "${JQ_RESULT}"' | (.config // {})' <<<"${response}")"; then
    warn "Could not read the tunnel's current routes, so they were left unchanged."
    return 1
  fi
  new="$(jq -c --argjson managed "${managed}" '
    ([$managed[].hostname]) as $ours
    | .ingress = $managed
        + [(.ingress // [])[] | select(.hostname != null and (.hostname | IN($ours[]) | not))]
        + [{service: "http_status:404"}]
  ' <<<"${old}")" || return 1

  [[ "$(tunnel_rules "${old}")" == "$(tunnel_rules "${new}")" ]] && return 0
  cf_cli tunnels config update "${tunnel}" --body "$(jq -c '{config: .}' <<<"${new}")" >/dev/null || return 1
  log "Tunnel routes updated."
}

# Make sure a hostname has a proxied CNAME to the tunnel.
cloudflare_dns() {
  local zone="$1" host="$2" target="$3" records
  records="$(cf_cli dns records list --zone "${zone}" --name "${host}" | jq -c "${JQ_LIST}")" || return 1
  if [[ "$(jq 'length' <<<"${records}")" == 0 ]]; then
    cf_cli dns records create --zone "${zone}" --body "$(jq -nc --arg host "${host}" --arg target "${target}" \
      '{type: "CNAME", name: $host, content: $target, proxied: true}')" >/dev/null || return 1
    log "Published https://${host}"
  elif ! jq -e --arg target "${target}" 'all(.[]; .content == $target)' <<<"${records}" >/dev/null; then
    warn "${host} already has a DNS record pointing somewhere else. Left it unchanged."
    note "\`${host}\` has a DNS record that doesn't point to the tunnel, which setup.sh won't overwrite. Delete it in Cloudflare and re-run setup.sh."
  fi
}

configure_cloudflare() {
  local zones zone tunnel token route name service policy host managed='[]' published=()
  export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
  cloudflare_routes

  if ! zones="$(cf_cli zones list --name "${DOMAIN}")"; then
    cloudflare_unavailable "Could not reach the Cloudflare API. Check CLOUDFLARE_API_TOKEN."
    return 0
  fi
  zone="$(jq -r "${JQ_LIST}"' | first(.[].id) // empty' <<<"${zones}")"
  CLOUDFLARE_ACCOUNT_ID="$(jq -r "${JQ_LIST}"' | first(.[].account.id) // empty' <<<"${zones}")"
  if [[ -z "${zone}" || -z "${CLOUDFLARE_ACCOUNT_ID}" ]]; then
    cloudflare_unavailable "Cloudflare zone ${DOMAIN} was not found. DOMAIN must match a zone the API token can read."
    return 0
  fi
  if ! tunnel="$(cloudflare_tunnel)"; then
    cloudflare_unavailable "Could not find or create the tunnel ${TUNNEL_NAME}."
    return 0
  fi
  if ! token="$(cf_cli tunnels token get "${tunnel}" | jq -re "${JQ_RESULT}")"; then
    cloudflare_unavailable "Could not get the token for tunnel ${TUNNEL_NAME}."
    return 0
  fi
  [[ "${token}" == "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]] || set_env_var CLOUDFLARE_TUNNEL_TOKEN "${token}"
  log "Tunnel ${TUNNEL_NAME}: ${tunnel}"

  for route in "${ROUTES[@]}"; do
    name="${route%%:*}"; policy="${route##*:}"
    service="${route#*:}"; service="${service%:*}"
    host="${name}.${DOMAIN}"
    # Access goes on first, so an admin app is never published without it.
    if [[ "${policy}" == access ]] && ! cloudflare_access_app "${host}" "${name}"; then
      warn "Skipped ${host}: could not set up its Cloudflare Access app."
      note "\`${host}\` was not published because its Cloudflare Access app could not be created. Check the API token's Access permission and re-run setup.sh."
      continue
    fi
    managed="$(jq -c --arg host "${host}" --arg service "${service}" \
      '. + [{hostname: $host, service: $service}]' <<<"${managed}")"
    published+=("${host}")
  done

  if ! cloudflare_ingress "${tunnel}" "${managed}"; then
    note "The tunnel's routes could not be updated. Check \`CLOUDFLARE_API_TOKEN\`'s Tunnel permission and re-run setup.sh."
    return 0
  fi
  for host in "${published[@]}"; do
    cloudflare_dns "${zone}" "${host}" "${tunnel}.cfargotunnel.com" || {
      warn "Could not check or create the DNS record for ${host}."
      note "Create a proxied CNAME for \`${host}\` pointing to \`${tunnel}.cfargotunnel.com\`, or re-run setup.sh."
    }
  done
}
