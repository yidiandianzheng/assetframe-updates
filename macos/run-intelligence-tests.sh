#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-intelligence-tests.XXXXXX)"
export ASSETFRAME_QA_DATA_ROOT="$(mktemp -d /tmp/assetframe-qa.intelligence-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR" "$ASSETFRAME_QA_DATA_ROOT"' EXIT
mkdir -p "$TEST_DIR/sources"
SOURCES=()
for name in PendingReviewStatus GenerationOperation GenerationBatchRecord GenerationCandidateRecord GenerationProvenance CodexGenerationManifest CodexGenerationProjectContext MaterialUndoPatch MaterialClassification ClassificationVocabulary MaterialTaggingState MaterialTaggingUndo MaterialSearchField MaterialSearchText MaterialTextSearchIndex MaterialTextSearchCache Models AssetFileLocation MaterialDatabase SSDPreviewCache PreviewCacheBudget ImportTiming ImportJobProgress ImportDirectoryScanner ImportResumeRecord MaterialImportController GlobalMaterialStore OriginalImageClipboard MaterialDelivery MaterialProductionActions CharacterProfile CharacterMarkdown CharacterLibraryStore CharacterProjectModules CharacterModuleWorkflow ProjectAssetGraph CharacterProjectScanner CharacterWorkflowBridge ProjectIntake ProjectAutomationState ProjectWorkbenchIndex ProjectImageResolution ProjectSourceFileIndex CharacterExtractionClient DeepSeekConfiguration DeepSeekChatClient DeepSeekClientError DeepSeekEndpointPolicy ProjectAutomationClient ProjectAutomationService DeepSeekTaskKind DeepSeekSettingsDraft DeepSeekAPISettings LinkedFolderEventMonitor MaterialIntelligence MaterialSimilarityScan VisionAPIConfiguration VisionAPIClientError VisionModelClient VisionImagePreprocessor OpenAICompatibleVisionClient; do
    cp "$SCRIPT_DIR/Sources/AssetFrame/$name.swift" "$TEST_DIR/sources/"
    SOURCES+=("$TEST_DIR/sources/$name.swift")
done
cp "$SCRIPT_DIR/SelfTests/MaterialIntelligenceSelfTest.swift" "$TEST_DIR/test.swift"
swiftc -swift-version 6 -parse-as-library "${SOURCES[@]}" "$TEST_DIR/test.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
