#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="FlareStackIDE"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
VERSION="${VERSION#v}"
APP="$ROOT/build/$NAME.app"
ICONSET="$ROOT/build/AppIcon.iconset"
STEPS=7
STEP=0

progress() {
    STEP=$((STEP + 1))
    local width=30 filled=$((STEP * 30 / STEPS))
    local bar
    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((width - filled)) '' | tr ' ' '-')"
    printf '\r\033[K[%s] %3d%% %s' "$bar" $((STEP * 100 / STEPS)) "$1"
    [ "$STEP" -eq "$STEPS" ] && printf '\n'
    return 0
}

trap 'printf "\n"' ERR

progress "準備"
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"

progress "コンパイル中 (swiftc)"
MODULE="$ROOT/build/module"
rm -rf "$MODULE"
mkdir -p "$MODULE"
swiftc -target arm64-apple-macos13 -O -enable-testing -module-name "$NAME" -emit-executable \
    -emit-module-path "$MODULE/$NAME.swiftmodule" "$ROOT"/Sources/*.swift \
    -o "$APP/Contents/MacOS/$NAME" -Xlinker -export_dynamic

progress "プラグインのコンパイル (plugins/*/plugin.dylib)"
for dir in "$ROOT"/plugins/*/; do
    sources=("$dir"*.swift)
    [ -e "${sources[0]}" ] || continue
    id="$(basename "$dir")"
    swiftc -target arm64-apple-macos13 -O -emit-library -module-name "FSPlugin_${id//-/_}" -I "$MODULE" \
        "${sources[@]}" -o "$dir/plugin.dylib" -Xlinker -undefined -Xlinker dynamic_lookup
done

progress "アイコン生成"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/data/pics/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ROOT/data/pics/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

progress "リソースと Info.plist"
cp "$ROOT/data/pics/interpolate.png" "$APP/Contents/Resources/interpolate.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>com.flarestackide.app</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
    </dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>File</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.data</string>
                <string>public.content</string>
                <string>public.text</string>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

progress "dmg 作成中"
DMG="$ROOT/$NAME-$VERSION.dmg"
STAGE="$ROOT/build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" 2> >(grep -v deprecated >&2) >/dev/null
rm -rf "$STAGE"
progress "完了"

echo "Built $APP ($VERSION)"
echo "Built $DMG"
