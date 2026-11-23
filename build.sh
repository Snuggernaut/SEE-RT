#!/bin/bash
# Builds "SEE-RT.app" into ./build.
# VLC.app must be installed on the Mac that BUILDS the app: its playback engine
# (libvlc + plugins, ~90 MB) is copied into SEE-RT.app, so the finished app runs without VLC.
set -euo pipefail
cd "$(dirname "$0")"
VLC=/Applications/VLC.app/Contents/MacOS
APP="build/SEE-RT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Runs on macOS 13 (Ventura) and later, Apple Silicon (VLC's engine here is arm64-only)
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -import-objc-header Sources/Bridging.h -Xcc -I"$VLC/include" \
  -L"$VLC/lib" -lvlc -Xlinker -rpath -Xlinker @executable_path/lib \
  -framework AppKit -framework Metal -framework MetalKit -framework UniformTypeIdentifiers \
  Sources/*.swift -o "$APP/Contents/MacOS/SEERT"
cp Resources/CRT.metal "$APP/Contents/Resources/"
# App icon: rendered from Tools/MakeIcon.swift (only rebuilt when that file changes)
if [ ! -f build/AppIcon.icns ] || [ Tools/MakeIcon.swift -nt build/AppIcon.icns ]; then
  swiftc -O Tools/MakeIcon.swift -o build/makeicon
  rm -rf build/AppIcon.iconset && build/makeicon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
# Bundle VLC's engine, same layout as inside VLC.app (symlinks preserved, Blu-ray Java bits skipped)
cp -a "$VLC/lib" "$APP/Contents/MacOS/lib"
rsync -a --exclude '*.jar' "$VLC/plugins/" "$APP/Contents/MacOS/plugins/"
cp Resources/VLC-NOTICE.txt "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
