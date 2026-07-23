#!/bin/bash
# Build, sign, and optionally notarize Perch.app.
#
# DEVELOPER ID SIGNING (production):
#   Export your Developer ID Application cert as a .p12, decode to $RUNNER_TEMP/cert.p12,
#   and import into the Keychain before calling this script. Then set:
#     DEVELOPER_ID_CERT=<40-char SHA-1 of the identity, or the Common Name>
#     APPLE_ID, APPLE_ID_PASSWORD, APPLE_TEAM_ID  — required for notarization
#     NOTARIZE=1                                   — opt in to notarytool submission
#
#   The CI workflow release-macos.yml handles this automatically. See
#   docs/runbooks/macos-release.md for operator instructions.
#
# AD-HOC BUILD (development / testing):
#   Run without any of the above variables. The app is signed ad-hoc with
#   Hardened Runtime for local testing. It is NOT notarized, NOT for
#   distribution, and will not pass Gatekeeper on a clean Mac.
#
# REFUSING INSECURE OUTPUT:
#   If DEVELOPER_ID_CERT is set but notarization is skipped (NOTARIZE != 1)
#   the script exits with an error to prevent accidental unnotarized publication.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

DEVELOPER_ID_CERT="${DEVELOPER_ID_CERT:-}"
NOTARIZE="${NOTARIZE:-0}"
APPLE_ID="${APPLE_ID:-}"
APPLE_ID_PASSWORD="${APPLE_ID_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

# If a real Developer ID cert is configured, require notarization to be
# explicitly opted in. An unnotarized Developer-ID-signed artifact is
# misleading and must not be published.
if [[ -n "$DEVELOPER_ID_CERT" && "$NOTARIZE" != "1" ]]; then
  echo ""
  echo "ERROR: DEVELOPER_ID_CERT is set but NOTARIZE=1 was not specified."
  echo "Unnotarized Developer ID artifacts are refused to prevent accidental"
  echo "distribution of an app that will fail Gatekeeper on a clean Mac."
  echo ""
  echo "Either:"
  echo "  - Set NOTARIZE=1 (and provide APPLE_ID / APPLE_ID_PASSWORD / APPLE_TEAM_ID)"
  echo "    to produce a notarized distributable archive."
  echo "  - Unset DEVELOPER_ID_CERT to produce an ad-hoc development build."
  echo ""
  exit 1
fi

echo "Building Perch..."
xcodegen generate
DERIVED_DATA="$SCRIPT_DIR/.build/xcode-release"
xcodebuild \
    -project Perch.xcodeproj \
    -scheme Perch \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/Perch.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "Build failed: app not found at $BUILT_APP"
    exit 1
fi
rm -rf "$SCRIPT_DIR/Perch.app"
cp -R "$BUILT_APP" "$SCRIPT_DIR/Perch.app"
BUNDLE_DIR="$SCRIPT_DIR/Perch.app/Contents"

if [[ -n "$DEVELOPER_ID_CERT" ]]; then
  # --- Developer ID signing (inside-out, Hardened Runtime) ---
  echo "Signing with Developer ID: $DEVELOPER_ID_CERT"

  if [ -f "$BUNDLE_DIR/Helpers/PerchExecutor" ]; then
    codesign --force --options runtime --entitlements "$SCRIPT_DIR/Executor.entitlements" \
        --sign "$DEVELOPER_ID_CERT" "$BUNDLE_DIR/Helpers/PerchExecutor"
  fi
  codesign --force --options runtime --entitlements "$SCRIPT_DIR/Perch.entitlements" \
      --sign "$DEVELOPER_ID_CERT" "$BUNDLE_DIR/.."

  codesign --verify --deep --strict "$SCRIPT_DIR/Perch.app"
  codesign -dvvv "$SCRIPT_DIR/Perch.app"

  if [[ "$NOTARIZE" == "1" ]]; then
    if [[ -z "$APPLE_ID" || -z "$APPLE_ID_PASSWORD" || -z "$APPLE_TEAM_ID" ]]; then
      echo "ERROR: NOTARIZE=1 requires APPLE_ID, APPLE_ID_PASSWORD, and APPLE_TEAM_ID."
      exit 1
    fi

    VERSION=$(defaults read "$SCRIPT_DIR/Perch.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "dev")
    ARCHIVE="$SCRIPT_DIR/Perch-${VERSION}.zip"

    echo "Creating archive for notarization: $ARCHIVE"
    ditto -c -k --keepParent "$SCRIPT_DIR/Perch.app" "$ARCHIVE"

    echo "Submitting to Apple notary service (this may take a few minutes)..."
    xcrun notarytool submit "$ARCHIVE" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_ID_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$SCRIPT_DIR/Perch.app"
    xcrun stapler validate "$SCRIPT_DIR/Perch.app"

    echo "Verifying Gatekeeper acceptance..."
    spctl --assess --type execute -vv "$SCRIPT_DIR/Perch.app"

    # Repackage stapled app
    ditto -c -k --keepParent "$SCRIPT_DIR/Perch.app" "$ARCHIVE"
    shasum -a 256 "$ARCHIVE" | tee "$SCRIPT_DIR/Perch-${VERSION}.sha256"

    echo ""
    echo "Build complete — NOTARIZED and STAPLED"
    echo "Archive:  $ARCHIVE"
    echo "Checksum: Perch-${VERSION}.sha256"
    echo ""
  fi
else
  # --- Ad-hoc signing (development/testing only) ---
  echo ""
  echo "⚠️  WARNING: AD-HOC BUILD — NOT FOR DISTRIBUTION ⚠️"
  echo "This artifact is signed ad-hoc. It will NOT pass Gatekeeper on"
  echo "another Mac and MUST NOT be published or distributed."
  echo ""
  echo "To produce a distributable artifact, set DEVELOPER_ID_CERT and NOTARIZE=1."
  echo "See docs/runbooks/macos-release.md for instructions."
  echo ""

  if [ -f "$BUNDLE_DIR/Helpers/PerchExecutor" ]; then
    codesign --force --options runtime --entitlements "$SCRIPT_DIR/Executor.entitlements" \
        --sign - "$BUNDLE_DIR/Helpers/PerchExecutor"
  fi
  codesign --force --options runtime --entitlements "$SCRIPT_DIR/Perch.entitlements" \
      --sign - "$BUNDLE_DIR/.."

  echo "Ad-hoc build complete: Perch.app"
  echo "Run locally: open Perch.app"
fi
