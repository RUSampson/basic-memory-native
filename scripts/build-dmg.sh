#!/usr/bin/env bash
# UI-7: релизный dmg BMem 1.1.1-beta1.
# Бандл BMem.app: BMemApp (главный исполняемый) + bmem (демон-хелпер рядом,
# как launcher/bmem в dmg 1.1.1) + бандл модели Gemma (текстовая часть, как в
# 1.1.1). Drag-to-Applications, ad-hoc подпись, UDZO. Боевые /Applications и
# ~/.local/bin не трогает.
# Использование: scripts/build-dmg.sh [каталог-источник-модели]
# Источник модели по умолчанию — ~/.bmem/models/embeddinggemma-2-coreml
# (с него в 1.1.1 брали 5 текстовых файлов; audio/vision/mlmodelc не кладём).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.1.2-beta3"
MODEL_SRC="${1:-$HOME/.bmem/models/embeddinggemma-2-coreml}"
STAGE="dist/stage-$VERSION"
APP="$STAGE/BMem.app"
DMG="dist/BMem-$VERSION.dmg"

echo "==> swift build -c release (bmem + BMemApp)"
swift build -c release

[[ -x .build/release/bmem ]] || { echo "нет .build/release/bmem"; exit 1; }
[[ -x .build/release/BMemApp ]] || { echo "нет .build/release/BMemApp"; exit 1; }
[[ -d "$MODEL_SRC" ]] || { echo "нет бандла модели: $MODEL_SRC"; exit 1; }

echo "==> каркас $APP"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/models"
cp .build/release/BMemApp "$APP/Contents/MacOS/BMemApp"
cp .build/release/bmem "$APP/Contents/MacOS/bmem"
cp scripts/icon.icns "$APP/Contents/Resources/icon.icns"
# L10N: каталог языков l10n/ (<lang>.json) + xcstrings системных строк —
# в ресурсном бандле SwiftPM (копируется целиком).
[[ -d .build/release/bm-native_BMemApp.bundle ]] || { echo "нет .build/release/bm-native_BMemApp.bundle"; exit 1; }
cp -R .build/release/bm-native_BMemApp.bundle "$APP/Contents/Resources/"

# Модель: только текстовый бандл (5 файлов), как в dmg 1.1.1.
echo "==> ditto модели из $MODEL_SRC"
mkdir -p "$APP/Contents/models/embeddinggemma-2-coreml"
for f in EmbeddingGemma2Text.mlpackage embeddings.bf16 tokenizer.json config.json position_embeddings.f16; do
  [[ -e "$MODEL_SRC/$f" ]] || { echo "в источнике нет $f"; exit 1; }
  ditto "$MODEL_SRC/$f" "$APP/Contents/models/embeddinggemma-2-coreml/$f"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>BMem</string>
    <key>CFBundleName</key><string>BMem</string>
    <key>CFBundleExecutable</key><string>BMemApp</string>
    <key>CFBundleIdentifier</key><string>com.bmem.app</string>
    <key>CFBundleIconFile</key><string>icon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

ln -sfn /Applications "$STAGE/Applications"

echo "==> ad-hoc подпись"
codesign --force --deep --sign - "$APP"

echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create -volname "BMem $VERSION" -srcfolder "$STAGE" -format UDZO -o "$DMG" >/dev/null

echo "готово:"
ls -l "$DMG"
shasum "$DMG"
