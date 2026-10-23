#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${ASSETFRAME_DIST_DIR:-$ROOT_DIR/dist-macos}"
APP_NAME="向量·素仓"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SCRIPT_DIR/Info.plist")"
VERSION_TAG="V$BUILD_VERSION"
CHANGELOG_FILE="$SCRIPT_DIR/CHANGELOG.md"
STAGE_DIR="$(mktemp -d)"
APP_DIR="$STAGE_DIR/$APP_NAME.app"
VERIFY_DIR="$STAGE_DIR/verify"
ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION_TAG-macOS.zip"
CONTENTS="$APP_DIR/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
trap 'rm -rf "$STAGE_DIR"' EXIT

fail() {
    echo "$1" >&2
    exit 1
}

[[ -f "$CHANGELOG_FILE" ]] || fail "缺少更新日志：$CHANGELOG_FILE"
if ! grep -q "^## $VERSION_TAG" "$CHANGELOG_FILE"; then
    fail "缺少 $VERSION_TAG 更新日志：$CHANGELOG_FILE"
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

# 构建：默认 swift build。ASSETFRAME_BUILD_PRODUCTS_DIR 可直接复用已验证的
# 独立构建产物；ASSETFRAME_SWIFT_* 用于指定 SDK / 额外参数 / 独立 scratch 路径。
if [[ -n "${ASSETFRAME_BUILD_PRODUCTS_DIR:-}" ]]; then
    BIN_DIR="${ASSETFRAME_BUILD_PRODUCTS_DIR:A}"
    echo "复用已构建产物：$BIN_DIR"
else
    typeset -a SWIFT_BUILD_ARGS
    SWIFT_BUILD_ARGS=(-c release)
    [[ -n "${ASSETFRAME_SWIFT_SDK:-}" ]] && SWIFT_BUILD_ARGS+=(--sdk "$ASSETFRAME_SWIFT_SDK")
    if [[ -n "${ASSETFRAME_SWIFT_BUILD_FLAGS:-}" ]]; then
        SWIFT_BUILD_ARGS+=(${=ASSETFRAME_SWIFT_BUILD_FLAGS})
    fi
    [[ -n "${ASSETFRAME_SWIFT_SCRATCH_PATH:-}" ]] && SWIFT_BUILD_ARGS+=(--scratch-path "${ASSETFRAME_SWIFT_SCRATCH_PATH:A}")
    swift build "${SWIFT_BUILD_ARGS[@]}"
    BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
fi
[[ -x "$BIN_DIR/AssetFrame" ]] || fail "找不到构建产物：$BIN_DIR/AssetFrame"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$FRAMEWORKS"
cp "$BIN_DIR/AssetFrame" "$CONTENTS/MacOS/AssetFrame"
cp "Info.plist" "$CONTENTS/Info.plist"
cp "Resources/AssetFrame.icns" "$CONTENTS/Resources/AssetFrame.icns"
cp "CLI/assetframe" "$CONTENTS/Resources/assetframe-cli"
chmod +x "$CONTENTS/Resources/assetframe-cli"
chmod +x "$CONTENTS/MacOS/AssetFrame"

# 发布时注入更新源与公钥；本地打包保持 Info.plist 占位值不变。
if [[ -n "${ASSETFRAME_UPDATE_FEED_URL:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $ASSETFRAME_UPDATE_FEED_URL" "$CONTENTS/Info.plist"
fi
if [[ -n "${ASSETFRAME_SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $ASSETFRAME_SPARKLE_PUBLIC_ED_KEY" "$CONTENTS/Info.plist"
fi
if [[ -n "${ASSETFRAME_FEEDBACK_ENDPOINT:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :AFFeedbackEndpoint $ASSETFRAME_FEEDBACK_ENDPOINT" "$CONTENTS/Info.plist"
fi
plutil -lint "$CONTENTS/Info.plist" >/dev/null || fail "Info.plist 格式无效。"

# SwiftPM links Sparkle as a dynamic framework.  A standalone .app must embed
# that framework instead of relying on SwiftPM's build directory at runtime.
SPARKLE_FRAMEWORK=""
for candidate in \
    "$BIN_DIR/Sparkle.framework" \
    ".build/release/Sparkle.framework" \
    ".build/out/Products/Release/Sparkle.framework"
do
    if [[ -d "$candidate" ]]; then
        SPARKLE_FRAMEWORK="$candidate"
        break
    fi
done

# Retain compatibility with older SwiftPM layouts.
if [[ -z "$SPARKLE_FRAMEWORK" && -d ".build" ]]; then
    SPARKLE_FRAMEWORK="$(find ".build/" -path '*/release/Sparkle.framework' -type d -print -quit 2>/dev/null || true)"
fi
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "未找到 Sparkle.framework，无法生成可启动的 App。" >&2
    exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/AssetFrame"
SIGN_IDENTITY="${ASSETFRAME_SIGN_IDENTITY:--}"
clean_bundle_attributes "$APP_DIR"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
verify_bundle "$APP_DIR"

mkdir -p "$BUILD_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
mkdir -p "$VERIFY_DIR"
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
verify_bundle "$VERIFY_DIR/$APP_NAME.app"

# 便利拷贝为 best-effort：DSH/文件提供程序可能拦截批量删除，ZIP 已严格验签，
# 失败只提示，不影响发布产物。
if [[ "${ASSETFRAME_SKIP_APP_COPY:-0}" != "1" ]]; then
    OUTPUT_APP="$BUILD_DIR/$APP_NAME.app"
    if rm -rf "$OUTPUT_APP" 2>/dev/null && ditto "$APP_DIR" "$OUTPUT_APP" 2>/dev/null; then
        clean_bundle_attributes "$OUTPUT_APP"
        codesign -dv --verbose=2 "$OUTPUT_APP" >/dev/null 2>&1 || true
    else
        echo "提示：便利 App 拷贝未完成（ZIP 已通过严格校验，不影响发布）。" >&2
    fi
fi

shasum -a 256 "$ZIP_PATH"
echo "$ZIP_PATH"
