#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-deepseek-smoke.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

swiftc -parse-as-library \
  "$SCRIPT_DIR/Sources/AssetFrame/Models.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/MaterialClassification.swift \
  "$SCRIPT_DIR/Sources/AssetFrame/ClassificationVocabulary.swift \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekTaskKind.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekConfiguration.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekSettingsDraft.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekAPISettings.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekEndpointPolicy.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekClientError.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekChatClient.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekAIClient.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/ScriptAssetExtractionClient.swift" \
  "$SCRIPT_DIR/SelfTests/DeepSeekLiveSmokeTest.swift" \
  -o "$TEST_DIR/deepseek-live-smoke"

ASSETFRAME_RUN_LIVE_DEEPSEEK=1 "$TEST_DIR/deepseek-live-smoke"
