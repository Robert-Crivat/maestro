#!/bin/sh
# Package build/Maestro.app into build/Maestro-<version>.dmg: the app next to an
# Applications shortcut, drag one onto the other to install. Run scripts/build-app.sh first.
set -eu
cd "$(dirname "$0")/.."

APP=build/Maestro.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Maestro-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Volume icon: the Finder shows it when the DMG is mounted.
cp assets/AppIcon.icns "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE" 2>/dev/null || true

rm -f "$DMG"
hdiutil create -volname "Maestro $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
# Bare file name in the checksum file, so `shasum -c` works next to the downloaded DMG.
(cd build && shasum -a 256 "Maestro-$VERSION.dmg" | tee "Maestro-$VERSION.dmg.sha256")
echo "ok: $DMG"
