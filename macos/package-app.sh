#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="$ROOT_DIR/dist-macos"
APP_NAME="向量AI资产管家"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SCRIPT_DIR/Info.plist")"
VERSION_TAG="V$BUILD_VERSION"
CHANGELOG_FILE="$SCRIPT_DIR/CHANGELOG.md"
STAGE_DIR="$(mktemp -d)"
APP_DIR="$STAGE_DIR/$APP_NAME.app"
VERIFY_DIR="$STAGE_DIR/verify"
OUTPUT_APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
trap 'rm -rf "$STAGE_DIR"' EXIT

if ! grep -q "^## $VERSION_TAG" "$CHANGELOG_FILE"; then
    echo "缺少 $VERSION_TAG 更新日志：$CHANGELOG_FILE" >&2
    exit 1
fi

clean_bundle_attributes() {
    local bundle="$1"
    xattr -cr "$bundle"
    xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
    xattr -d com.apple.provenance "$bundle" 2>/dev/null || true
}

verify_bundle() {
    local bundle="$1"
    local attempt
    for attempt in 1 2 3 4 5; do
        clean_bundle_attributes "$bundle"
        if codesign --verify --deep --strict "$bundle" 2>/dev/null; then
            return 0
        fi
    done
    codesign --verify --deep --strict "$bundle"
}

cd "$SCRIPT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$FRAMEWORKS"
cp ".build/release/AssetFrame" "$CONTENTS/MacOS/AssetFrame"
cp "Info.plist" "$CONTENTS/Info.plist"
cp "Resources/AssetFrame.icns" "$CONTENTS/Resources/AssetFrame.icns"
cp "CLI/assetframe" "$CONTENTS/Resources/assetframe-cli"
chmod +x "$CONTENTS/Resources/assetframe-cli"
chmod +x "$CONTENTS/MacOS/AssetFrame"

# SwiftPM links Sparkle as a dynamic framework.  A standalone .app must embed
# that framework instead of relying on SwiftPM's build directory at runtime.
SPARKLE_FRAMEWORK=""
for candidate in \
    ".build/release/Sparkle.framework" \
    ".build/out/Products/Release/Sparkle.framework"
do
    if [[ -d "$candidate" ]]; then
        SPARKLE_FRAMEWORK="$candidate"
        break
    fi
done

# Retain compatibility with older SwiftPM layouts.
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    SPARKLE_FRAMEWORK="$(find .build -path '*/release/Sparkle.framework' -type d -print -quit)"
fi
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "未找到 Sparkle.framework，无法生成可启动的 App。" >&2
    exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/AssetFrame"
clean_bundle_attributes "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
verify_bundle "$APP_DIR"

mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR/$APP_NAME-$VERSION_TAG-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$BUILD_DIR/$APP_NAME-$VERSION_TAG-macOS.zip"
mkdir -p "$VERIFY_DIR"
ditto -x -k "$BUILD_DIR/$APP_NAME-$VERSION_TAG-macOS.zip" "$VERIFY_DIR"
verify_bundle "$VERIFY_DIR/$APP_NAME.app"

# Copy the verified staging bundle only after the ZIP is complete.
rm -rf "$OUTPUT_APP"
ditto "$APP_DIR" "$OUTPUT_APP"
clean_bundle_attributes "$OUTPUT_APP"
# iCloud/File Provider may immediately re-attach FinderInfo to bundles stored
# in Documents. The archive and its extracted app are strictly verified above;
# the copied app already carries the verified staging signature, so here we only
# assert that the convenience copy still contains that signature.
codesign -dv --verbose=2 "$OUTPUT_APP" >/dev/null 2>&1

echo "$OUTPUT_APP"
