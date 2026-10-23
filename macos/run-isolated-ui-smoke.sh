#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SCRIPT_DIR/Info.plist")"
ZIP_PATH="${SCRIPT_DIR:h}/dist-macos/向量·素仓-V${BUILD_VERSION}-macOS.zip"
QA_CHECKLIST="ProductValidation/V${BUILD_VERSION}_隔离QA验收清单.md"
AUTOMATED=0

for argument in "$@"; do
    case "$argument" in
        --automated) AUTOMATED=1 ;;
        *.zip) ZIP_PATH="$argument" ;;
        *) echo "未知参数：$argument" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$ZIP_PATH" ]]; then
    echo "发布包不存在：$ZIP_PATH" >&2
    exit 3
fi

EXTRACT_ROOT="$(mktemp -d /tmp/assetframe-ui-package.XXXXXX)"
QA_ROOT="$(mktemp -d /tmp/assetframe-qa.XXXXXX)"
LOG_PATH="$QA_ROOT/launch.log"
APP_PID=""

cleanup() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -rf "$EXTRACT_ROOT"
    if [[ "${ASSETFRAME_QA_KEEP:-0}" != "1" ]]; then
        rm -rf "$QA_ROOT"
    fi
}
trap cleanup EXIT

ditto -x -k "$ZIP_PATH" "$EXTRACT_ROOT"
APP_PATH="$(find "$EXTRACT_ROOT" -maxdepth 2 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
    echo "ZIP 中没有 .app" >&2
    exit 4
fi
codesign --verify --deep --strict "$APP_PATH"

ASSETFRAME_QA_DATA_ROOT="$QA_ROOT" "$APP_PATH/Contents/MacOS/AssetFrame" >"$LOG_PATH" 2>&1 &
APP_PID=$!

if [[ "$AUTOMATED" == "1" ]]; then
    sleep 5
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "隔离启动失败，日志：$LOG_PATH" >&2
        sed -n '1,160p' "$LOG_PATH" >&2
        exit 5
    fi
    echo "Isolated UI launch smoke passed: V$BUILD_VERSION"
    exit 0
fi

echo "已使用隔离数据根启动 V$BUILD_VERSION"
echo "QA 数据：$QA_ROOT"
echo "日志：$LOG_PATH"
echo "请按 $QA_CHECKLIST 走查；关闭 App 后脚本结束。"
wait "$APP_PID"
APP_PID=""
