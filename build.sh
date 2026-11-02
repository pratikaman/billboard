#!/bin/bash
# Builds bin/billboard-hook (the Claude Code hook) and Billboard.app. No Xcode project.
set -euo pipefail
cd "$(dirname "$0")"
# This Mac's CLT defaults to a newer deployment target than the running OS; pin it or the app won't launch.
TARGET="$(uname -m)-apple-macos14.0"
mkdir -p build bin

swiftc -O -target "$TARGET" Sources/hook/main.swift -o build/billboard-hook
mv -f build/billboard-hook bin/billboard-hook   # atomic swap: running sessions call this path on every tool use

APP=Billboard.app
rm -rf build/$APP && mkdir -p build/$APP/Contents/{MacOS,Resources/Art}
swiftc -O -target "$TARGET" -swift-version 5 Sources/app/*.swift -o build/$APP/Contents/MacOS/Billboard 2>&1 \
  | grep -v "^$" || true
[ -x build/$APP/Contents/MacOS/Billboard ] || { echo "app build failed"; exit 1; }
cp Resources/Info.plist build/$APP/Contents/
[ -d Resources/Art ] && cp Resources/Art/* build/$APP/Contents/Resources/Art/ 2>/dev/null || true
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns build/$APP/Contents/Resources/
codesign --force --sign - build/$APP >/dev/null 2>&1
rm -rf $APP && mv build/$APP $APP
echo "built $APP + bin/billboard-hook"
