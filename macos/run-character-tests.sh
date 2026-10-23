#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-character-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$SCRIPT_DIR/Sources/AssetFrame/CharacterProfile.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/CharacterProjectModules.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/CharacterProjectScanner.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/CharacterWorkflowBridge.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/ProjectIntake.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/ProjectAutomationState.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/CharacterMarkdown.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/CharacterLibraryStore.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/CharacterExtractionClient.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekConfiguration.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekChatClient.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekClientError.swift" \
  "$SCRIPT_DIR/Sources/AssetFrame/DeepSeekEndpointPolicy.swift" \
  "$SCRIPT_DIR/SelfTests/CharacterLibrarySelfTest.swift" \
  -o "$TEST_DIR/characters"
"$TEST_DIR/characters"

SOURCE_DIR="$SCRIPT_DIR/Sources/AssetFrame"
INTEGRATION_SOURCES=()
for name in PendingReviewStatus GenerationOperation GenerationBatchRecord GenerationCandidateRecord GenerationProvenance CodexGenerationManifest CodexGenerationProjectContext MaterialUndoPatch MaterialClassification ClassificationVocabulary MaterialTaggingState MaterialTaggingUndo MaterialSearchField MaterialSearchText MaterialTextSearchIndex MaterialTextSearchCache Models AssetFileLocation MaterialDatabase SSDPreviewCache PreviewCacheBudget ImportTiming ImportJobProgress ImportDirectoryScanner ImportResumeRecord MaterialImportController GlobalMaterialStore OriginalImageClipboard MaterialDelivery MaterialProductionActions CharacterProfile CharacterMarkdown CharacterLibraryStore CharacterProjectModules CharacterModuleWorkflow ProjectAssetGraph CharacterProjectScanner CharacterWorkflowBridge ProjectIntake ProjectAutomationState CharacterExtractionClient DeepSeekConfiguration DeepSeekChatClient DeepSeekClientError DeepSeekEndpointPolicy; do
    INTEGRATION_SOURCES+=("$SOURCE_DIR/$name.swift")
done
swiftc -parse-as-library "${INTEGRATION_SOURCES[@]}" "$SCRIPT_DIR/SelfTests/CharacterMaterialIntegrationSelfTest.swift" -o "$TEST_DIR/character-material-integration"
"$TEST_DIR/character-material-integration"

swiftc -parse-as-library "${INTEGRATION_SOURCES[@]}" "$SCRIPT_DIR/SelfTests/ProjectWorkflowIntegrationSelfTest.swift" -o "$TEST_DIR/project-workflow"
"$TEST_DIR/project-workflow"
