#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-vision-live.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

if [[ "${ASSETFRAME_VISION_SMOKE_ALLOW_COST:-0}" != "1" ]]; then
    echo "未授权真实视觉 API 调用。确认费用后设置 ASSETFRAME_VISION_SMOKE_ALLOW_COST=1" >&2
    exit 2
fi

swiftc -parse-as-library \
    "$SCRIPT_DIR/Sources/AssetFrame/PendingReviewStatus.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/GenerationOperation.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/GenerationBatchRecord.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/GenerationCandidateRecord.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/GenerationProvenance.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/CodexGenerationManifest.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/CodexGenerationProjectContext.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/Models.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/MaterialClassification.swift \
    "$SCRIPT_DIR/Sources/AssetFrame/ClassificationVocabulary.swift \
    "$SCRIPT_DIR/Sources/AssetFrame/AssetFileLocation.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekEndpointPolicy.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/VisionAPIConfiguration.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/VisionAPISettings.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/VisionAPIClientError.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/VisionModelClient.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/VisionImagePreprocessor.swift" \
    "$SCRIPT_DIR/Sources/AssetFrame/OpenAICompatibleVisionClient.swift" \
    "$SCRIPT_DIR/SelfTests/VisionAPILiveSmokeTest.swift" \
    -o "$TEST_DIR/vision-api-live-smoke"

"$TEST_DIR/vision-api-live-smoke"
