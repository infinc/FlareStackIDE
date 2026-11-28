#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="FlareStackIDE"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
VERSION="${VERSION#v}${VERSION_SUFFIX:-}"
APP="$ROOT/build/$NAME.app"
ICONSET="$ROOT/build/AppIcon.iconset"
STEPS=8
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

SERVICE="$APP/Contents/XPCServices/FlareStackPluginHost.xpc/Contents"
mkdir -p "$SERVICE/MacOS"
swiftc -target arm64-apple-macos13 -O -module-name FlareStackPluginHost "$ROOT"/Worker/*.swift -o "$SERVICE/MacOS/FlareStackPluginHost"
cat > "$SERVICE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.flarestackide.app.PluginHost</string>
    <key>CFBundleName</key><string>FlareStackPluginHost</string>
    <key>CFBundleExecutable</key><string>FlareStackPluginHost</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>XPCService</key>
    <dict>
        <key>ServiceType</key><string>Application</string>
    </dict>
</dict>
</plist>
PLIST

progress "プラグインのコンパイル (plugins/*/plugin.dylib)"
STAMPS="$ROOT/build/plugin-stamps"
mkdir -p "$STAMPS"
for dir in "$ROOT"/plugins/*/; do
    sources=("$dir"*.swift)
    [ -e "${sources[0]}" ] || continue
    id="$(basename "$dir")"
    if grep -q '"abi": *"c"' "$dir/plugin.json" 2>/dev/null; then
        stamp="$(cat "${sources[@]}" "$ROOT"/PluginKit/CAPI/*.swift | shasum -a 256 | cut -d' ' -f1)"
        if [ -f "$dir/plugin.dylib" ] && [ "$(cat "$STAMPS/$id" 2>/dev/null)" = "$stamp" ]; then continue; fi
        swiftc -target arm64-apple-macos13 -O -emit-library -module-name "FSPlugin_${id//-/_}" \
            "${sources[@]}" "$ROOT"/PluginKit/CAPI/*.swift -o "$dir/plugin.dylib"
    else
        stamp="$(cat "${sources[@]}" "$ROOT"/PluginKit/*.swift "$MODULE/$NAME.swiftmodule" | shasum -a 256 | cut -d' ' -f1)"
        if [ -f "$dir/plugin.dylib" ] && [ "$(cat "$STAMPS/$id" 2>/dev/null)" = "$stamp" ]; then continue; fi
        swiftc -target arm64-apple-macos13 -O -emit-library -module-name "FSPlugin_${id//-/_}" -I "$MODULE" \
            "${sources[@]}" "$ROOT"/PluginKit/*.swift -o "$dir/plugin.dylib" -Xlinker -undefined -Xlinker dynamic_lookup
    fi
    printf '%s' "$stamp" > "$STAMPS/$id"
done

json() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
jsonlist() { local out="" a; for a in "$@"; do out+="${out:+,}$(json "$a")"; done; printf '%s' "$out"; }
SDK="$(xcrun --show-sdk-path)"
FIRST=1
emit() {
    local args="$1" f
    shift
    for f in "$@"; do
        [ "$FIRST" -eq 1 ] || printf ','
        FIRST=0
        printf '\n{"directory":%s,"file":%s,"arguments":[%s]}' "$(json "$ROOT")" "$(json "$f")" "$args"
    done
}
{
    printf '['
    emit "$(jsonlist swiftc -target arm64-apple-macos13 -sdk "$SDK" -enable-testing -module-name "$NAME" "$ROOT"/Sources/*.swift)" "$ROOT"/Sources/*.swift
    kit=("$ROOT"/PluginKit/*.swift)
    pending=("${kit[@]}")
    for dir in "$ROOT"/plugins/*/; do
        sources=("$dir"*.swift)
        [ -e "${sources[0]}" ] || continue
        id="$(basename "$dir")"
        emit "$(jsonlist swiftc -target arm64-apple-macos13 -sdk "$SDK" -module-name "FSPlugin_${id//-/_}" -I "$MODULE" "${sources[@]}" "${kit[@]}")" \
            "${sources[@]}" ${pending[@]+"${pending[@]}"}
        pending=()
    done
    printf '\n]\n'
} > "$ROOT/build/compile_commands.json"

progress "マニフェストと署名 (plugins/*/plugin.sig)"
swift "$ROOT/tools/manifest.swift" "$ROOT" >/dev/null
swift "$ROOT/tools/l10n-check.swift" "$ROOT" >/dev/null

progress "アイコン生成"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/data/pics/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ROOT/data/pics/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

progress "リソースと Info.plist"
cp "$ROOT/data/pics/interpolate.png" "$APP/Contents/Resources/interpolate.png"

if [ -n "${BUNDLE_PLUGINS:-}" ]; then
    BUNDLED="$APP/Contents/Resources/Plugins"
    mkdir -p "$BUNDLED"
    for dir in "$ROOT"/plugins/*/; do
        [ -f "$dir/plugin.json" ] || continue
        id="$(basename "$dir")"
        ditto "$dir" "$BUNDLED/$id"
        find "$BUNDLED/$id" -name '*.swift' -delete
    done
    date +%s > "$BUNDLED/.build-stamp"
fi

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
rm -rf "$STAGE" "$DMG" "$DMG.sig"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" 2> >(grep -v deprecated >&2) >/dev/null
rm -rf "$STAGE"
swift "$ROOT/tools/manifest.swift" --sign "$DMG"
progress "完了"

echo "Built $APP ($VERSION)"
echo "Built $DMG"
