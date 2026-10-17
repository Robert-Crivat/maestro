#!/bin/sh
# Build build/Maestro.app: universal (Apple Silicon + Intel), ad-hoc signed.
# Usage: scripts/build-app.sh
set -eu
cd "$(dirname "$0")/.."

VERSION=0.2.0
BUNDLE_ID=com.maestro.local
APP=build/Maestro.app

# One slice per architecture (a multi-arch `swift build` needs full Xcode), then lipo.
swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0
.build/arm64-apple-macosx/release/Maestro --selftest

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/Maestro .build/x86_64-apple-macosx/release/Maestro \
     -output "$APP/Contents/MacOS/Maestro"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Maestro</string>
    <key>CFBundleDisplayName</key><string>Maestro</string>
    <key>CFBundleExecutable</key><string>Maestro</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Robert Crivat Florian · MIT License</string>
</dict>
</plist>
EOF
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

# An ad-hoc signature changes on every build and macOS silently ignores the old
# Accessibility grant (the switch stays on but does nothing): drop it so the app asks again.
# A self-signed certificate would keep the grant across builds, but macOS refuses to enable
# Accessibility for an untrusted certificate (the switch turns itself off again). Verified 2026-10-17.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "ok: $APP ($(lipo -archs "$APP/Contents/MacOS/Maestro"))"
