#!/usr/bin/env bash
#
# 编译并打包“窗口复位器”为 .app（无需 Xcode）。
# 用法：./build.sh
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR"

APP_NAME="窗口复位器"
EXEC_NAME="WindowResizer"
BUNDLE_ID="com.example.WindowResizer"
VERSION="1.0"
BUILD_VERSION="1"
MIN_OS="13.0"
# 按本机 CPU 架构编译（Apple Silicon = arm64，Intel = x86_64）。
TARGET_ARCH="$(uname -m)"

BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

FRAMEWORKS="-framework AppKit -framework SwiftUI -framework CoreGraphics -framework ApplicationServices -framework ServiceManagement"

echo "==> 编译 Swift 源文件（$TARGET_ARCH，macOS $MIN_OS+）"
mkdir -p "$BUILD_DIR"
swiftc -O -target "$TARGET_ARCH-apple-macosx$MIN_OS" $FRAMEWORKS "$SRC_DIR"/*.swift -o "$BUILD_DIR/$EXEC_NAME"

echo "==> 组装 .app 包"
# 覆盖式组装：只替换包内的可执行文件与 Info.plist。
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
mv -f "$BUILD_DIR/$EXEC_NAME" "$MACOS_DIR/$EXEC_NAME"

# 将 Info.plist 中的 Xcode 变量替换为实际值（单引号内避免被 shell 当作命令替换）
sed -e 's/$(EXECUTABLE_NAME)/'"$EXEC_NAME"'/g' \
    -e 's/$(PRODUCT_NAME)/'"$EXEC_NAME"'/g' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/'"$BUNDLE_ID"'/g' \
    -e 's/$(MARKETING_VERSION)/'"$VERSION"'/g' \
    -e 's/$(CURRENT_PROJECT_VERSION)/'"$BUILD_VERSION"'/g' \
    -e 's/$(MACOSX_DEPLOYMENT_TARGET)/'"$MIN_OS"'/g' \
    "$SRC_DIR/Info.plist" > "$CONTENTS/Info.plist"

# 优先使用本地自签名证书（身份稳定，TCC 不会每次重新要授权）；否则回退 ad-hoc。
CODE_SIGN_IDENTITY="WindowResetterSigning"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CODE_SIGN_IDENTITY"; then
    echo "==> 签名（使用本地证书 $CODE_SIGN_IDENTITY，身份稳定）"
    codesign --force --deep --sign "$CODE_SIGN_IDENTITY" "$APP_DIR"
else
    echo "==> 签名（ad-hoc；如需避免反复授权，请先创建本地证书 WindowResetterSigning）"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "==> 完成：$APP_DIR"
echo "    首次运行后，请到 系统设置 › 隐私与安全性 › 辅助功能 中授权本应用。"
