#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SCRIPT_DIR/Info.plist")"
ZIP_PATH="${SCRIPT_DIR:h}/dist-macos/向量AI资产管家-V${BUILD_VERSION}-macOS.zip"

cd "$SCRIPT_DIR"
swift build -c release
./run-self-tests.sh
./package-app.sh
./verify-release-zip.sh "$ZIP_PATH"
./run-isolated-ui-smoke.sh --automated "$ZIP_PATH"

echo "AssetFrame release gate passed: V$BUILD_VERSION"
