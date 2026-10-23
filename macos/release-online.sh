#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CLOUD_DIR="$ROOT_DIR/cloud/assetframe-online"
APP_NAME="向量AI资产管家"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SCRIPT_DIR/Info.plist")"
VERSION_TAG="V$BUILD_VERSION"
CACHE_ROOT="${ASSETFRAME_CACHE_ROOT:-$HOME/Library/Caches/AssetFrame}"
VERIFIED_APP="$CACHE_ROOT/VerifiedApp/$APP_NAME.app"
ARCHIVE_NAME="$APP_NAME-$VERSION_TAG-macOS.zip"
ARCHIVE="$ROOT_DIR/dist-macos/$ARCHIVE_NAME"
RELEASE_DIR="$(mktemp -d /tmp/assetframe-release.XXXXXX)"
WRANGLER="$CLOUD_DIR/node_modules/.bin/wrangler"
trap 'rm -rf "$RELEASE_DIR"' EXIT

required_variables=(
    ASSETFRAME_SIGN_IDENTITY
    ASSETFRAME_NOTARY_PROFILE
    ASSETFRAME_UPDATE_FEED_URL
    ASSETFRAME_SPARKLE_PUBLIC_ED_KEY
    ASSETFRAME_FEEDBACK_ENDPOINT
    ASSETFRAME_RELEASE_BASE_URL
    ASSETFRAME_R2_UPDATES_BUCKET
)
for variable_name in "${required_variables[@]}"; do
    if [[ -z "${(P)variable_name:-}" ]]; then
        echo "缺少发布变量：$variable_name" >&2
        exit 1
    fi
done
for service_url in "$ASSETFRAME_UPDATE_FEED_URL" "$ASSETFRAME_FEEDBACK_ENDPOINT" "$ASSETFRAME_RELEASE_BASE_URL"; do
    if [[ "$service_url" != https://* ]]; then
        echo "正式发布地址必须使用 HTTPS：$service_url" >&2
        exit 1
    fi
done
if [[ "$ASSETFRAME_SPARKLE_PUBLIC_ED_KEY" == REPLACE_WITH_* ]]; then
    echo "Sparkle 公钥仍是占位值。" >&2
    exit 1
fi
if [[ -z "${ASSETFRAME_EDDSA_KEY_FILE:-}" && -z "${ASSETFRAME_EDDSA_KEY_ACCOUNT:-}" ]]; then
    echo "必须配置 ASSETFRAME_EDDSA_KEY_FILE 或 ASSETFRAME_EDDSA_KEY_ACCOUNT。" >&2
    exit 1
fi
if [[ ! -d /Applications/Xcode.app ]]; then
    echo "未安装完整 Xcode，不能执行公证发布。" >&2
    exit 1
fi
if [[ ! -x "$WRANGLER" ]]; then
    echo "缺少锁定版本的 Wrangler；请先在 cloud/assetframe-online 执行 npm ci。" >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -Fq "$ASSETFRAME_SIGN_IDENTITY"; then
    echo "钥匙串中没有指定的 Developer ID 签名身份。" >&2
    exit 1
fi
RELEASE_BASE_URL="${ASSETFRAME_RELEASE_BASE_URL%/}"

"$SCRIPT_DIR/run-self-tests.sh"
(cd "$CLOUD_DIR" && npm test)
if [[ -f "$CLOUD_DIR/wrangler.toml" ]]; then
    "$WRANGLER" deploy --dry-run --config "$CLOUD_DIR/wrangler.toml"
else
    echo "缺少 cloud/assetframe-online/wrangler.toml，不能执行正式发布。" >&2
    exit 1
fi
ASSETFRAME_SKIP_INSTALL=1 "$SCRIPT_DIR/package-app.sh"
SIGN_DETAILS="$(codesign -dv --verbose=4 "$VERIFIED_APP" 2>&1)"
if [[ "$SIGN_DETAILS" != *"Authority=Developer ID Application"* || "$SIGN_DETAILS" != *"runtime"* ]]; then
    echo "应用未使用 Developer ID Application + Hardened Runtime 签名。" >&2
    exit 1
fi

xcrun notarytool submit "$ARCHIVE" --keychain-profile "$ASSETFRAME_NOTARY_PROFILE" --wait
xcrun stapler staple "$VERIFIED_APP"
xcrun stapler validate "$VERIFIED_APP"
codesign --verify --deep --strict --verbose=2 "$VERIFIED_APP"
spctl --assess --type execute --verbose=2 "$VERIFIED_APP"
ARCHS="$(lipo -archs "$VERIFIED_APP/Contents/MacOS/AssetFrame")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]]

# 公证票据装订后重新生成最终 ZIP，确保用户拿到的归档包含 ticket。
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$VERIFIED_APP" "$ARCHIVE"
cp "$ARCHIVE" "$RELEASE_DIR/$ARCHIVE_NAME"
awk -v version="$VERSION_TAG" '
    index($0, "## " version) == 1 { capture=1; next }
    capture && /^## / { exit }
    capture { print }
' "$SCRIPT_DIR/CHANGELOG.md" > "$RELEASE_DIR/${ARCHIVE_NAME%.zip}.md"

SPARKLE_BIN="$CACHE_ROOT/PackageBuild/.build-arm64/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
    echo "缺少 Sparkle generate_appcast。请先在 macos 目录完成 swift package resolve。" >&2
    exit 1
fi

# 复用远端 appcast 可保留旧版本条目；首次发布时对象不存在是正常情况。
"$WRANGLER" r2 object get "$ASSETFRAME_R2_UPDATES_BUCKET/feeds/stable/appcast.xml" \
    --file "$RELEASE_DIR/appcast.xml" --remote >/dev/null 2>&1 || true

GENERATE_ARGS=(
    --download-url-prefix "$RELEASE_BASE_URL/releases/$VERSION_TAG/"
    --release-notes-url-prefix "$RELEASE_BASE_URL/releases/$VERSION_TAG/"
    --versions "$BUILD_VERSION"
    -o "$RELEASE_DIR/appcast.xml"
)
if [[ -n "${ASSETFRAME_EDDSA_KEY_FILE:-}" ]]; then
    GENERATE_ARGS+=(--ed-key-file "$ASSETFRAME_EDDSA_KEY_FILE")
else
    GENERATE_ARGS+=(--account "$ASSETFRAME_EDDSA_KEY_ACCOUNT")
fi
"$SPARKLE_BIN/generate_appcast" "${GENERATE_ARGS[@]}" "$RELEASE_DIR"
xmllint --noout "$RELEASE_DIR/appcast.xml"
if ! grep -q 'sparkle:edSignature=' "$RELEASE_DIR/appcast.xml"; then
    echo "appcast 缺少 Sparkle EdDSA 签名，停止发布。" >&2
    exit 1
fi
if ! grep -Fq "/releases/$VERSION_TAG/" "$RELEASE_DIR/appcast.xml"; then
    echo "appcast 的不可变版本路径不正确，停止发布。" >&2
    exit 1
fi

# 版本文件先上传；稳定 appcast 最后发布，避免客户端看到不完整版本。
"$WRANGLER" r2 object put "$ASSETFRAME_R2_UPDATES_BUCKET/releases/$VERSION_TAG/$ARCHIVE_NAME" \
    --file "$RELEASE_DIR/$ARCHIVE_NAME" --content-type application/zip --remote
"$WRANGLER" r2 object put "$ASSETFRAME_R2_UPDATES_BUCKET/releases/$VERSION_TAG/${ARCHIVE_NAME%.zip}.md" \
    --file "$RELEASE_DIR/${ARCHIVE_NAME%.zip}.md" --content-type text/markdown --remote
for delta in "$RELEASE_DIR"/*.delta(N); do
    "$WRANGLER" r2 object put "$ASSETFRAME_R2_UPDATES_BUCKET/releases/$VERSION_TAG/${delta:t}" \
        --file "$delta" --content-type application/octet-stream --remote
done
"$WRANGLER" r2 object put "$ASSETFRAME_R2_UPDATES_BUCKET/feeds/stable/appcast.xml" \
    --file "$RELEASE_DIR/appcast.xml" --content-type application/xml --remote

echo "已发布 $VERSION_TAG；appcast 是本次流程最后上传的对象。"
