#!/usr/bin/env bash
#
# 编译并打包“窗口复位器”为 .app（无需 Xcode）。
# 用法：
#   ./build.sh               按本机 CPU 架构编译（日常开发，最快）
#   ./build.sh --universal   编译 Universal 双架构（arm64 + x86_64，发布用）
#
# 环境变量（可选，发布用）：
#   SIGN_IDENTITY="Developer ID Application: 姓名 (TEAMID)"
#     指定后改用该证书签名，并启用 Hardened Runtime + 安全时间戳，
#     以满足 Apple 公证的前置要求；不设置时行为与旧版完全一致。
#
set -eo pipefail

ARCH_MODE="native"
for arg in "$@"; do
    case "$arg" in
        --universal) ARCH_MODE="universal" ;;
        -h|--help)
            echo "用法：./build.sh [--universal]"
            echo "  --universal  编译 arm64 + x86_64 双架构（发布用）"
            exit 0 ;;
        *)
            echo "未知参数：$arg（可用：--universal、-h）" >&2
            exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR"

APP_NAME="窗口复位器"
EXEC_NAME="WindowResizer"
BUNDLE_ID="com.example.WindowResizer"
VERSION="1.1.0"
BUILD_VERSION="2"
MIN_OS="13.0"
# native 模式按本机 CPU 架构编译；universal 模式分别编两个架构再合并。
TARGET_ARCH="$(uname -m)"

BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

FRAMEWORKS="-framework AppKit -framework SwiftUI -framework CoreGraphics -framework ApplicationServices -framework ServiceManagement"

mkdir -p "$BUILD_DIR"
if [ "$ARCH_MODE" = "universal" ]; then
    echo "==> 编译 Swift 源文件（Universal: arm64 + x86_64，macOS $MIN_OS+）"
    # 中间产物放在 build/.universal/（已被 .gitignore 忽略），每次构建覆盖复用，不做删除。
    LIPO_TMP="$BUILD_DIR/.universal"
    mkdir -p "$LIPO_TMP"
    ARM64_BIN="$LIPO_TMP/arm64"
    X86_BIN="$LIPO_TMP/x86_64"
    swiftc -O -target "arm64-apple-macosx$MIN_OS" $FRAMEWORKS "$SRC_DIR"/*.swift -o "$ARM64_BIN"
    swiftc -O -target "x86_64-apple-macosx$MIN_OS" $FRAMEWORKS "$SRC_DIR"/*.swift -o "$X86_BIN"
    lipo -create -output "$BUILD_DIR/$EXEC_NAME" "$ARM64_BIN" "$X86_BIN"
    echo "==> $(lipo -info "$BUILD_DIR/$EXEC_NAME")"
else
    echo "==> 编译 Swift 源文件（$TARGET_ARCH，macOS $MIN_OS+）"
    swiftc -O -target "$TARGET_ARCH-apple-macosx$MIN_OS" $FRAMEWORKS "$SRC_DIR"/*.swift -o "$BUILD_DIR/$EXEC_NAME"
fi

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

# 签名优先级：
#   1) SIGN_IDENTITY（发布用，Developer ID）→ Hardened Runtime + 安全时间戳，供 Apple 公证
#   2) 本地自签证书 WindowResetterSigning（日常开发，身份稳定，TCC 不会反复要授权）
#   3) ad-hoc 签名（兜底）
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> 签名（Developer ID：$SIGN_IDENTITY；Hardened Runtime + 安全时间戳）"
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "WindowResetterSigning"; then
    echo "==> 签名（使用本地证书 WindowResetterSigning，身份稳定）"
    codesign --force --deep --sign "WindowResetterSigning" "$APP_DIR"
else
    echo "==> 签名（ad-hoc；如需避免反复授权，请先创建本地证书 WindowResetterSigning）"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "==> 完成：$APP_DIR"
echo "    首次运行后，请到 系统设置 › 隐私与安全性 › 辅助功能 中授权本应用。"
