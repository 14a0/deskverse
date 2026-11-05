#!/bin/bash
# Build EOU.app into build/ and sign it with the local Apple Development identity.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --package-path app
APP="$ROOT/build/EOU.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "app/.build/release/EOU" "$APP/Contents/MacOS/EOU"
cp app/Info.plist "$APP/Contents/Info.plist"
cp app/Resources/EOU.icns "$APP/Contents/Resources/EOU.icns"
IDENTITY="${EOU_SIGN_IDENTITY:-Apple Development}"
if ! codesign --force --options runtime --entitlements app/EOU.entitlements --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signing with '$IDENTITY' failed; signing ad hoc (macOS will ask for permissions again after each build)."
  codesign --force --options runtime --entitlements app/EOU.entitlements --sign - "$APP"
fi
echo "$APP"
