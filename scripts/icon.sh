#!/usr/bin/env bash
# Render Resources/AppIcon.svg into Resources/AppIcon.icns.
# Needs rsvg-convert: brew install librsvg
set -euo pipefail
cd "$(dirname "$0")/.."

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

# Each size is rendered from the SVG rather than scaled down from 1024,
# so small sizes stay sharp.
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" Resources/AppIcon.svg -o "$SET/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" Resources/AppIcon.svg -o "$SET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo Resources/AppIcon.icns
