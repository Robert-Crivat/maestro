#!/bin/sh
# Render assets/icon.svg into assets/AppIcon.icns and assets/icon.png (needs Google Chrome).
set -eu
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '<html><body style="margin:0;background:transparent">%s</body></html>' "$(cat assets/icon.svg)" > "$TMP/icon.html"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$TMP/profile" \
    --default-background-color=00000000 --window-size=1024,1024 \
    --screenshot="$TMP/icon-1024.png" "file://$TMP/icon.html" >/dev/null 2>&1
cp "$TMP/icon-1024.png" assets/icon.png

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
echo "ok: assets/AppIcon.icns"
