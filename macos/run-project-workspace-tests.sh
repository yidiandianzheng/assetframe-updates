#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-workspace-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCE_DIR="$TEST_DIR/sources"
mkdir -p "$SOURCE_DIR"
cp "$SCRIPT_DIR"/Sources/AssetFrame/*.swift "$SOURCE_DIR/"
INTEGRATION_SOURCES=()
for name in PendingReviewStatus GenerationOperation GenerationBatchRecord GenerationCandidateRecord GenerationProvenance CodexGenerationManifest CodexGenerationProjectContext MaterialUndoPatch MaterialClassification ClassificationVocabulary MaterialTaggingState MaterialTaggingUndo MaterialSearchField MaterialSearchText MaterialTextSearchIndex MaterialTextSearchCache Models AssetFileLocation MaterialDatabase SSDPreviewCache PreviewCacheBudget ImportTiming ImportJobProgress ImportDirectoryScanner ImportResumeRecord MaterialImportController GlobalMaterialStore OriginalImageClipboard MaterialDelivery MaterialProductionActions CharacterProfile CharacterMarkdown CharacterLibraryStore CharacterProjectModules CharacterModuleWorkflow ProjectAssetGraph CharacterProjectScanner CharacterWorkflowBridge ProjectIntake ProjectAutomationState ProjectWorkbenchIndex ProjectImageResolution ProjectSourceFileIndex CharacterExtractionClient DeepSeekConfiguration DeepSeekChatClient DeepSeekClientError DeepSeekEndpointPolicy ProjectAutomationClient ProjectAutomationService DeepSeekTaskKind DeepSeekSettingsDraft DeepSeekAPISettings LinkedFolderEventMonitor; do
    INTEGRATION_SOURCES+=("$SOURCE_DIR/$name.swift")
done
swiftc -swift-version 6 -parse-as-library "${INTEGRATION_SOURCES[@]}" "$SCRIPT_DIR/SelfTests/ProjectWorkspaceSelfTest.swift" -o "$TEST_DIR/workspace"
"$TEST_DIR/workspace"
