#!/bin/bash
# Local Suiqu disk image. No upload, notarization or external Homebrew changes.
# Usage: scripts/make-dmg.sh [debug|release] [--skip-build]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
if [ "${2:-}" != "--skip-build" ]; then scripts/build-app.sh "$CONFIG"; fi
APP="build/随取.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Suiqu-$VERSION.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$APP" "$WORK/"
ln -s /Applications "$WORK/Applications"
hdiutil create -quiet -ov -srcfolder "$WORK" -volname "随取" -format UDZO "$DMG"
echo "Built $DMG"
