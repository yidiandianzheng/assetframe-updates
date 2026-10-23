#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-duplicate-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=()
for name in PendingReviewStatus GenerationOperation GenerationBatchRecord GenerationCandidateRecord GenerationProvenance CodexGenerationManifest CodexGenerationProjectContext Models AssetFileLocation DuplicateImportCandidate DuplicateImportQueueWriter; do
  SOURCES+=("$SCRIPT_DIR/Sources/AssetFrame/$name.swift")
done
swiftc -parse-as-library "${SOURCES[@]}" "$SCRIPT_DIR/SelfTests/DuplicateImportPreviewSelfTest.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
