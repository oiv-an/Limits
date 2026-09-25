#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$PWD"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

build_architecture() {
  arch="$1"
  scratch="$project_root/.build-$arch"
  export CLANG_MODULE_CACHE_PATH="$scratch/module-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache"
  xcrun swift build -c release --disable-sandbox --scratch-path "$scratch" \
    --triple "$arch-apple-macosx14.0" --product Limits
  compiled_binary="$(xcrun swift build -c release --disable-sandbox --scratch-path "$scratch" \
    --triple "$arch-apple-macosx14.0" --show-bin-path)/Limits"
}

build_architecture arm64
arm_binary="$compiled_binary"
build_architecture x86_64
intel_binary="$compiled_binary"

app="$PWD/dist/Limits.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "$arm_binary" "$intel_binary" \
  -output "$app/Contents/MacOS/Limits"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Limits</string>
  <key>CFBundleDisplayName</key><string>Limits</string>
  <key>CFBundleIdentifier</key><string>pro.ivol.Limits</string>
  <key>CFBundleVersion</key><string>7</string>
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>CFBundleExecutable</key><string>Limits</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
xcrun swift scripts/icon.swift "$app/Contents/Resources"
signing_identity="${LIMITS_CODESIGN_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
  codesign --force --options runtime --sign - "$app"
else
  codesign --force --options runtime --timestamp --sign "$signing_identity" "$app"
fi
codesign --verify --strict "$app"
test "$(lipo -archs "$app/Contents/MacOS/Limits")" = "x86_64 arm64" \
  || test "$(lipo -archs "$app/Contents/MacOS/Limits")" = "arm64 x86_64"
printf 'Built: %s\n' "$app"
