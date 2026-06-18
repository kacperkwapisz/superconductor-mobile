#!/usr/bin/env bash
# Regenerate iOS App Icon from Superconductor.app (macOS). Run after Superconductor updates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/SuperconductorMobile/Assets.xcassets/AppIcon.appiconset"
ICNS="/Applications/Superconductor.app/Contents/Resources/Superconductor.icns"
if [[ ! -f "$ICNS" ]]; then
  echo "Superconductor.app not found at $ICNS" >&2
  exit 1
fi
SRC=$(mktemp /tmp/superconductor-icon.XXXXXX.png)
trap 'rm -f "$SRC"' EXIT
sips -s format png "$ICNS" --out "$SRC" >/dev/null
gen() { sips -z "$2" "$2" "$SRC" --out "$ICONSET/$1" >/dev/null; }
gen "Icon-20@2x.png" 40
gen "Icon-20@3x.png" 60
gen "Icon-29@2x.png" 58
gen "Icon-29@3x.png" 87
gen "Icon-40@2x.png" 80
gen "Icon-40@3x.png" 120
gen "Icon-60@2x.png" 120
gen "Icon-60@3x.png" 180
gen "Icon-20-ipad.png" 20
gen "Icon-20@2x-ipad.png" 40
gen "Icon-29-ipad.png" 29
gen "Icon-29@2x-ipad.png" 58
gen "Icon-40-ipad.png" 40
gen "Icon-40@2x-ipad.png" 80
gen "Icon-76.png" 76
gen "Icon-76@2x.png" 152
gen "Icon-83.5@2x.png" 167
cp "$SRC" "$ICONSET/Icon-1024.png"
echo "Updated App Icon in $ICONSET"