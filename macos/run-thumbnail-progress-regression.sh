#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-thumbnail-progress.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    "$SCRIPT_DIR/Sources/AssetFrame/ThumbnailLoadProgressModel.swift" \
    "$SCRIPT_DIR/SelfTests/ThumbnailLoadProgressSelfTest.swift" \
    -o "$TEST_DIR/test"
"$TEST_DIR/test"
