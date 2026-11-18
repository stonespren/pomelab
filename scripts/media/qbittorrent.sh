# shellcheck shell=bash
# =============================================================================
# media/qbittorrent.sh — qBittorrent: login and paths, its download client in
# Sonarr and Radarr, and a check on every run that it uses the VPN.
#
# Sourced by configure-media.sh. Runs after Sonarr and Radarr are set up.
# =============================================================================

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

# Confirm on every run that qBittorrent is not using the home connection.
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

setup_qbittorrent() {
  if [[ -z "${VPN_SERVICE_PROVIDER:-}" ]]; then
    note "Set up the VPN: fill in \`VPN_SERVICE_PROVIDER\` and its credentials in \`.env\`, then re-run setup.sh. qBittorrent and Decluttarr stay stopped until then, so nothing can download over your home connection."
    return 0
  fi

  run_step qbittorrent "qBittorrent" \
    "Configure qBittorrent at https://qbittorrent.${DOMAIN}: its temporary password is in \`docker logs qbittorrent\`. Set the save path to \`/data/torrents/complete\`, the incomplete path to \`/data/torrents/incomplete\`, and the login from \`.env\`. If it isn't responding, check \`docker logs gluetun\`." \
    configure_qbittorrent
  run_step sonarr-client "qBittorrent in Sonarr" \
    "In Sonarr, add a qBittorrent download client: host \`qbittorrent\`, port \`${QBITTORRENT_PORT}\`, category \`tv\`." \
    arr_add_qbittorrent "${SONARR_PORT}" "${SONARR_API_KEY}" tvCategory tv
  run_step radarr-client "qBittorrent in Radarr" \
    "In Radarr, add a qBittorrent download client: host \`qbittorrent\`, port \`${QBITTORRENT_PORT}\`, category \`movies\`." \
    arr_add_qbittorrent "${RADARR_PORT}" "${RADARR_API_KEY}" movieCategory movies
  check_vpn
}
