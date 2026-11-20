#!/bin/bash
# Build DyskShot.app (release) into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/DyskShot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/DyskShot" "$APP/Contents/MacOS/DyskShot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Stable identity keeps macOS privacy permissions across rebuilds (see scripts/setup-signing.sh).
IDENTITY="DyskShot Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --identifier com.dysklab.dyskshot "$APP"
else
  echo "warning: '$IDENTITY' not found, signing ad-hoc (permissions reset on every rebuild). Run scripts/setup-signing.sh"
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
echo "Run: open $APP"
