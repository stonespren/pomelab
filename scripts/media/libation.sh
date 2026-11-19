# shellcheck shell=bash
# =============================================================================
# media/libation.sh — Libation: signing in to Audible needs a browser, so this
# only checks whether it is done. Syncing is up to you, with scripts/audible-sync.sh.
#
# Sourced by configure-media.sh. Re-checked on every run.
# =============================================================================

libation_pending() {
  # Optional: nothing to do until an Audible account is set in .env.
  [[ -n "${AUDIBLE_EMAIL:-}" ]] || return 0
  grep -qsF "\"${AUDIBLE_EMAIL}\"" "${MEDIA_CONFIG_DIR}/libation/AccountsSettings.json" && return 0
  note "Run \`sudo ./scripts/audible-sync.sh\` to sign in to Audible as ${AUDIBLE_EMAIL} and download your library into Audiobookshelf. The first run asks you to sign in through a browser link; after that, run it whenever you want to sync."
}
