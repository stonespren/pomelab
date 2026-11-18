# shellcheck shell=bash
# =============================================================================
# media/flaresolverr.sh — FlareSolverr: add it to Prowlarr as an indexer proxy.
# Indexers that sit behind Cloudflare use it when given the flaresolverr tag.
#
# Sourced by configure-media.sh.
# =============================================================================

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

setup_flaresolverr() {
  run_step flaresolverr "FlareSolverr in Prowlarr" \
    "In Prowlarr under Settings > Indexers, add a FlareSolverr proxy with host \`http://flaresolverr:8191/\` and the tag \`flaresolverr\`." \
    configure_flaresolverr
}
