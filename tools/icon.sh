#!/bin/sh
# tools/icon.svg is the one icon (T3 project icon, site). The iOS app icon is it full-bleed (iOS rounds the corners itself).
cd "$(dirname "$0")/.." && sed 's/ rx="112"//' tools/icon.svg | rsvg-convert -w 1024 -h 1024 | magick - -alpha off ios/Homestill/Assets.xcassets/AppIcon.appiconset/icon.png
