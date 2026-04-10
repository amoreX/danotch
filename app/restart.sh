#!/bin/bash
set -e

cd "$(dirname "$0")"
chmod +x "$0"

echo "Building..."
swift build 2>&1 | grep -E "error:|warning:|Build complete"

# Copy debug binary into app bundle so it runs with the correct bundle ID (com.danotch.app)
# This ensures TCC (calendar, etc.) permissions are correctly associated
mkdir -p Danotch.app/Contents/MacOS
cp .build/debug/Danotch Danotch.app/Contents/MacOS/Danotch
codesign --force --sign - Danotch.app/Contents/MacOS/Danotch 2>/dev/null || true

echo "Restarting Danotch..."
pkill -x Danotch 2>/dev/null || true
sleep 0.5
open Danotch.app

echo "Done."
