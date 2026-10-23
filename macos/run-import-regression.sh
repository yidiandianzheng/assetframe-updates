#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-import-regression.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCE_SNAPSHOT="$TEST_DIR/Sources"
ditto "$SCRIPT_DIR/Sources/AssetFrame" "$SOURCE_SNAPSHOT"
GENERATION_MODEL_SOURCES=()
for name in GenerationOperation GenerationBatchRecord GenerationCandidateRecord GenerationProvenance CodexGenerationManifest CodexGenerationProjectContext; do
  GENERATION_MODEL_SOURCES+=("$SOURCE_SNAPSHOT/$name.swift")
done
SOURCES=("$SOURCE_SNAPSHOT/PendingReviewStatus.swift" "${GENERATION_MODEL_SOURCES[@]}" "$SOURCE_SNAPSHOT/Models.swift" "$SOURCE_SNAPSHOT/MaterialClassification.swift" "$SOURCE_SNAPSHOT/ClassificationVocabulary.swift" "$SOURCE_SNAPSHOT/AssetFileLocation.swift" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift")
swiftc -parse-as-library "$SOURCE_SNAPSHOT/FileImportPasteboard.swift" "$SCRIPT_DIR/SelfTests/FileImportPasteboardSelfTest.swift" -o "$TEST_DIR/pasteboard"
"$TEST_DIR/pasteboard"
swiftc -O -D OPTIMIZED_IMPORT -parse-as-library "${SOURCES[@]}" "$SCRIPT_DIR/SelfTests/MaterialImportPerformanceSelfTest.swift" -o "$TEST_DIR/performance"
"$TEST_DIR/performance"
swiftc -parse-as-library "${SOURCES[@]}" "$SCRIPT_DIR/SelfTests/GlobalMaterialStoreSelfTest.swift" -o "$TEST_DIR/store"
"$TEST_DIR/store"
swiftc -O -parse-as-library "${SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDelivery.swift" "$SOURCE_SNAPSHOT/MaterialProductionActions.swift" "$SOURCE_SNAPSHOT/MaterialMediaAnalysis.swift" "$SOURCE_SNAPSHOT/MaterialPlaybackController.swift" "$SCRIPT_DIR/SelfTests/MaterialProductionSelfTest.swift" -o "$TEST_DIR/production"
"$TEST_DIR/production"
echo "Import focused regression passed"
