#!/usr/bin/env bash
# Сборка BMemApp в .app-бандл (ad-hoc подпись), по образцу бандла 1.1.1:
# Contents/{MacOS,Resources/icon.icns,Info.plist}. Боевой /Applications/BMem.app не трогает.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/BMem-Dev.app"
BIN=".build/release/BMemApp"

echo "==> swift build -c release --product BMemApp"
swift build -c release --product BMemApp

echo "==> собираю бандл $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BMemApp"
cp scripts/icon.icns "$APP/Contents/Resources/icon.icns"
# UI-8: String Catalog живёт в ресурсном бандле SwiftPM — без него L10n
# покажет ключи вместо строк. Имя бандла = <пакет>_<таргет>.bundle.
RES_BUNDLE="$(dirname "$BIN")/bm-native_BMemApp.bundle"
[[ -d "$RES_BUNDLE" ]] || { echo "нет $RES_BUNDLE — пересобери: swift build -c release"; exit 1; }
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>BMem Dev</string>
    <key>CFBundleName</key><string>BMem</string>
    <key>CFBundleExecutable</key><string>BMemApp</string>
    <key>CFBundleIdentifier</key><string>com.bmem.app.dev</string>
    <key>CFBundleIconFile</key><string>icon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1.2-beta3</string>
    <key>CFBundleVersion</key><string>1.1.2-beta3-dev</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc подпись"
codesign --force --sign - "$APP"

echo "готово: $(du -sh "$APP" | cut -f1) $APP"
