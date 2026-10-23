#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SCRIPT_DIR/Info.plist")"
ZIP_PATH="${SCRIPT_DIR:h}/dist-macos/向量·素仓-V${BUILD_VERSION}-macOS.zip"

cd "$SCRIPT_DIR"
typeset -a SWIFT_BUILD_ARGS
SWIFT_BUILD_ARGS=(-c release)
[[ -n "${ASSETFRAME_SWIFT_SDK:-}" ]] && SWIFT_BUILD_ARGS+=(--sdk "$ASSETFRAME_SWIFT_SDK")
if [[ -n "${ASSETFRAME_SWIFT_BUILD_FLAGS:-}" ]]; then
    SWIFT_BUILD_ARGS+=(${=ASSETFRAME_SWIFT_BUILD_FLAGS})
fi
swift build "${SWIFT_BUILD_ARGS[@]}"
./run-self-tests.sh
./package-app.sh
./verify-release-zip.sh "$ZIP_PATH"
./run-isolated-ui-smoke.sh --automated "$ZIP_PATH"

echo "AssetFrame release gate passed: V$BUILD_VERSION"
