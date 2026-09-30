#!/bin/bash
# Сборка для macOS: bash build.sh   (только Apple Silicon: ARCHS=arm64 bash build.sh)
# Нужны Xcode или Command Line Tools:  xcode-select --install
# Результат: build/AiLimitWidget.app (Apple Silicon + Intel) и build/AiLimitWidget.zip и ../release/AiLimitWidget.dmg (его коммитят в git)
set -euo pipefail
cd "$(dirname "$0")"

MIN_OS=12.0
SDK=$(xcrun --sdk macosx --show-sdk-path)
# в новых SDK @State — макрос SwiftUI; в Command Line Tools нет его плагина, берём из Xcode, если он установлен
PLUGIN_FLAGS=()
XCODE_PLUGINS=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
if [ -f "$XCODE_PLUGINS/libSwiftUIMacros.dylib" ]; then PLUGIN_FLAGS=(-plugin-path "$XCODE_PLUGINS"); fi
mkdir -p build

build_app() {
    local NAME=$1 BUNDLE_ID=$2 DISPLAY=$3 EXTRA_PLIST=${4:-}
    local APP="build/$NAME.app"
    echo "==> $NAME"
    rm -rf "$APP" "build/$NAME.zip"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

    local BINS=()
    for ARCH in ${ARCHS:-arm64 x86_64}; do   # только Apple Silicon: ARCHS=arm64 bash build.sh
        xcrun swiftc -O -swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macos$MIN_OS" ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"} \
            -o "build/$NAME-$ARCH" Shared/*.swift Sources/*.swift
        BINS+=("build/$NAME-$ARCH")
    done
    lipo -create -output "$APP/Contents/MacOS/$NAME" "${BINS[@]}"
    rm -f "${BINS[@]}"

    # значок: PNG 256×256 → .icns
    local ICON_KEY=""
    if [ -f "Resources/AppIcon.png" ]; then
        local SET="build/$NAME.iconset"
        rm -rf "$SET" && mkdir -p "$SET"
        for S in 16 32 128 256 512; do
            sips -z $S $S "Resources/AppIcon.png" --out "$SET/icon_${S}x${S}.png" >/dev/null
            sips -z $((S * 2)) $((S * 2)) "Resources/AppIcon.png" --out "$SET/icon_${S}x${S}@2x.png" >/dev/null
        done
        if iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"; then
            ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
        fi
        rm -rf "$SET"
    fi

    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    $ICON_KEY
    $EXTRA_PLIST
</dict>
</plist>
PLIST

    # подпись «для себя» (ad-hoc): без неё Apple Silicon не запустит программу
    codesign --force --deep --sign - "$APP"
    ditto -c -k --keepParent "$APP" "build/$NAME.zip"
    # DMG для раздачи: лежит в release/ рядом с .exe для Windows (коммитится в git)
    mkdir -p ../release
    rm -f "../release/$NAME.dmg"
    # внутри DMG — приложение и ярлык «Программы»: достаточно перетащить одно на другое
    local STAGE="build/dmg"
    rm -rf "$STAGE" && mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/$NAME.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$DISPLAY" -srcfolder "$STAGE" -ov -format UDZO "../release/$NAME.dmg" >/dev/null
    rm -rf "$STAGE"
    echo "    готово: $APP и release/$NAME.dmg"
}

build_app AiLimitWidget com.asror.AiLimitWidget "Лимиты ИИ" \
    "<key>NSAppleEventsUsageDescription</key><string>Чтобы выйти из Antigravity, виджет открывает Терминал с командой agy /logout.</string>"
echo "Перенесите build/AiLimitWidget.app в «Программы» и запустите."
