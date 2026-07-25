#!/bin/bash
# Fetch and install an immutable, signed Perch source release.

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/perch-common.sh
source "$SCRIPT_ROOT/scripts/lib/perch-common.sh"

REQUESTED_TAG=""
CLEAN_REINSTALL=0
while (($#)); do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || perch_die "--tag requires vX.Y.Z."
      REQUESTED_TAG="$2"
      shift 2
      ;;
    --clean-reinstall)
      CLEAN_REINSTALL=1
      shift
      ;;
    *)
      perch_die "Usage: perch update [--tag vX.Y.Z] [--clean-reinstall]"
      ;;
  esac
done

perch_require_host
command -v gpg >/dev/null 2>&1 ||
  perch_die "GnuPG is required to verify release tags. Install it from https://gnupg.org/download/ before updating."

TRUSTED_KEYS="$SCRIPT_ROOT/release/maintainer-gpg-fingerprints.txt"
[[ -f "$TRUSTED_KEYS" ]] || perch_die "Installed maintainer key allowlist is missing; repair from a reviewed clone."
grep -Eq '^[A-Fa-f0-9]{40,64}$' "$TRUSTED_KEYS" ||
  perch_die "No trusted maintainer release key is configured; updates remain disabled."

if [[ -d "$SCRIPT_ROOT/.git" ]] && [[ -n "$(git -C "$SCRIPT_ROOT" status --porcelain)" ]] &&
  ((CLEAN_REINSTALL == 0)); then
  perch_die "The source tree has uncommitted changes. Commit/stash them, or pass --clean-reinstall to update from a fresh verified clone."
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/perch-update.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

perch_note "Fetching stable release tags from $PERCH_REPOSITORY_URL..."
git clone --filter=blob:none --no-checkout "$PERCH_REPOSITORY_URL" "$WORK_DIR/repository"
git -C "$WORK_DIR/repository" fetch --force --tags origin

if [[ -n "$REQUESTED_TAG" ]]; then
  [[ "$REQUESTED_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    perch_die "Requested tag must match vX.Y.Z exactly."
  NEXT_TAG="$REQUESTED_TAG"
else
  NEXT_TAG="$(perch_latest_stable_tag "$WORK_DIR/repository")"
fi
[[ -n "$NEXT_TAG" ]] || perch_die "The canonical repository has no stable vX.Y.Z release tags."
git -C "$WORK_DIR/repository" checkout --detach "$NEXT_TAG"

export PERCH_TRUSTED_KEYS_FILE="$TRUSTED_KEYS"
VERIFIED_TAG="$(perch_verify_release_checkout "$WORK_DIR/repository")"
[[ "$VERIFIED_TAG" == "$NEXT_TAG" ]] || perch_die "Verified tag differs from the selected update."

CURRENT_TAG=""
if [[ -f "$PERCH_STATE_DIR/install/version" ]]; then
  CURRENT_TAG="$(tr -d '\r\n' <"$PERCH_STATE_DIR/install/version")"
fi
if [[ "$CURRENT_TAG" == "$NEXT_TAG" && $CLEAN_REINSTALL -eq 0 ]]; then
  perch_note "Perch $NEXT_TAG is already installed."
  exit 0
fi

if [[ -n "$CURRENT_TAG" && "$CURRENT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  IS_DOWNGRADE="$(python3 - "$CURRENT_TAG" "$NEXT_TAG" <<'PY'
import sys
parse = lambda value: tuple(map(int, value.removeprefix("v").split(".")))
print("1" if parse(sys.argv[2]) < parse(sys.argv[1]) else "0")
PY
)"
  [[ "$IS_DOWNGRADE" == "0" ]] ||
    perch_die "Refusing automatic downgrade from $CURRENT_TAG to $NEXT_TAG; restore a schema-compatible backup manually."
fi

perch_note "Building verified update $NEXT_TAG in isolation..."
"$WORK_DIR/repository/install.sh" --no-open
open "$PERCH_APP_PATH"
perch_note "Perch is now at $NEXT_TAG."
