#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-vision-evaluation.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

if [[ -z "${ASSETFRAME_VISION_EVALUATION_REVIEW_INPUT:-}" && "${ASSETFRAME_VISION_EVALUATION_ALLOW_COST:-0}" != "1" ]]; then
    echo "未授权付费评测。确认费用后设置 ASSETFRAME_VISION_EVALUATION_ALLOW_COST=1" >&2
    exit 2
fi
if [[ -z "${ASSETFRAME_VISION_EVALUATION_MANIFEST:-}" ]]; then
    echo "缺少 ASSETFRAME_VISION_EVALUATION_MANIFEST" >&2
    exit 3
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
    "$SCRIPT_DIR/SelfTests/VisionAPIBatchEvaluation.swift" \
    -o "$TEST_DIR/vision-api-batch-evaluation"

"$TEST_DIR/vision-api-batch-evaluation"
