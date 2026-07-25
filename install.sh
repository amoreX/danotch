#!/bin/bash
# Build and install a verified Perch source release for the current user.

set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "$0")" && pwd)"
ORIGINAL_PATH="${PATH:-}"
# shellcheck source=scripts/lib/perch-common.sh
source "$SOURCE_ROOT/scripts/lib/perch-common.sh"

OPEN_APP=1
if [[ "${1:-}" == "--no-open" ]]; then
  OPEN_APP=0
elif [[ $# -ne 0 ]]; then
  perch_die "Usage: ./install.sh [--no-open]"
fi

perch_require_host
perch_require_build_tools
RELEASE_TAG="$(perch_verify_release_checkout "$SOURCE_ROOT")"

LOCAL_DAEMON_SOURCE="$SOURCE_ROOT/backend/src/index.ts"
DAEMON_ENTRY_SOURCE="$SOURCE_ROOT/app/scripts/daemon-entry.mjs"
LAUNCH_AGENT_TEMPLATE="$SOURCE_ROOT/app/Resources/engineering.super.Perch.daemon.plist.template"
[[ -f "$LOCAL_DAEMON_SOURCE" ]] ||
  perch_die "Source distribution is not ready: expected local daemon entrypoint backend/src/index.ts."
[[ -f "$DAEMON_ENTRY_SOURCE" ]] ||
  perch_die "Source distribution is not ready: expected app/scripts/daemon-entry.mjs for the Keychain-brokered daemon bootstrap."
[[ -f "$LAUNCH_AGENT_TEMPLATE" ]] ||
  perch_die "Source distribution is not ready: expected the reviewed per-user LaunchAgent template."

NODE_ENV_FILE="$SOURCE_ROOT/release/node-runtime.env"
NODE_CHECKSUM_FILE="$SOURCE_ROOT/release/node-runtime.sha256"
[[ -f "$NODE_ENV_FILE" && -f "$NODE_CHECKSUM_FILE" ]] ||
  perch_die "Pinned Node runtime metadata is incomplete under release/."
# shellcheck disable=SC1090
source "$NODE_ENV_FILE"
: "${NODE_VERSION:?NODE_VERSION is required}"
: "${NODE_PLATFORM:?NODE_PLATFORM is required}"
: "${NODE_ARCHIVE_FORMAT:?NODE_ARCHIVE_FORMAT is required}"
: "${NODE_BASE_URL:?NODE_BASE_URL is required}"
[[ "$NODE_VERSION" =~ ^24\.[0-9]+\.[0-9]+$ ]] ||
  perch_die "The embedded runtime must be an exact Node 24 version."
[[ "$NODE_PLATFORM" == "darwin-arm64" ]] ||
  perch_die "The embedded runtime manifest must target darwin-arm64."

NODE_ARCHIVE="node-v${NODE_VERSION}-${NODE_PLATFORM}.${NODE_ARCHIVE_FORMAT}"
EXPECTED_NODE_SHA="$(awk -v name="$NODE_ARCHIVE" '$2 == name {print $1}' "$NODE_CHECKSUM_FILE")"
[[ "$EXPECTED_NODE_SHA" =~ ^[0-9a-f]{64}$ ]] ||
  perch_die "release/node-runtime.sha256 has no valid digest for $NODE_ARCHIVE."

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/perch-install.XXXXXX")"
STAGED_SOURCE="$WORK_DIR/source"
STAGED_APP="$WORK_DIR/Perch.app"
STAGED_PLIST="$WORK_DIR/$PERCH_LABEL.plist"
PREVIOUS_APP="$HOME/Applications/.Perch.app.previous"
PREVIOUS_SOURCE="$PERCH_STATE_DIR/install/source.previous"
PREVIOUS_PLIST="$HOME/Library/LaunchAgents/.$PERCH_LABEL.plist.previous"
INSTALLED_SOURCE="$PERCH_STATE_DIR/install/source"
ACTIVATION_APP="$HOME/Applications/.Perch.app.staging.$$"
ACTIVATION_SOURCE="$PERCH_STATE_DIR/install/source.staging.$$"
ACTIVATION_PLIST="$HOME/Library/LaunchAgents/.$PERCH_LABEL.plist.staging.$$"
DATABASE_BACKUP="$PERCH_STATE_DIR/backups/perch.sqlite3.before-${RELEASE_TAG}-$(date -u +%Y%m%dT%H%M%SZ)"
SWAP_STARTED=0
HAD_PREVIOUS_APP=0
HAD_PREVIOUS_SOURCE=0
HAD_PREVIOUS_PLIST=0
HAD_DATABASE=0

cleanup() {
  rm -rf "$WORK_DIR" "$ACTIVATION_APP" "$ACTIVATION_SOURCE"
  rm -f "$ACTIVATION_PLIST"
}

rollback() {
  local status=$?
  trap - ERR
  if ((SWAP_STARTED == 1)); then
    perch_note "Installation failed after activation; restoring the previous app, daemon, source, and SQLite backup."
    perch_launchctl_remove
    rm -rf "$PERCH_APP_PATH"
    if ((HAD_PREVIOUS_APP == 1)) && [[ -d "$PREVIOUS_APP" ]]; then
      mv "$PREVIOUS_APP" "$PERCH_APP_PATH"
    fi
    rm -rf "$INSTALLED_SOURCE"
    if ((HAD_PREVIOUS_SOURCE == 1)) && [[ -d "$PREVIOUS_SOURCE" ]]; then
      mv "$PREVIOUS_SOURCE" "$INSTALLED_SOURCE"
    fi
    rm -f "$PERCH_LAUNCH_AGENT"
    if ((HAD_PREVIOUS_PLIST == 1)) && [[ -f "$PREVIOUS_PLIST" ]]; then
      mv "$PREVIOUS_PLIST" "$PERCH_LAUNCH_AGENT"
    fi
    if ((HAD_DATABASE == 1)); then
      perch_restore_database "$DATABASE_BACKUP"
    else
      rm -f "$PERCH_DATABASE" "$PERCH_DATABASE-wal" "$PERCH_DATABASE-shm"
    fi
    if [[ -f "$PERCH_LAUNCH_AGENT" && -d "$PERCH_APP_PATH" ]]; then
      launchctl bootstrap "gui/$(id -u)" "$PERCH_LAUNCH_AGENT" >/dev/null 2>&1 || true
    fi
  fi
  cleanup
  exit "$status"
}
trap cleanup EXIT
trap rollback ERR

perch_note "Preparing verified source for $RELEASE_TAG..."
mkdir -p "$STAGED_SOURCE"
git -C "$SOURCE_ROOT" archive --format=tar "$RELEASE_TAG" | tar -xf - -C "$STAGED_SOURCE"

NODE_DOWNLOAD="$WORK_DIR/$NODE_ARCHIVE"
NODE_URL="${NODE_BASE_URL%/}/v${NODE_VERSION}/${NODE_ARCHIVE}"
perch_note "Downloading pinned Node.js v$NODE_VERSION for Apple Silicon..."
curl --fail --show-error --location --proto '=https' --tlsv1.2 \
  --output "$NODE_DOWNLOAD" "$NODE_URL"
ACTUAL_NODE_SHA="$(shasum -a 256 "$NODE_DOWNLOAD" | awk '{print $1}')"
[[ "$ACTUAL_NODE_SHA" == "$EXPECTED_NODE_SHA" ]] ||
  perch_die "Node runtime checksum mismatch for $NODE_ARCHIVE; refusing untrusted bytes."

RUNTIME_ROOT="$WORK_DIR/runtime"
mkdir -p "$RUNTIME_ROOT"
tar -xzf "$NODE_DOWNLOAD" -C "$RUNTIME_ROOT"
RUNTIME_HOME="$RUNTIME_ROOT/node-v${NODE_VERSION}-${NODE_PLATFORM}"
NODE_BIN="$RUNTIME_HOME/bin/node"
NPM_BIN="$RUNTIME_HOME/bin/npm"
[[ -x "$NODE_BIN" && -x "$NPM_BIN" ]] ||
  perch_die "Verified Node archive did not contain the expected bin/node and bin/npm."
[[ "$("$NODE_BIN" -p 'process.arch')" == "arm64" ]] ||
  perch_die "Downloaded Node runtime is not arm64."
[[ "$("$NODE_BIN" --version)" == "v$NODE_VERSION" ]] ||
  perch_die "Downloaded Node runtime version does not match the manifest."

export PATH="$RUNTIME_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export npm_config_audit=false
export npm_config_fund=false

perch_note "Installing and testing daemon dependencies with the bundled runtime..."
"$NPM_BIN" ci --prefix "$STAGED_SOURCE/backend"
"$NPM_BIN" test --prefix "$STAGED_SOURCE/backend"
"$NPM_BIN" run build --prefix "$STAGED_SOURCE/backend"
[[ -f "$STAGED_SOURCE/backend/dist/index.js" ]] ||
  perch_die "Daemon build passed but did not produce backend/dist/index.js."

perch_note "Resolving and testing the macOS app..."
(
  cd "$STAGED_SOURCE/app"
  swift package resolve
  swift test
  python3 scripts/verify_release_static.py
  xcodegen generate
  xcodebuild -project Perch.xcodeproj -scheme Perch -configuration Release \
    -derivedDataPath "$WORK_DIR/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    PERCH_MARKETING_VERSION="${RELEASE_TAG#v}" \
    PERCH_BUILD_NUMBER="$(git -C "$SOURCE_ROOT" rev-list --count "$RELEASE_TAG")" \
    build
)

BUILT_APP="$WORK_DIR/DerivedData/Build/Products/Release/Perch.app"
[[ -d "$BUILT_APP" ]] || perch_die "Xcode build did not produce Perch.app at the deterministic Release path."
ditto "$BUILT_APP" "$STAGED_APP"

RUNTIME_DEST="$STAGED_APP/Contents/Resources/DaemonRuntime"
DAEMON_DEST="$STAGED_APP/Contents/Resources/Daemon"
mkdir -p "$RUNTIME_DEST" "$DAEMON_DEST"
ditto "$RUNTIME_HOME" "$RUNTIME_DEST"
ditto "$STAGED_SOURCE/backend/dist" "$DAEMON_DEST/dist"
ditto "$STAGED_SOURCE/backend/node_modules" "$DAEMON_DEST/node_modules"
cp "$STAGED_SOURCE/backend/package.json" "$DAEMON_DEST/package.json"
cp "$STAGED_SOURCE/backend/package-lock.json" "$DAEMON_DEST/package-lock.json"
cp "$STAGED_SOURCE/app/scripts/daemon-entry.mjs" "$DAEMON_DEST/entry.mjs"
"$NPM_BIN" prune --omit=dev --prefix "$DAEMON_DEST"

HELPER="$STAGED_APP/Contents/Helpers/PerchExecutor"
DAEMON_HOST="$STAGED_APP/Contents/Helpers/PerchDaemonHost"
[[ -f "$HELPER" ]] || perch_die "Built app is missing Contents/Helpers/PerchExecutor."
[[ -f "$DAEMON_HOST" ]] || perch_die "Built app is missing Contents/Helpers/PerchDaemonHost."
codesign --force --options runtime --sign - "$RUNTIME_DEST/bin/node"
codesign --force --options runtime --entitlements "$STAGED_SOURCE/app/Executor.entitlements" --sign - "$HELPER"
codesign --force --options runtime --sign - "$DAEMON_HOST"
codesign --force --options runtime --entitlements "$STAGED_SOURCE/app/Perch.entitlements" --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
[[ "$(lipo -archs "$STAGED_APP/Contents/MacOS/Perch")" == "arm64" ]] ||
  perch_die "Built Perch executable is not arm64-only."

mkdir -p "$PERCH_STATE_DIR" "$PERCH_LOG_DIR" "$HOME/Applications" \
  "$HOME/Library/LaunchAgents" "$HOME/.local/bin" "$PERCH_STATE_DIR/install"
chmod 700 "$PERCH_STATE_DIR" "$PERCH_LOG_DIR" "$PERCH_STATE_DIR/install"
if [[ -f "$PERCH_DATABASE" ]]; then
  HAD_DATABASE=1
fi
perch_backup_database "$DATABASE_BACKUP"

python3 - "$STAGED_SOURCE/app/Resources/engineering.super.Perch.daemon.plist.template" \
  "$STAGED_PLIST" "$PERCH_APP_PATH" "$PERCH_LOG_DIR" <<'PY'
import sys
from pathlib import Path

source, destination, app_path, log_path = sys.argv[1:]
value = Path(source).read_text(encoding="utf-8")
value = value.replace("__PERCH_APP_PATH__", app_path)
value = value.replace("__PERCH_LOG_PATH__", log_path)
if "__PERCH_" in value:
    raise SystemExit("ERROR: unresolved LaunchAgent template variable")
Path(destination).write_text(value, encoding="utf-8")
PY
plutil -lint "$STAGED_PLIST" >/dev/null

perch_note "Activating Perch with an atomic per-user swap..."
rm -rf "$ACTIVATION_APP" "$ACTIVATION_SOURCE"
rm -f "$ACTIVATION_PLIST"
ditto "$STAGED_APP" "$ACTIVATION_APP"
mkdir -p "$ACTIVATION_SOURCE"
git -C "$SOURCE_ROOT" archive --format=tar "$RELEASE_TAG" |
  tar -xf - -C "$ACTIVATION_SOURCE"
cp "$STAGED_PLIST" "$ACTIVATION_PLIST"
perch_launchctl_remove
osascript -e 'tell application id "engineering.super.Perch" to quit' >/dev/null 2>&1 || true
rm -rf "$PREVIOUS_APP" "$PREVIOUS_SOURCE"
rm -f "$PREVIOUS_PLIST"
if [[ -d "$PERCH_APP_PATH" ]]; then
  mv "$PERCH_APP_PATH" "$PREVIOUS_APP"
  HAD_PREVIOUS_APP=1
fi
if [[ -d "$INSTALLED_SOURCE" ]]; then
  mv "$INSTALLED_SOURCE" "$PREVIOUS_SOURCE"
  HAD_PREVIOUS_SOURCE=1
fi
if [[ -f "$PERCH_LAUNCH_AGENT" ]]; then
  mv "$PERCH_LAUNCH_AGENT" "$PREVIOUS_PLIST"
  HAD_PREVIOUS_PLIST=1
fi
SWAP_STARTED=1
mv "$ACTIVATION_APP" "$PERCH_APP_PATH"
mv "$ACTIVATION_SOURCE" "$INSTALLED_SOURCE"
mv "$ACTIVATION_PLIST" "$PERCH_LAUNCH_AGENT"
cp "$INSTALLED_SOURCE/bin/perch" "$PERCH_CLI_PATH"
chmod 755 "$PERCH_CLI_PATH"
printf '%s\n' "$RELEASE_TAG" >"$PERCH_STATE_DIR/install/version"

launchctl bootstrap "gui/$(id -u)" "$PERCH_LAUNCH_AGENT"
DISCOVERY_FILE="$PERCH_STATE_DIR/runtime/daemon.json"
HEALTHY=0
for _ in $(seq 1 30); do
  if [[ -f "$DISCOVERY_FILE" ]]; then
    if python3 "$INSTALLED_SOURCE/scripts/verify-local-health.py" "$DISCOVERY_FILE"; then
      HEALTHY=1
      break
    fi
  fi
  sleep 1
done
((HEALTHY == 1)) ||
  perch_die "The local daemon did not pass its authenticated health check within 30 seconds."

SWAP_STARTED=0
rm -rf "$PREVIOUS_APP" "$PREVIOUS_SOURCE"
rm -f "$PREVIOUS_PLIST"
if ((OPEN_APP == 1)); then
  open "$PERCH_APP_PATH"
fi
perch_note "Perch $RELEASE_TAG is installed at $PERCH_APP_PATH."
perch_note "Use '$PERCH_CLI_PATH update' for signed source updates."
if [[ ":$ORIGINAL_PATH:" != *":$HOME/.local/bin:"* ]]; then
  perch_note "Add $HOME/.local/bin to PATH to invoke the installed 'perch' command directly."
fi
