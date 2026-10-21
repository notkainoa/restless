#!/usr/bin/env bash
# Renders icon/restless.svg into the AppIcon asset catalog (all macOS sizes).
# Requires: rsvg-convert (brew install librsvg) and sips (built in).
set -euo pipefail
cd "$(dirname "$0")"

SVG="restless.svg"
OUT="../Resources/Assets.xcassets/AppIcon.appiconset"
MASTER="$(mktemp -t restless-master).png"

rsvg-convert -w 1024 -h 1024 "$SVG" -o "$MASTER"

emit() { # emit <filename> <pixels>
  sips -z "$2" "$2" "$MASTER" --out "$OUT/$1" >/dev/null
}

emit icon_16.png      16
emit icon_16@2x.png   32
emit icon_32.png      32
emit icon_32@2x.png   64
emit icon_128.png     128
emit icon_128@2x.png  256
emit icon_256.png     256
emit icon_256@2x.png  512
emit icon_512.png     512
emit icon_512@2x.png  1024

rm -f "$MASTER"
echo "✅ App icon generated into $OUT"
