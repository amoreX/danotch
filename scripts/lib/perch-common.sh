#!/bin/bash
# Shared, side-effect-free helpers for Perch's source distribution scripts.

set -euo pipefail

PERCH_REPOSITORY_URL="${PERCH_REPOSITORY_URL:-https://github.com/unordinarytech/perch.git}"
PERCH_APP_PATH="${PERCH_APP_PATH:-$HOME/Applications/Perch.app}"
PERCH_STATE_DIR="${PERCH_STATE_DIR:-$HOME/Library/Application Support/Perch}"
PERCH_LOG_DIR="${PERCH_LOG_DIR:-$HOME/Library/Logs/Perch}"
PERCH_LAUNCH_AGENT="${PERCH_LAUNCH_AGENT:-$HOME/Library/LaunchAgents/engineering.super.Perch.daemon.plist}"
PERCH_LABEL="engineering.super.Perch.daemon"
PERCH_CLI_PATH="${PERCH_CLI_PATH:-$HOME/.local/bin/perch}"
PERCH_DATABASE="$PERCH_STATE_DIR/data/perch.sqlite3"

perch_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

perch_note() {
  printf '%s\n' "$*"
}

perch_require_host() {
  [[ "$(uname -s)" == "Darwin" ]] || perch_die "Perch supports macOS only."
  [[ "$(uname -m)" == "arm64" ]] ||
    perch_die "Perch requires Apple Silicon (arm64); Intel and Rosetta installs are unsupported."

  local major
  major="$(sw_vers -productVersion | awk -F. '{print $1}')"
  [[ "$major" =~ ^[0-9]+$ ]] || perch_die "Could not determine the macOS version."
  ((major >= 26)) || perch_die "Perch requires macOS 26 or newer; found $(sw_vers -productVersion)."

  command -v git >/dev/null 2>&1 || perch_die "Git is required. Install Apple's Command Line Tools with: xcode-select --install"
  command -v python3 >/dev/null 2>&1 || perch_die "python3 is required (provided by Xcode Command Line Tools)."
  command -v curl >/dev/null 2>&1 || perch_die "curl is required for the pinned Node runtime download."
  command -v shasum >/dev/null 2>&1 || perch_die "shasum is required to verify downloaded runtime bytes."
}

perch_require_build_tools() {
  command -v xcodebuild >/dev/null 2>&1 ||
    perch_die "Xcode 26+ is required. Install Xcode, then select it with: sudo xcode-select -s /Applications/Xcode.app"
  local xcode_major xcode_version
  xcode_version="$(xcodebuild -version 2>/dev/null)" ||
    perch_die "Full Xcode 26+ must be selected. Run: sudo xcode-select -s /Applications/Xcode.app"
  xcode_major="$(printf '%s\n' "$xcode_version" | awk 'NR == 1 {split($2, v, "."); print v[1]}')"
  [[ "$xcode_major" =~ ^[0-9]+$ ]] || perch_die "Could not determine the Xcode version."
  ((xcode_major >= 26)) || perch_die "Xcode 26 or newer is required; found $(printf '%s' "$xcode_version" | tr '\n' ' ')."
  command -v xcodegen >/dev/null 2>&1 ||
    perch_die "XcodeGen 2.44.1+ is required to build Perch. Install it explicitly from https://github.com/yonaskolb/XcodeGen/releases (Homebrew is optional for this build tool only)."
}

perch_tag_fingerprint() {
  local repository="$1"
  local tag="$2"
  local verification_log="$3"

  git -C "$repository" verify-tag --raw "$tag" >"$verification_log" 2>&1 ||
    perch_die "Tag $tag does not have a valid cryptographic signature. See docs/maintainer-keys.md."

  awk '/^\[GNUPG:\] VALIDSIG / {print toupper($3); exit}' "$verification_log"
}

perch_verify_release_checkout() {
  local repository="$1"
  local keys_file="${PERCH_TRUSTED_KEYS_FILE:-$repository/release/maintainer-gpg-fingerprints.txt}"
  local keys_directory
  local gnupg_home
  local tag
  local object_type
  local tag_commit
  local fingerprint
  local verification_log

  [[ -d "$repository/.git" ]] ||
    perch_die "Run this installer from a Git clone of $PERCH_REPOSITORY_URL; source archives cannot prove tag authenticity."
  [[ -f "$keys_file" ]] ||
    perch_die "Missing trusted maintainer fingerprint allowlist; release trust is not configured."
  grep -Eq '^[A-Fa-f0-9]{40,64}$' "$keys_file" ||
    perch_die "No maintainer signing fingerprint is configured. A maintainer must complete docs/maintainer-keys.md before installation."
  command -v gpg >/dev/null 2>&1 ||
    perch_die "GnuPG is required to verify release tags. Install it from https://gnupg.org/download/ and retry."

  keys_directory="$(dirname "$keys_file")/keys"
  compgen -G "$keys_directory/*.asc" >/dev/null ||
    perch_die "No exported maintainer public key exists beside the trusted fingerprint allowlist."
  gnupg_home="$(mktemp -d "${TMPDIR:-/tmp}/perch-gnupg.XXXXXX")"
  chmod 700 "$gnupg_home"
  GNUPGHOME="$gnupg_home" gpg --batch --quiet --import "$keys_directory"/*.asc ||
    perch_die "A documented maintainer public key could not be imported into the temporary verification keyring."

  tag="$(git -C "$repository" describe --tags --exact-match HEAD 2>/dev/null || true)"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    perch_die "Install from an exact stable release tag (vX.Y.Z), not a branch or untagged commit."
  object_type="$(git -C "$repository" cat-file -t "refs/tags/$tag" 2>/dev/null || true)"
  [[ "$object_type" == "tag" ]] || perch_die "Release $tag is lightweight; Perch requires an annotated signed tag."
  tag_commit="$(git -C "$repository" rev-list -n 1 "$tag")"
  [[ "$(git -C "$repository" rev-parse HEAD)" == "$tag_commit" ]] ||
    perch_die "The checked-out commit does not match $tag."
  [[ -z "$(git -C "$repository" status --porcelain --untracked-files=all)" ]] ||
    perch_die "The release checkout has local modifications or untracked files; installation requires the exact signed source tree."

  verification_log="$(mktemp "${TMPDIR:-/tmp}/perch-tag-verification.XXXXXX")"
  fingerprint="$(GNUPGHOME="$gnupg_home" perch_tag_fingerprint "$repository" "$tag" "$verification_log")"
  rm -f "$verification_log"
  rm -rf "$gnupg_home"
  [[ -n "$fingerprint" ]] ||
    perch_die "Tag $tag verified with an unsupported signature format; release tags must use a documented OpenPGP maintainer key."
  grep -Eiq "^${fingerprint}$" "$keys_file" ||
    perch_die "Tag $tag is validly signed, but signer $fingerprint is not in the documented maintainer allowlist."
  printf '%s\n' "$tag"
}

perch_latest_stable_tag() {
  git -C "$1" tag --list 'v[0-9]*.[0-9]*.[0-9]*' |
    python3 -c 'import re,sys; tags=[(tuple(map(int,m.groups())),line.strip()) for line in sys.stdin if (m:=re.fullmatch(r"v([0-9]+)\.([0-9]+)\.([0-9]+)\n?",line))]; print(max(tags)[1] if tags else "")'
}

perch_launchctl_remove() {
  launchctl bootout "gui/$(id -u)/$PERCH_LABEL" >/dev/null 2>&1 || true
}

perch_backup_database() {
  local destination="$1"
  [[ -f "$PERCH_DATABASE" ]] || return 0
  mkdir -p "$(dirname "$destination")"
  python3 - "$PERCH_DATABASE" "$destination" <<'PY'
import sqlite3
import sys

source = sqlite3.connect(sys.argv[1], timeout=10)
destination = sqlite3.connect(sys.argv[2])
with destination:
    source.backup(destination)
destination.close()
source.close()
PY
  chmod 600 "$destination"
}

perch_restore_database() {
  local backup="$1"
  [[ -f "$backup" ]] || return 0
  rm -f "$PERCH_DATABASE-wal" "$PERCH_DATABASE-shm"
  cp "$backup" "$PERCH_DATABASE"
  chmod 600 "$PERCH_DATABASE"
}
