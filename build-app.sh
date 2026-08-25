#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/StudyLock.app"
CACHE_DIR="$ROOT_DIR/.build/ModuleCache"
ICON_TOOL="$ROOT_DIR/.build/generate-icon"

mkdir -p "$CACHE_DIR" "$BUILD_DIR"

# macOS 26 SDK 起 SwiftUI 的 @State 等改成了宏,编译需要 libSwiftUIMacros.dylib。
# 这个插件只随完整 Xcode 分发,Command Line Tools 里没有——只装 CLT 会报一堆
# 「cannot find '$xxx' in scope」,根源其实是 "plugin for module 'SwiftUIMacros' not found"。
# 当前工具链缺插件时自动改用已装的 Xcode。
has_swiftui_macros() {
    [[ -f "$1/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]] \
        || [[ -f "$1/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]
}

if ! has_swiftui_macros "${DEVELOPER_DIR:-$(xcode-select -p)}"; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if has_swiftui_macros "$candidate/Contents/Developer"; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            echo "当前工具链缺 SwiftUIMacros,改用: $DEVELOPER_DIR"
            break
        fi
    done
fi

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp ".build/release/StudyLock" "$APP_DIR/Contents/MacOS/StudyLock"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

swiftc \
    -module-cache-path "$CACHE_DIR" \
    "Tools/GenerateIcon.swift" \
    -o "$ICON_TOOL" \
    -framework AppKit
"$ICON_TOOL" "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR"
