#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SCRIPT_DIR/Info.plist")"
ZIP_PATH="${1:-${SCRIPT_DIR:h}/dist-macos/向量AI资产管家-V${BUILD_VERSION}-macOS.zip}"

if [[ ! -f "$ZIP_PATH" ]]; then
    echo "发布包不存在：$ZIP_PATH" >&2
    exit 2
fi

VERIFY_ROOT="$(mktemp -d /tmp/assetframe-release-verify.XXXXXX)"
trap 'rm -rf "$VERIFY_ROOT"' EXIT
ditto -x -k "$ZIP_PATH" "$VERIFY_ROOT"
APP_PATH="$(find "$VERIFY_ROOT" -maxdepth 2 -type d -name '*.app' -print -quit)"

if [[ -z "$APP_PATH" ]]; then
    echo "ZIP 中没有 .app：$ZIP_PATH" >&2
    exit 3
fi

ARCHIVE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
if [[ "$ARCHIVE_BUILD" != "$BUILD_VERSION" ]]; then
    echo "发布包版本不一致：源码 $BUILD_VERSION，ZIP $ARCHIVE_BUILD" >&2
    exit 4
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Release ZIP verification passed: V$ARCHIVE_BUILD"
shasum -a 256 "$ZIP_PATH"
