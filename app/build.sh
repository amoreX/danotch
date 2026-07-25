#!/bin/bash
# Build an Apple-Silicon, source-distribution Perch.app for macOS 26+.
# The installer must provide a pre-fetched Node 24 runtime and its verified
# node-binary SHA-256. This script performs no downloads or notarization.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/../backend"
DERIVED_DATA="$SCRIPT_DIR/.build/xcode-release"
STAGING_DIR="$SCRIPT_DIR/.build/daemon-staging"
NODE_RUNTIME_DIR="${PERCH_NODE_RUNTIME_DIR:-}"
NODE_SHA256="${PERCH_NODE_SHA256:-}"
MARKETING_VERSION="${PERCH_MARKETING_VERSION:-0.0.0}"
BUILD_NUMBER="${PERCH_BUILD_NUMBER:-1}"
RELEASE_BUILD="${PERCH_RELEASE_BUILD:-0}"
EXECUTOR_ARTIFACT_SIGNING_KEY_PEM="${EXECUTOR_ARTIFACT_SIGNING_KEY_PEM:-}"
MANIFEST_BACKUP="$SCRIPT_DIR/.build/ExecutorArtifacts.source.json"

cd "$SCRIPT_DIR"

[[ -n "$NODE_RUNTIME_DIR" && -d "$NODE_RUNTIME_DIR" ]] || {
  echo "ERROR: PERCH_NODE_RUNTIME_DIR must name a pre-fetched Node 24 runtime directory." >&2
  exit 1
}
NODE_BINARY="$NODE_RUNTIME_DIR/bin/node"
NPM_BINARY="$NODE_RUNTIME_DIR/bin/npm"
[[ -x "$NODE_BINARY" && -x "$NPM_BINARY" ]] || {
  echo "ERROR: Node runtime is missing executable bin/node or bin/npm." >&2
  exit 1
}
[[ "$NODE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || {
  echo "ERROR: PERCH_NODE_SHA256 must contain the installer-verified bin/node SHA-256." >&2
  exit 1
}
ACTUAL_NODE_SHA256="$(shasum -a 256 "$NODE_BINARY" | awk '{print $1}')"
ACTUAL_NODE_SHA256="$(printf '%s' "$ACTUAL_NODE_SHA256" | tr '[:upper:]' '[:lower:]')"
NODE_SHA256="$(printf '%s' "$NODE_SHA256" | tr '[:upper:]' '[:lower:]')"
[[ "$ACTUAL_NODE_SHA256" == "$NODE_SHA256" ]] || {
  echo "ERROR: bundled Node binary checksum does not match PERCH_NODE_SHA256." >&2
  exit 1
}
[[ "$("$NODE_BINARY" --version)" =~ ^v24\. ]] || {
  echo "ERROR: bundled runtime must be Node 24." >&2
  exit 1
}
file "$NODE_BINARY" | grep -q "arm64" || {
  echo "ERROR: bundled Node runtime must contain an arm64 executable." >&2
  exit 1
}
export PATH="$NODE_RUNTIME_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$SCRIPT_DIR/.build"
if [[ -n "$EXECUTOR_ARTIFACT_SIGNING_KEY_PEM" ]]; then
  [[ -f "$EXECUTOR_ARTIFACT_SIGNING_KEY_PEM" ]] || {
    echo "ERROR: EXECUTOR_ARTIFACT_SIGNING_KEY_PEM does not name a file." >&2
    exit 1
  }
  cp Resources/ExecutorArtifacts.json "$MANIFEST_BACKUP"
  trap 'cp "$MANIFEST_BACKUP" Resources/ExecutorArtifacts.json; rm -f "$MANIFEST_BACKUP"' EXIT
  python3 scripts/executor_manifest.py Resources/ExecutorArtifacts.json \
    --sign-key "$EXECUTOR_ARTIFACT_SIGNING_KEY_PEM" \
    --output "$SCRIPT_DIR/.build/ExecutorArtifacts.signed.json"
  cp "$SCRIPT_DIR/.build/ExecutorArtifacts.signed.json" Resources/ExecutorArtifacts.json
fi

if [[ "$RELEASE_BUILD" == "1" ]]; then
  python3 -c 'import json,sys; value=json.load(open(sys.argv[1])).get("signature",""); sys.exit(0 if isinstance(value,str) and value.strip() else 1)' \
    Resources/ExecutorArtifacts.json || {
      echo "ERROR: release build requires a non-empty executor manifest signature." >&2
      exit 1
    }
  python3 scripts/executor_manifest.py Resources/ExecutorArtifacts.json
fi

echo "Building backend daemon..."
"$NPM_BINARY" ci --prefix "$BACKEND_DIR"
"$NPM_BINARY" run --prefix "$BACKEND_DIR" build

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp "$BACKEND_DIR/package.json" "$BACKEND_DIR/package-lock.json" "$STAGING_DIR/"
"$NPM_BINARY" ci --prefix "$STAGING_DIR" --omit=dev
cp -R "$BACKEND_DIR/dist" "$STAGING_DIR/dist"
cp "$SCRIPT_DIR/scripts/daemon-entry.mjs" "$STAGING_DIR/entry.mjs"

echo "Building Perch.app..."
xcodegen generate
xcodebuild \
  -project Perch.xcodeproj \
  -scheme Perch \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=26.0 \
  PERCH_MARKETING_VERSION="$MARKETING_VERSION" \
  PERCH_BUILD_NUMBER="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/Perch.app"
[[ -d "$BUILT_APP" ]] || {
  echo "ERROR: app build product was not found." >&2
  exit 1
}
rm -rf "$SCRIPT_DIR/Perch.app"
cp -R "$BUILT_APP" "$SCRIPT_DIR/Perch.app"
BUNDLE_DIR="$SCRIPT_DIR/Perch.app/Contents"

rm -rf "$BUNDLE_DIR/Resources/DaemonRuntime" "$BUNDLE_DIR/Resources/Daemon"
mkdir -p "$BUNDLE_DIR/Resources/DaemonRuntime" "$BUNDLE_DIR/Resources/Daemon"
ditto "$NODE_RUNTIME_DIR" "$BUNDLE_DIR/Resources/DaemonRuntime"
ditto "$STAGING_DIR" "$BUNDLE_DIR/Resources/Daemon"

# Sign Mach-O payloads first, then helpers, then the outer app. The source
# distribution intentionally uses only ad-hoc signatures.
while IFS= read -r -d '' candidate; do
  if file "$candidate" | grep -q "Mach-O"; then
    codesign --force --options runtime --sign - "$candidate"
  fi
done < <(find "$BUNDLE_DIR/Resources/DaemonRuntime" "$BUNDLE_DIR/Resources/Daemon" -type f -print0)

codesign --force --options runtime --sign - "$BUNDLE_DIR/Helpers/PerchDaemonHost"
codesign --force --options runtime --entitlements "$SCRIPT_DIR/Executor.entitlements" \
  --sign - "$BUNDLE_DIR/Helpers/PerchExecutor"
codesign --force --options runtime --entitlements "$SCRIPT_DIR/Perch.entitlements" \
  --sign - "$SCRIPT_DIR/Perch.app"
codesign --verify --deep --strict "$SCRIPT_DIR/Perch.app"

"$BUNDLE_DIR/Helpers/PerchDaemonHost" --self-test
echo "Source build complete: $SCRIPT_DIR/Perch.app"
