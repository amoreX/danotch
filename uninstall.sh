#!/bin/bash
# Remove Perch's installed programs; preserve user data unless explicitly purged.

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/perch-common.sh
source "$SCRIPT_ROOT/scripts/lib/perch-common.sh"

PURGE=0
if [[ "${1:-}" == "--purge" && $# -eq 1 ]]; then
  PURGE=1
elif [[ $# -ne 0 ]]; then
  perch_die "Usage: ./uninstall.sh [--purge]"
fi

if ((PURGE == 1)); then
  perch_note "PURGE permanently deletes Perch's SQLite data, settings, logs, backups, and known Keychain entries."
  if [[ "${PERCH_PURGE_CONFIRM:-}" != "DELETE PERCH" ]]; then
    [[ -t 0 ]] ||
      perch_die "Non-interactive purge requires PERCH_PURGE_CONFIRM='DELETE PERCH'."
    printf 'Type DELETE PERCH to continue: '
    IFS= read -r confirmation
    [[ "$confirmation" == "DELETE PERCH" ]] || perch_die "Purge cancelled."
  fi
fi

perch_note "Stopping Perch..."
osascript -e 'tell application id "engineering.super.Perch" to quit' >/dev/null 2>&1 || true
perch_launchctl_remove

rm -f "$PERCH_LAUNCH_AGENT"
rm -rf "$PERCH_APP_PATH"
rm -f "$PERCH_CLI_PATH"
rm -rf "$PERCH_STATE_DIR/install"

if ((PURGE == 1)); then
  for account in \
    installation.secret \
    provider.anthropic \
    provider.openai \
    provider.openrouter \
    provider.deepseek \
    provider.custom_openai \
    composio; do
    security delete-generic-password \
      -s engineering.super.Perch.daemon \
      -a "$account" >/dev/null 2>&1 || true
  done
  # The Secure Enclave reference is the sole generic-password item under this
  # service. Its account is the installation UUID, which is intentionally not
  # copied out of the data directory during purge.
  security delete-generic-password \
    -s engineering.super.Perch.device-identity.p256 >/dev/null 2>&1 || true
  rm -rf "$PERCH_STATE_DIR" "$PERCH_LOG_DIR"
  perch_note "Perch and its local data were purged."
else
  perch_note "Perch was removed. User data and Keychain entries remain in place."
  perch_note "Run the uninstaller with --purge for confirmed permanent deletion."
fi
