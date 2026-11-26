#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--skip-build" ]]; then
  ./scripts/build.sh
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Limits.app/Contents/Info.plist)"
release_dir="$PWD/release"
stage="$release_dir/.Limits-$version"
dmg="$release_dir/Limits-$version-universal.dmg"

rm -rf "$stage"
mkdir -p "$stage" "$release_dir"
ditto dist/Limits.app "$stage/Limits.app"
ln -s /Applications "$stage/Applications"
printf '%s\n' \
  'УСТАНОВКА LIMITS' \
  '' \
  '1. Перетащите Limits.app на значок Applications.' \
  '2. Откройте Limits из папки «Программы».' \
  '3. При первом запуске выберите автозагрузку и плавающую панель.' \
  '4. Добавьте аккаунты: кнопка «+» в окне Limits.' \
  > "$stage/INSTALL.txt"
if [[ "$(codesign -dv dist/Limits.app 2>&1)" == *"Signature=adhoc"* ]]; then
  # Unsigned builds need the Gatekeeper and keychain hints.
  printf '%s\n' \
    '' \
    'Если macOS пишет, что приложение не проверено:' \
    'Системные настройки → Конфиденциальность и безопасность →' \
    '«Всё равно открыть». Или в Терминале:' \
    '  xattr -dr com.apple.quarantine /Applications/Limits.app' \
    '' \
    'После обновления macOS один раз спросит доступ к ключу' \
    '«pro.ivol.Limits.vault» — введите пароль Mac и нажмите «Всегда разрешать».' \
    >> "$stage/INSTALL.txt"
fi

hdiutil create -volname "Limits $version" -srcfolder "$stage" -format UDZO \
  -imagekey zlib-level=9 -ov "$dmg"
rm -rf "$stage"
hdiutil verify "$dmg"

signing_identity="${LIMITS_CODESIGN_IDENTITY:--}"
if [[ "$signing_identity" != "-" ]]; then
  codesign --force --timestamp --sign "$signing_identity" "$dmg"
  if [[ -n "${LIMITS_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$LIMITS_NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
  fi
fi

(cd "$release_dir" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
printf 'Packaged: %s\n' "$dmg"
