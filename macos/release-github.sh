#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
APP_NAME="向量AI资产管家"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SCRIPT_DIR/Info.plist")"
VERSION_TAG="V$BUILD_VERSION"
GITHUB_REPOSITORY="${ASSETFRAME_GITHUB_REPOSITORY:-yidiandianzheng/assetframe-updates}"
RELEASE_MODE="${ASSETFRAME_GITHUB_RELEASE_MODE:-test}"
KEY_ACCOUNT="${ASSETFRAME_EDDSA_KEY_ACCOUNT:-assetframe-github}"
CACHE_ROOT="${ASSETFRAME_CACHE_ROOT:-$HOME/Library/Caches/AssetFrame}"
VERIFIED_APP="$CACHE_ROOT/VerifiedApp/$APP_NAME.app"
LOCAL_ARCHIVE="$ROOT_DIR/dist-macos/$APP_NAME-$VERSION_TAG-macOS.zip"
RELEASE_STEM="AssetFrame-$VERSION_TAG-macOS"
RELEASE_ARCHIVE="$RELEASE_STEM.zip"
RELEASE_NOTES="$RELEASE_STEM.md"
RELEASE_DIR="$(mktemp -d /tmp/assetframe-github-release.XXXXXX)"
SPARKLE_BIN="$CACHE_ROOT/PackageBuild/.build-arm64/artifacts/sparkle/Sparkle/bin"
FEED_URL="https://github.com/$GITHUB_REPOSITORY/releases/latest/download/appcast.xml"
VERSION_BASE_URL="https://github.com/$GITHUB_REPOSITORY/releases/download/$VERSION_TAG/"
trap 'rm -rf "$RELEASE_DIR"' EXIT

fail() {
    echo "$1" >&2
    exit 1
}

[[ "$RELEASE_MODE" == "test" || "$RELEASE_MODE" == "production" ]] \
    || fail "ASSETFRAME_GITHUB_RELEASE_MODE 只能是 test 或 production。"
command -v gh >/dev/null || fail "缺少 GitHub CLI（gh）。"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI 尚未登录。"
gh repo view "$GITHUB_REPOSITORY" >/dev/null 2>&1 || fail "找不到 GitHub 更新仓库：$GITHUB_REPOSITORY"
[[ -x "$SPARKLE_BIN/generate_keys" && -x "$SPARKLE_BIN/generate_appcast" ]] \
    || fail "缺少 Sparkle 发布工具；请先执行 package-app.sh。"
[[ ! -e "$RELEASE_DIR/private-key" ]] || fail "临时目录中不应存在私钥文件。"

if gh release view "$VERSION_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    fail "GitHub Release $VERSION_TAG 已存在。版本发布后不可覆盖，请先提升构建号。"
fi

PUBLIC_KEY="${ASSETFRAME_SPARKLE_PUBLIC_ED_KEY:-$($SPARKLE_BIN/generate_keys --account "$KEY_ACCOUNT" -p)}"
[[ -n "$PUBLIC_KEY" && "$PUBLIC_KEY" != REPLACE_WITH_* ]] || fail "Sparkle EdDSA 公钥无效。"

SIGN_IDENTITY="${ASSETFRAME_SIGN_IDENTITY:--}"
if [[ "$RELEASE_MODE" == "production" ]]; then
    [[ -n "${ASSETFRAME_SIGN_IDENTITY:-}" ]] || fail "正式发布缺少 ASSETFRAME_SIGN_IDENTITY。"
    [[ -n "${ASSETFRAME_NOTARY_PROFILE:-}" ]] || fail "正式发布缺少 ASSETFRAME_NOTARY_PROFILE。"
    [[ -d /Applications/Xcode.app ]] || fail "正式发布需要完整 Xcode。"
    security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY" \
        || fail "钥匙串中没有指定的 Developer ID 签名身份。"
else
    SIGN_IDENTITY="-"
    echo "邀请测试模式：安装包使用临时签名；首次安装可能需要在系统设置中手动允许。"
fi

"$SCRIPT_DIR/run-self-tests.sh"
ASSETFRAME_SIGN_IDENTITY="$SIGN_IDENTITY" \
ASSETFRAME_UPDATE_FEED_URL="$FEED_URL" \
ASSETFRAME_SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
ASSETFRAME_FEEDBACK_ENDPOINT="${ASSETFRAME_FEEDBACK_ENDPOINT:-REPLACE_WITH_FEEDBACK_ENDPOINT}" \
ASSETFRAME_SKIP_INSTALL=1 \
    "$SCRIPT_DIR/package-app.sh"

[[ -f "$LOCAL_ARCHIVE" && -d "$VERIFIED_APP" ]] || fail "构建产物不完整。"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$VERIFIED_APP/Contents/Info.plist")" == "$BUILD_VERSION" ]] \
    || fail "应用构建号与发布标签不一致。"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$VERIFIED_APP/Contents/Info.plist")" == "$FEED_URL" ]] \
    || fail "应用未写入 GitHub appcast 地址。"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$VERIFIED_APP/Contents/Info.plist")" == "$PUBLIC_KEY" ]] \
    || fail "应用未写入 Sparkle EdDSA 公钥。"
codesign --verify --deep --strict --verbose=2 "$VERIFIED_APP"

if [[ "$RELEASE_MODE" == "production" ]]; then
    SIGN_DETAILS="$(codesign -dv --verbose=4 "$VERIFIED_APP" 2>&1)"
    [[ "$SIGN_DETAILS" == *"Authority=Developer ID Application"* && "$SIGN_DETAILS" == *"runtime"* ]] \
        || fail "应用未使用 Developer ID Application + Hardened Runtime 签名。"
    xcrun notarytool submit "$LOCAL_ARCHIVE" --keychain-profile "$ASSETFRAME_NOTARY_PROFILE" --wait
    xcrun stapler staple "$VERIFIED_APP"
    xcrun stapler validate "$VERIFIED_APP"
    codesign --verify --deep --strict --verbose=2 "$VERIFIED_APP"
    spctl --assess --type execute --verbose=2 "$VERIFIED_APP"
    rm -f "$LOCAL_ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$VERIFIED_APP" "$LOCAL_ARCHIVE"
fi

cp "$LOCAL_ARCHIVE" "$RELEASE_DIR/$RELEASE_ARCHIVE"
awk -v version="$VERSION_TAG" '
    index($0, "## " version) == 1 { capture=1; next }
    capture && /^## / { exit }
    capture { print }
' "$SCRIPT_DIR/CHANGELOG.md" > "$RELEASE_DIR/$RELEASE_NOTES"
[[ -s "$RELEASE_DIR/$RELEASE_NOTES" ]] || fail "缺少 $VERSION_TAG 更新说明。"

# 复用当前公开 appcast，保留最多三个历史版本；首次发布时不存在是正常情况。
curl -fsSL "$FEED_URL" -o "$RELEASE_DIR/appcast.xml" 2>/dev/null || true
GENERATE_ARGS=(
    --account "$KEY_ACCOUNT"
    --download-url-prefix "$VERSION_BASE_URL"
    --release-notes-url-prefix "$VERSION_BASE_URL"
    --link "https://github.com/$GITHUB_REPOSITORY/releases"
    --versions "$BUILD_VERSION"
    --maximum-versions 3
    -o "$RELEASE_DIR/appcast.xml"
)
"$SPARKLE_BIN/generate_appcast" "${GENERATE_ARGS[@]}" "$RELEASE_DIR"
xmllint --noout "$RELEASE_DIR/appcast.xml"
grep -q 'sparkle:edSignature=' "$RELEASE_DIR/appcast.xml" \
    || fail "appcast 缺少 Sparkle EdDSA 签名。"
grep -Fq "$VERSION_BASE_URL$RELEASE_ARCHIVE" "$RELEASE_DIR/appcast.xml" \
    || fail "appcast 下载地址不正确。"

RELEASE_BODY="$RELEASE_DIR/release-body.md"
{
    echo "邀请测试版 macOS 安装包。"
    echo
    echo "首次安装：解压 ZIP，将应用拖入“应用程序”。未办理 Apple 公证前，macOS 可能要求在“系统设置 → 隐私与安全性”中允许打开。"
    echo
    cat "$RELEASE_DIR/$RELEASE_NOTES"
} > "$RELEASE_BODY"

# 先创建草稿并上传全部资产，最后公开；latest/appcast.xml 不会提前指向半成品。
gh release create "$VERSION_TAG" \
    --repo "$GITHUB_REPOSITORY" \
    --title "$APP_NAME $VERSION_TAG" \
    --notes-file "$RELEASE_BODY" \
    --draft
gh release upload "$VERSION_TAG" \
    "$RELEASE_DIR/$RELEASE_ARCHIVE" \
    "$RELEASE_DIR/$RELEASE_NOTES" \
    "$RELEASE_DIR/appcast.xml" \
    "$RELEASE_DIR"/*.delta(N) \
    --repo "$GITHUB_REPOSITORY"
gh release edit "$VERSION_TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest

# GitHub 的 releases/latest CDN 在新 Release 公开后可能短暂返回上一版。
# 使用无缓存查询重试，避免把正常的传播延迟误报成发布失败。
PUBLISHED_APPCAST_VERIFIED=0
for attempt in {1..8}; do
    if curl --max-time 30 -fsSL -H 'Cache-Control: no-cache' \
        "$FEED_URL?version=$VERSION_TAG&attempt=$attempt" \
        -o "$RELEASE_DIR/published-appcast.xml" \
        && xmllint --noout "$RELEASE_DIR/published-appcast.xml" \
        && grep -Fq "$VERSION_BASE_URL$RELEASE_ARCHIVE" "$RELEASE_DIR/published-appcast.xml"; then
        PUBLISHED_APPCAST_VERIFIED=1
        break
    fi
    sleep 5
done
[[ "$PUBLISHED_APPCAST_VERIFIED" == "1" ]] || fail "GitHub latest appcast 发布后校验失败。"

echo "已发布：https://github.com/$GITHUB_REPOSITORY/releases/tag/$VERSION_TAG"
echo "更新源：$FEED_URL"
echo "Sparkle 公钥：$PUBLIC_KEY"
