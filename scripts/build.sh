#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox
app="$PWD/dist/Limits.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Limits "$app/Contents/MacOS/Limits"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Limits</string>
  <key>CFBundleDisplayName</key><string>Limits</string>
  <key>CFBundleIdentifier</key><string>pro.ivol.Limits</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>CFBundleShortVersionString</key><string>1.0.4</string>
  <key>CFBundleExecutable</key><string>Limits</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
swift scripts/icon.swift "$app/Contents/Resources"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built: %s\n' "$app"
