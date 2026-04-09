#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
ICON_SVG="$BUILD_DIR/icon.svg"
DMG_BG_SVG="$BUILD_DIR/dmg-background.svg"
ICON_PNG="$BUILD_DIR/icon-1024.png"
DMG_BG_PNG="$BUILD_DIR/dmg-background.png"
ICONSET_DIR="$BUILD_DIR/icon.iconset"
ICNS_FILE="$BUILD_DIR/icon.icns"

mkdir -p "$BUILD_DIR"

render_svg_png() {
  local svg_path="$1"
  local png_path="$2"
  qlmanage -t -s 1024 -o "$BUILD_DIR" "$svg_path" >/dev/null 2>&1
  local generated="$BUILD_DIR/$(basename "$svg_path").png"
  mv "$generated" "$png_path"
}

render_svg_png "$ICON_SVG" "$ICON_PNG"
render_svg_png "$DMG_BG_SVG" "$DMG_BG_PNG"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$ICON_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_FILE"
echo "Generated $ICNS_FILE and $DMG_BG_PNG"
