# shellcheck shell=bash
# =============================================================================
# media/prowlarr.sh — Prowlarr: sync indexers to Sonarr and Radarr, set the
# login, and remind about adding indexers.
#
# Sourced by configure-media.sh.
# =============================================================================

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

setup_prowlarr() {
  run_step prowlarr "Prowlarr" \
    "Configure Prowlarr at https://prowlarr.${DOMAIN}: under Settings > Apps add Sonarr (\`http://sonarr:8989\`) and Radarr (\`http://radarr:7878\`) with the API keys from \`.env\`, using \`http://prowlarr:9696\` as the Prowlarr server. ${MEDIA_SEE_LOGIN}" \
    configure_prowlarr
}

# Re-checked on every run.
prowlarr_pending() {
  local count
  count="$(API_HEADER="X-Api-Key: ${PROWLARR_API_KEY}" api GET \
    "http://${MEDIA_HOST}:${PROWLARR_PORT}/api/v1/indexer" | jq 'length' || true)"
  if [[ "${count}" == "0" ]]; then
    note "Add indexers in Prowlarr (https://prowlarr.${DOMAIN} > Indexers > Add Indexer). They sync to Sonarr and Radarr automatically. For an indexer behind Cloudflare, add the \`flaresolverr\` tag."
  fi
}
