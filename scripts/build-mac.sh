#!/bin/sh
# Build the macOS agent as a universal OpenTrack.app and package it in a dmg.
# Usage: scripts/build-mac.sh <version>        (run on macOS)
# Output: dist/OpenTrack-mac-<version>.dmg
#
# The app is ad-hoc signed (free). It is not notarized, so on first launch of a
# freshly downloaded copy macOS asks you to confirm: right-click > Open.
set -eu

VERSION="${1:?usage: build-mac.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/stage/OpenTrack.app"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS"

cd "$ROOT/agent-mac"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/OpenTrack"

cp "$BIN" "$APP/Contents/MacOS/OpenTrack"
sed "s/__VERSION__/$VERSION/g" Info.plist > "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

ln -s /Applications "$DIST/stage/Applications"
hdiutil create -volname "OpenTrack" -srcfolder "$DIST/stage" -ov -format UDZO "$DIST/OpenTrack-mac-$VERSION.dmg"
ls -l "$DIST/OpenTrack-mac-$VERSION.dmg"
