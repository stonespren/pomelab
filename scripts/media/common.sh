# shellcheck shell=bash
# =============================================================================
# media/common.sh — Helpers shared by the per-app media scripts.
#
# Sourced by configure-media.sh. Steps run in `if` conditions, where `set -e`
# has no effect, so every call that can fail needs its own `|| return 1`.
# =============================================================================

# Appended to manual instructions for apps that get the login from .env.
MEDIA_SEE_LOGIN="Sign in with \`MEDIA_ADMIN_USER\` and \`MEDIA_ADMIN_PASSWORD\` from \`.env\` where the app already has them."

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

# -----------------------------------------------------------------------------
# Servarr apps (Sonarr, Radarr, Prowlarr)
# -----------------------------------------------------------------------------

# jq: set the named entries of a Servarr schema's "fields" array.
JQ_WITH_FIELDS='def with_fields($v): .fields |= map(if $v[.name] != null then .value = $v[.name] else . end);'

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

# configure_arr NAME PORT API_KEY ROOT_FOLDER — used by Sonarr and Radarr
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
