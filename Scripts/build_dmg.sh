#!/bin/bash

set -euo pipefail

# DeepSeek Web 免证书 ARM64 测试版 DMG 构建脚本。
# 只打包 Swift 启动器和视觉资源，严禁复制 Node、npm、dsh 或 node_modules。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/Sources/DeepSeekWeb"
TEST_DIR="$PROJECT_ROOT/Tests"
RESOURCE_DIR="$PROJECT_ROOT/Resources"
CONFIG_DIR="$PROJECT_ROOT/Config"
DOCS_DIR="$PROJECT_ROOT/Docs"
APP_NAME="DeepSeek Web"
VERSION="1.1.0"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
BUILD_ROOT="$(mktemp -d /private/tmp/dsh-web-dmg.XXXXXX)"
APP_PATH="$BUILD_ROOT/$APP_NAME.app"
VOLUME_DIR="$BUILD_ROOT/volume"
DIST_DIR="$PROJECT_ROOT/dist"
DMG_PATH="$DIST_DIR/DeepSeek-Web-$VERSION-macOS26-arm64.dmg"
SHA_PATH="$DIST_DIR/DeepSeek-Web-$VERSION-macOS26-arm64.sha256"

cleanup() {
    rm -rf "${BUILD_ROOT:?}"
}
trap cleanup EXIT

if [[ ! -d "$SDK_PATH" ]]; then
    echo "缺少构建 SDK：$SDK_PATH" >&2
    exit 1
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$VOLUME_DIR" "$DIST_DIR"

# 先运行隔离环境检测测试；测试文件不会进入应用包或 DMG。
CLANG_MODULE_CACHE_PATH=/private/tmp/dsh-clang-cache \
SWIFT_MODULE_CACHE_PATH=/private/tmp/dsh-swift-cache \
xcrun swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -D RUNTIME_LOCATOR_TEST \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx26.0 \
    -o "$BUILD_ROOT/runtime-locator-tests" \
    "$SOURCE_DIR/DshWebBar.swift" \
    "$TEST_DIR/RuntimeLocatorTests.swift"
"$BUILD_ROOT/runtime-locator-tests"

CLANG_MODULE_CACHE_PATH=/private/tmp/dsh-clang-cache \
SWIFT_MODULE_CACHE_PATH=/private/tmp/dsh-swift-cache \
xcrun swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx26.0 \
    -o "$APP_PATH/Contents/MacOS/dsh-web-bar" \
    "$SOURCE_DIR/DshWebBar.swift"

cp "$CONFIG_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$RESOURCE_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$RESOURCE_DIR/whale-white.svg" "$APP_PATH/Contents/Resources/whale.svg"

codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"

if [[ "$(file "$APP_PATH/Contents/MacOS/dsh-web-bar")" != *"arm64"* ]]; then
    echo "错误：应用不是 ARM64 架构。" >&2
    exit 1
fi

if find "$APP_PATH" -type d -name node_modules -print -quit | grep -q .; then
    echo "错误：应用包内发现 node_modules。" >&2
    exit 1
fi

if find "$APP_PATH/Contents/Resources" \( -name node -o -name npm -o -name dsh \) -print -quit | grep -q .; then
    echo "错误：资源目录内发现禁止打包的运行时或 Harness。" >&2
    exit 1
fi

cp -R "$APP_PATH" "$VOLUME_DIR/$APP_NAME.app"
ln -s /Applications "$VOLUME_DIR/Applications"
cp "$DOCS_DIR/安装说明.txt" "$VOLUME_DIR/安装说明.txt"

rm -f "$DMG_PATH" "$SHA_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$VOLUME_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

(
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$SHA_PATH")"
)

echo "构建完成："
echo "$DMG_PATH"
echo "$SHA_PATH"
