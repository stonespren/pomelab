#!/usr/bin/env bash
# =============================================================================
# audible-sync.sh — Download new Audible purchases into the Audiobooks library
# with Libation, then exit. Audiobookshelf picks them up from there.
#
# Set AUDIBLE_EMAIL and AUDIBLE_LOCALE in .env, run setup.sh once, then:
#   sudo ./scripts/audible-sync.sh
#
# The first run signs in to Audible. Amazon needs a browser for that (captchas,
# two-step codes), so the script prints a link to open and asks for the address
# you end up on. Later runs reuse the saved sign-in and only sync. To sign in
# again, delete AccountsSettings.json (see "Audible" in README.md).
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_DIR}/.env"

fail() { echo "audible-sync: $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fail "Please run as root: sudo ./scripts/audible-sync.sh"
[[ -f "${ENV_FILE}" ]] || fail "No .env yet. Run setup.sh first."
set -a; source "${ENV_FILE}"; set +a

[[ -n "${MEDIA_CONFIG_DIR:-}" ]] || fail "MEDIA_CONFIG_DIR isn't set in .env. Run setup.sh first."
[[ -n "${AUDIBLE_EMAIL:-}" ]] || fail "Set AUDIBLE_EMAIL (and AUDIBLE_LOCALE) in ${ENV_FILE}."
AUDIBLE_LOCALE="${AUDIBLE_LOCALE:-us}"

COMPOSE=(docker compose --project-directory "${REPO_DIR}")
ACCOUNTS="${MEDIA_CONFIG_DIR}/libation/AccountsSettings.json"

# Libation keeps its accounts in this file, keyed by the Audible email.
if ! grep -qsF "\"${AUDIBLE_EMAIL}\"" "${ACCOUNTS}"; then
  [[ -t 0 ]] || fail "Signing in to Audible needs an interactive terminal. Run this script by hand."
  echo "Signing in to Audible as ${AUDIBLE_EMAIL} (${AUDIBLE_LOCALE}). Open the link below,"
  echo "sign in, then paste the address your browser ends up on."
  "${COMPOSE[@]}" run --rm libation LibationCli login-external \
    --libationFiles /config --locale "${AUDIBLE_LOCALE}" --account "${AUDIBLE_EMAIL}"
fi

echo "Syncing your Audible library..."
"${COMPOSE[@]}" run --rm libation \
  || fail "The sync failed. If the log above says the Audible sign-in expired or was rejected, delete ${ACCOUNTS} and run this script again to sign in."
echo "Done. New books are in ${MEDIA_DATA_DIR:-MEDIA_DATA_DIR}/media/audiobooks."
