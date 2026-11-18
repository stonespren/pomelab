# shellcheck shell=bash
# =============================================================================
# media/decluttarr.sh — Decluttarr is configured entirely from .env through
# compose.yaml, so this only reminds you to leave test mode.
#
# Sourced by configure-media.sh. Re-checked on every run.
# =============================================================================

decluttarr_pending() {
  if [[ -n "${VPN_SERVICE_PROVIDER:-}" && "${DECLUTTARR_TEST_RUN}" == "true" ]]; then
    note "Decluttarr is in test mode, so it only logs what it would remove. Review \`docker logs decluttarr\`, then set \`DECLUTTARR_TEST_RUN=false\` in \`.env\` and re-run setup.sh."
  fi
}
