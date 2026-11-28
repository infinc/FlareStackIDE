#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="$(grep -Eo 'static let apiVersion = [0-9]+' "$ROOT/Sources/NativePlugins.swift" | grep -Eo '[0-9]+$')"
TAG="plugins-api$API"
command -v gh >/dev/null || { echo "gh が見つかりません" >&2; exit 1; }

if ! gh release view "$TAG" >/dev/null 2>&1; then
    gh release create "$TAG" --title "Plugins (apiVersion $API)" --notes "Swift プラグインの plugin.dylib（apiVersion $API）" --latest=false
fi
existing="$(gh api "repos/{owner}/{repo}/releases/tags/$TAG" --jq '.assets[] | "\(.name) \(.digest // "")"')"

uploads=()
for manifest in "$ROOT"/plugins/*/plugin.json; do
    dir="$(dirname "$manifest")"
    id="$(basename "$dir")"
    grep -q '"binary": *"release"' "$manifest" || continue
    [ -f "$dir/plugin.dylib" ] || { echo "$id/plugin.dylib がありません" >&2; exit 1; }
    version="$(grep -Eo '"version": *"[^"]+"' "$manifest" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
    name="$id-$version.dylib"
    digest="sha256:$(shasum -a 256 "$dir/plugin.dylib" | cut -d' ' -f1)"
    grep -qx "$name $digest" <<<"$existing" && continue
    mkdir -p "$ROOT/build/plugins-dist"
    cp "$dir/plugin.dylib" "$ROOT/build/plugins-dist/$name"
    uploads+=("$ROOT/build/plugins-dist/$name")
done

if [ ${#uploads[@]} -eq 0 ]; then
    echo "アップロードする plugin.dylib はありません（$TAG）"
    exit 0
fi
gh release upload "$TAG" "${uploads[@]}" --clobber
echo "${#uploads[@]} 個の plugin.dylib を $TAG にアップロードしました"
