#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-self-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCE_SNAPSHOT="$TEST_DIR/Sources/AssetFrame"
SELF_TEST_SNAPSHOT="$TEST_DIR/SelfTests"

tree_fingerprint() {
    local root="$1"
    (
        cd "$root"
        find Sources/AssetFrame SelfTests -type f -print | LC_ALL=C sort | while IFS= read -r file; do
            printf '%s  %s\n' "$(shasum -a 256 "$file" | awk '{print $1}')" "$file"
        done
        printf '%s  Package.swift\n' "$(shasum -a 256 Package.swift | awk '{print $1}')"
    ) | shasum -a 256 | awk '{print $1}'
}

active_fingerprint() {
    {
        tree_fingerprint "$SCRIPT_DIR"
        shasum -a 256 "$SCRIPT_DIR/run-self-tests.sh" | awk '{print $1}'
    } | shasum -a 256 | awk '{print $1}'
}

SOURCE_FINGERPRINT_BEFORE="$(active_fingerprint)"
SNAPSHOT_FINGERPRINT_BEFORE="$(tree_fingerprint "$SCRIPT_DIR")"
mkdir -p "$TEST_DIR/Sources"
ditto "$SCRIPT_DIR/Sources/AssetFrame" "$SOURCE_SNAPSHOT"
ditto "$SCRIPT_DIR/SelfTests" "$SELF_TEST_SNAPSHOT"
ditto "$SCRIPT_DIR/Package.swift" "$TEST_DIR/Package.swift"
SNAPSHOT_FINGERPRINT_AFTER="$(tree_fingerprint "$TEST_DIR")"
if [[ "$SNAPSHOT_FINGERPRINT_BEFORE" != "$SNAPSHOT_FINGERPRINT_AFTER" ]]; then
    echo "SOURCE_DRIFT: 测试快照与运行前源码不一致，测试结果作废。" >&2
    exit 3
fi

swiftc -swift-version 6 -parse-as-library \
    "$SOURCE_SNAPSHOT/CharacterProfile.swift" "$SOURCE_SNAPSHOT/CharacterMarkdown.swift" \
    "$SOURCE_SNAPSHOT/CharacterProjectModules.swift" "$SOURCE_SNAPSHOT/CharacterProjectScanner.swift" \
    "$SOURCE_SNAPSHOT/CharacterWorkflowBridge.swift" "$SOURCE_SNAPSHOT/ProjectIntake.swift" "$SOURCE_SNAPSHOT/ProjectAutomationState.swift" \
    "$SOURCE_SNAPSHOT/CharacterLibraryStore.swift" "$SOURCE_SNAPSHOT/CharacterExtractionClient.swift" \
    "$SOURCE_SNAPSHOT/DeepSeekConfiguration.swift" "$SOURCE_SNAPSHOT/DeepSeekChatClient.swift" \
    "$SOURCE_SNAPSHOT/DeepSeekClientError.swift" "$SOURCE_SNAPSHOT/DeepSeekEndpointPolicy.swift" \
    "$SELF_TEST_SNAPSHOT/CharacterLibrarySelfTest.swift" -o "$TEST_DIR/characters"
"$TEST_DIR/characters"

swiftc -parse-as-library "$SOURCE_SNAPSHOT/PreviewCacheBudget.swift" "$SELF_TEST_SNAPSHOT/PreviewCacheBudgetSelfTest.swift" -o "$TEST_DIR/cache-budget"
"$TEST_DIR/cache-budget"

swiftc -swift-version 6 -parse-as-library "$SOURCE_SNAPSHOT/LocalCLIProtocol.swift" "$SOURCE_SNAPSHOT/LocalCLITransport.swift" "$SELF_TEST_SNAPSHOT/LocalCLITransportSelfTest.swift" -o "$TEST_DIR/cli-transport"
"$TEST_DIR/cli-transport"
if [[ "${1:-}" == "--cli-only" ]]; then
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

swiftc -parse-as-library "$SOURCE_SNAPSHOT/InspectorEditGuard.swift" "$SELF_TEST_SNAPSHOT/InspectorEditGuardSelfTest.swift" -o "$TEST_DIR/inspector-edit-guard"
"$TEST_DIR/inspector-edit-guard"

swiftc -parse-as-library "$SOURCE_SNAPSHOT/PreviewEscapeHandler.swift" "$SELF_TEST_SNAPSHOT/PreviewKeyNavigationSelfTest.swift" -framework AppKit -framework SwiftUI -o "$TEST_DIR/preview-key-navigation"
"$TEST_DIR/preview-key-navigation"

swiftc -O -parse-as-library "$SOURCE_SNAPSHOT/GalleryContentIndex.swift" "$SELF_TEST_SNAPSHOT/GalleryContentIndexSelfTest.swift" -o "$TEST_DIR/gallery-content-index"
"$TEST_DIR/gallery-content-index"

swiftc -O -parse-as-library "$SOURCE_SNAPSHOT/GalleryMembershipUpdatePolicy.swift" "$SELF_TEST_SNAPSHOT/GalleryMembershipUpdatePolicySelfTest.swift" -o "$TEST_DIR/gallery-membership-policy"
"$TEST_DIR/gallery-membership-policy"

GENERATION_MODEL_SOURCES=(
    "$SOURCE_SNAPSHOT/GenerationOperation.swift"
    "$SOURCE_SNAPSHOT/GenerationBatchRecord.swift"
    "$SOURCE_SNAPSHOT/GenerationCandidateRecord.swift"
    "$SOURCE_SNAPSHOT/GenerationProvenance.swift"
    "$SOURCE_SNAPSHOT/CodexGenerationManifest.swift"
    "$SOURCE_SNAPSHOT/CodexGenerationProjectContext.swift"
)

MODEL_SUPPORT_SOURCES=(
    "$SOURCE_SNAPSHOT/MaterialUndoPatch.swift"
    "$SOURCE_SNAPSHOT/MaterialTaggingState.swift"
    "$SOURCE_SNAPSHOT/MaterialTaggingUndo.swift"
    "$SOURCE_SNAPSHOT/MaterialClassification.swift"
    "$SOURCE_SNAPSHOT/ClassificationVocabulary.swift"
    "${GENERATION_MODEL_SOURCES[@]}"
    "$SOURCE_SNAPSHOT/MaterialSearchField.swift"
    "$SOURCE_SNAPSHOT/MaterialSearchText.swift"
    "$SOURCE_SNAPSHOT/MaterialTextSearchIndex.swift"
    "$SOURCE_SNAPSHOT/MaterialTextSearchCache.swift"
)

swiftc -O -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/SSDPreviewCache.swift" "$SOURCE_SNAPSHOT/PreviewCacheBudget.swift" \
    "$SOURCE_SNAPSHOT/MaterialMediaAnalysis.swift" \
    "$SOURCE_SNAPSHOT/MaterialPlaybackController.swift" \
    "$SOURCE_SNAPSHOT/NativeMaterialVideoPlayer.swift" \
    "$SOURCE_SNAPSHOT/CachedMaterialVideoFrame.swift" \
    "$SELF_TEST_SNAPSHOT/MaterialPlayerPreviewSelfTest.swift" \
    -o "$TEST_DIR/material-player-preview"
"$TEST_DIR/material-player-preview"

if [[ "${1:-}" == "--media-preview-only" ]]; then
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

COMMON_SOURCES=(
    "$SOURCE_SNAPSHOT/AppProduct.swift"
    "$SOURCE_SNAPSHOT/AssetRemovalPlan.swift"
    "$SOURCE_SNAPSHOT/AssetActionTarget.swift"
    "$SOURCE_SNAPSHOT/OriginalImageClipboard.swift"
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift"
    "$SOURCE_SNAPSHOT/PendingSourceTrashService.swift"
    "$SOURCE_SNAPSHOT/PendingImportManifestWriter.swift"
    "$SOURCE_SNAPSHOT/PendingImportJournalWriter.swift"
    "$SOURCE_SNAPSHOT/DuplicateImportQueueWriter.swift"
    "$SOURCE_SNAPSHOT/PendingReviewQueue.swift"
    "$SOURCE_SNAPSHOT/PendingReviewTypeSelection.swift"
    "$SOURCE_SNAPSHOT/PendingImportFocusResolver.swift"
    "${MODEL_SUPPORT_SOURCES[@]}"
    "$SOURCE_SNAPSHOT/Models.swift"
    "$SOURCE_SNAPSHOT/AssetAspectRatioFilterOption.swift"
    "$SOURCE_SNAPSHOT/AssetFileFormat.swift"
    "$SOURCE_SNAPSHOT/FilenameAssetClassifier.swift"
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift"
    "$SOURCE_SNAPSHOT/DuplicateImportCandidate.swift"
    "$SOURCE_SNAPSHOT/CodexGenerationIntake.swift"
    "$SOURCE_SNAPSHOT/LocalImageClassifier.swift"
    "$SOURCE_SNAPSHOT/PendingImportLocalClassification.swift"
    "$SOURCE_SNAPSHOT/PendingVisionClassificationProgressState.swift"
    "$SOURCE_SNAPSHOT/PendingAIClassificationProgressState.swift"
    "$SOURCE_SNAPSHOT/ProjectImageIndex.swift"
    "$SOURCE_SNAPSHOT/ScriptAssetMatchSortMode.swift"
    "$SOURCE_SNAPSHOT/ScriptAssetMatcher.swift"
    "$SOURCE_SNAPSHOT/AssetDecisionFilter.swift"
    "$SOURCE_SNAPSHOT/AssetQuery.swift"
    "$SOURCE_SNAPSHOT/SeededAssetShuffle.swift"
    "$SOURCE_SNAPSHOT/LocalFolderScope.swift"
    "$SOURCE_SNAPSHOT/GalleryChildFolder.swift"
    "$SOURCE_SNAPSHOT/OriginalFileMoveService.swift"
    "$SOURCE_SNAPSHOT/DeepSeekTaskKind.swift"
    "$SOURCE_SNAPSHOT/DeepSeekConfiguration.swift"
    "$SOURCE_SNAPSHOT/DeepSeekSettingsDraft.swift"
    "$SOURCE_SNAPSHOT/DeepSeekAPISettings.swift"
    "$SOURCE_SNAPSHOT/DeepSeekEndpointPolicy.swift"
    "$SOURCE_SNAPSHOT/DeepSeekClientError.swift"
    "$SOURCE_SNAPSHOT/DeepSeekChatClient.swift"
    "$SOURCE_SNAPSHOT/DeepSeekAIClient.swift"
    "$SOURCE_SNAPSHOT/VisionAPIConfiguration.swift"
    "$SOURCE_SNAPSHOT/VisionAPISettings.swift"
    "$SOURCE_SNAPSHOT/VisionAPIClientError.swift"
    "$SOURCE_SNAPSHOT/VisionModelClient.swift"
    "$SOURCE_SNAPSHOT/VisionImagePreprocessor.swift"
    "$SOURCE_SNAPSHOT/OpenAICompatibleVisionClient.swift"
    "$SOURCE_SNAPSHOT/LibraryAuditIssueKind.swift"
    "$SOURCE_SNAPSHOT/LibraryAuditSeverity.swift"
    "$SOURCE_SNAPSHOT/LibraryAuditIssue.swift"
    "$SOURCE_SNAPSHOT/LibraryAuditSuggestion.swift"
    "$SOURCE_SNAPSHOT/LibraryAuditSession.swift"
    "$SOURCE_SNAPSHOT/LibraryAuditAnalyzer.swift"
    "$SOURCE_SNAPSHOT/DeepSeekLibraryAuditClient.swift"
    "$SOURCE_SNAPSHOT/FeishuImport.swift"
    "$SOURCE_SNAPSHOT/ExportHealthIssue.swift"
    "$SOURCE_SNAPSHOT/ProjectLoadProgress.swift"
    "$SOURCE_SNAPSHOT/ImportProgressEstimator.swift"
    "$SOURCE_SNAPSHOT/ImportProgressController.swift"
    "$SOURCE_SNAPSHOT/ImportProgressRelay.swift"
    "$SOURCE_SNAPSHOT/SSDPreviewCache.swift" "$SOURCE_SNAPSHOT/PreviewCacheBudget.swift"
    "$SOURCE_SNAPSHOT/ImportTiming.swift"
    "$SOURCE_SNAPSHOT/ImportJobProgress.swift"
    "$SOURCE_SNAPSHOT/ImportDirectoryScanner.swift"
    "$SOURCE_SNAPSHOT/ImportResumeRecord.swift"
    "$SOURCE_SNAPSHOT/ProjectDatabase.swift"
    "$SOURCE_SNAPSHOT/ProjectRegistry.swift"
    "$SOURCE_SNAPSHOT/ScriptAssetExtractionClient.swift"
    "$SOURCE_SNAPSHOT/AssetStore.swift"
    "$SOURCE_SNAPSHOT/AssetStore+WorkspaceActions.swift"
)

swiftc -parse-as-library "$SOURCE_SNAPSHOT/ImportDirectoryScanner.swift" "$SOURCE_SNAPSHOT/LinkedFolderUpdateDetector.swift" "$SELF_TEST_SNAPSHOT/LinkedFolderUpdateDetectorSelfTest.swift" -o "$TEST_DIR/folder-update-detector"
"$TEST_DIR/folder-update-detector"

if [[ "${1:-}" == "--maintenance-only" || -z "${1:-}" ]]; then
    swiftc -D ASSETFRAME_SELF_TEST -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SOURCE_SNAPSHOT/MaterialRelocationScan.swift" "$SOURCE_SNAPSHOT/MaterialSimilarityScan.swift" "$SOURCE_SNAPSHOT/MaterialDocumentPreview.swift" "$SELF_TEST_SNAPSHOT/MaterialMaintenanceSelfTest.swift" -o "$TEST_DIR/maintenance"
    ASSETFRAME_QA_DATA_ROOT="$(mktemp -d /tmp/assetframe-qa.maintenance.XXXXXX)" "$TEST_DIR/maintenance"
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    if [[ "${1:-}" == "--maintenance-only" ]]; then exit 0; fi
fi

if [[ "${1:-}" == "--linked-folders-only" ]]; then
    swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SELF_TEST_SNAPSHOT/LinkedFolderReadSelfTest.swift" -o "$TEST_DIR/linked-folders"
    "$TEST_DIR/linked-folders"
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

if [[ "${1:-}" == "--finish-only" ]]; then
    swiftc -O -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SOURCE_SNAPSHOT/SVGDocument.swift" "$SOURCE_SNAPSHOT/LinkedFolderEventMonitor.swift" "$SOURCE_SNAPSHOT/TiledOriginalImage.swift" "$SOURCE_SNAPSHOT/PreviewCacheInventory.swift" "$SELF_TEST_SNAPSHOT/OptimizationFinishSelfTest.swift" -o "$TEST_DIR/finish"
    ASSETFRAME_QA_DATA_ROOT="$(mktemp -d /tmp/assetframe-qa.finish-selftest.XXXXXX)" "$TEST_DIR/finish"
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

if [[ "${1:-}" == "--library-session-only" ]]; then
    swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SOURCE_SNAPSHOT/LibraryStorage.swift" "$SOURCE_SNAPSHOT/LibrarySession.swift" "$SOURCE_SNAPSHOT/PreviewDecodePolicy.swift" "$SOURCE_SNAPSHOT/PreviewImagePipeline.swift" "$SOURCE_SNAPSHOT/MaterialTrashService.swift" "$SOURCE_SNAPSHOT/MaterialPlaybackController.swift" "$SELF_TEST_SNAPSHOT/LibrarySessionSelfTest.swift" -o "$TEST_DIR/library-session"
    ASSETFRAME_QA_DATA_ROOT="$(mktemp -d /tmp/assetframe-qa.session.XXXXXX)" "$TEST_DIR/library-session"
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

if [[ "${1:-}" == "--search-index-only" ]]; then
    swiftc -O -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SELF_TEST_SNAPSHOT/MaterialTextSearchSelfTest.swift" -o "$TEST_DIR/material-text-search"
    "$TEST_DIR/material-text-search"
    swiftc -O -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SELF_TEST_SNAPSHOT/MaterialFilterSelfTest.swift" -o "$TEST_DIR/material-filter"
    "$TEST_DIR/material-filter"
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

if [[ "${1:-}" == "--material-filter-only" ]]; then
    swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SELF_TEST_SNAPSHOT/MaterialFilterSelfTest.swift" -o "$TEST_DIR/material-filter"
    "$TEST_DIR/material-filter"
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

if [[ "${1:-}" == "--classification-only" ]]; then
    swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SELF_TEST_SNAPSHOT/MaterialClassificationSelfTest.swift" -o "$TEST_DIR/material-classification"
    "$TEST_DIR/material-classification"
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

if [[ "${1:-}" == "--unified-library-only" ]]; then
    swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/LibraryStorage.swift" "$SELF_TEST_SNAPSHOT/UnifiedLibrarySelfTest.swift" -o "$TEST_DIR/unified-library"
    "$TEST_DIR/unified-library"
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

if [[ "${1:-}" == "--direct-gallery-only" ]]; then
    swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/DirectGalleryImportSelfTest.swift" -o "$TEST_DIR/direct-gallery"
    "$TEST_DIR/direct-gallery"
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

if [[ "${1:-}" == "--streaming-only" ]]; then
    swiftc -O -parse-as-library "${COMMON_SOURCES[@]}" \
        "$SOURCE_SNAPSHOT/MaterialDatabase.swift" \
        "$SOURCE_SNAPSHOT/MaterialImportController.swift" \
        "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" \
        "$SELF_TEST_SNAPSHOT/StreamingImportSelfTest.swift" -o "$TEST_DIR/streaming"
    "$TEST_DIR/streaming"
    [[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }
    exit 0
fi

if [[ "${1:-}" == "--codex-live-e2e" ]]; then
    if [[ -z "${ASSETFRAME_REAL_IMAGE_PATH:-}" ]]; then
        echo "缺少 ASSETFRAME_REAL_IMAGE_PATH" >&2
        exit 2
    fi
    swiftc -parse-as-library \
        "${COMMON_SOURCES[@]}" \
        "$SELF_TEST_SNAPSHOT/CodexGenerationLiveE2E.swift" \
        -o "$TEST_DIR/codex-generation-live-e2e"
    ASSETFRAME_REAL_IMAGE_PATH="$ASSETFRAME_REAL_IMAGE_PATH" \
    ASSETFRAME_REAL_MODEL="${ASSETFRAME_REAL_MODEL:-}" \
    ASSETFRAME_REAL_PROMPT="${ASSETFRAME_REAL_PROMPT:-}" \
        "$TEST_DIR/codex-generation-live-e2e"
    exit 0
fi

if [[ "${1:-}" == "--performance-only" ]]; then
    swiftc -O -parse-as-library \
        "${COMMON_SOURCES[@]}" \
        "$SELF_TEST_SNAPSHOT/PerformanceSelfTest.swift" \
        -o "$TEST_DIR/performance"
    "$TEST_DIR/performance"
    SOURCE_FINGERPRINT_AFTER="$(active_fingerprint)"
    if [[ "$SOURCE_FINGERPRINT_BEFORE" != "$SOURCE_FINGERPRINT_AFTER" ]]; then
        echo "SOURCE_DRIFT: 性能测试期间源码、自测或脚本发生变化，结果作废。" >&2
        exit 3
    fi
    exit 0
fi

if [[ "${1:-}" == "--fast-index-only" ]]; then
    swiftc -O -parse-as-library \
        "${COMMON_SOURCES[@]}" \
        "$SELF_TEST_SNAPSHOT/FastIndexResumeSelfTest.swift" \
        -o "$TEST_DIR/fast-index-resume"
    "$TEST_DIR/fast-index-resume"
    SOURCE_FINGERPRINT_AFTER="$(active_fingerprint)"
    if [[ "$SOURCE_FINGERPRINT_BEFORE" != "$SOURCE_FINGERPRINT_AFTER" ]]; then
        echo "SOURCE_DRIFT: 快速索引测试期间源码、自测或脚本发生变化，结果作废。" >&2
        exit 3
    fi
    exit 0
fi

if [[ "${1:-}" == "--import-progress-isolation-only" ]]; then
    swiftc -parse-as-library \
        "${COMMON_SOURCES[@]}" \
        "$SELF_TEST_SNAPSHOT/ImportProgressIsolationSelfTest.swift" \
        -o "$TEST_DIR/import-progress-isolation"
    "$TEST_DIR/import-progress-isolation"
    SOURCE_FINGERPRINT_AFTER="$(active_fingerprint)"
    if [[ "$SOURCE_FINGERPRINT_BEFORE" != "$SOURCE_FINGERPRINT_AFTER" ]]; then
        echo "SOURCE_DRIFT: 进度隔离测试期间源码、自测或脚本发生变化，测试结果作废。" >&2
        exit 3
    fi
    exit 0
fi

if [[ "${1:-}" == "--duplicate-queue-only" ]]; then
    swiftc -parse-as-library \
        "${COMMON_SOURCES[@]}" \
        "$SELF_TEST_SNAPSHOT/DuplicateImportQueueSelfTest.swift" \
        -o "$TEST_DIR/duplicate-import-queue"
    "$TEST_DIR/duplicate-import-queue"
    SOURCE_FINGERPRINT_AFTER="$(active_fingerprint)"
    if [[ "$SOURCE_FINGERPRINT_BEFORE" != "$SOURCE_FINGERPRINT_AFTER" ]]; then
        echo "SOURCE_DRIFT: 重复队列测试期间源码、自测或脚本发生变化，结果作废。" >&2
        exit 3
    fi
    exit 0
fi

swiftc -parse-as-library "${COMMON_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/MaterialDatabase.swift" \
    "$SOURCE_SNAPSHOT/MaterialImportController.swift" \
    "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" \
    "$SELF_TEST_SNAPSHOT/StreamingImportSelfTest.swift" -o "$TEST_DIR/streaming"
"$TEST_DIR/streaming"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/ImportProgressEstimator.swift" \
    "$SELF_TEST_SNAPSHOT/ImportProgressEstimatorSelfTest.swift" \
    -o "$TEST_DIR/import-progress-estimator"
"$TEST_DIR/import-progress-estimator"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/FilenameAssetClassifier.swift" \
    "$SELF_TEST_SNAPSHOT/FilenameAssetClassifierSelfTest.swift" \
    -o "$TEST_DIR/filename-classifier"
"$TEST_DIR/filename-classifier"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/AppAppearance.swift" \
    "$SELF_TEST_SNAPSHOT/AppAppearanceSelfTest.swift" \
    -o "$TEST_DIR/app-appearance"
"$TEST_DIR/app-appearance"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/AssetRatingInteraction.swift" \
    "$SELF_TEST_SNAPSHOT/AssetRatingInteractionSelfTest.swift" \
    -o "$TEST_DIR/asset-rating-interaction"
"$TEST_DIR/asset-rating-interaction"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/CurrentProjectStarScope.swift" \
    "$SELF_TEST_SNAPSHOT/CurrentProjectStarScopeSelfTest.swift" \
    -o "$TEST_DIR/current-project-star-scope"
"$TEST_DIR/current-project-star-scope"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/ThumbnailLoadProgressModel.swift" \
    "$SELF_TEST_SNAPSHOT/ThumbnailLoadProgressSelfTest.swift" \
    -o "$TEST_DIR/thumbnail-load-progress"
"$TEST_DIR/thumbnail-load-progress"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/TrashSelection.swift" \
    "$SELF_TEST_SNAPSHOT/TrashSelectionSelfTest.swift" \
    -o "$TEST_DIR/trash-selection"
"$TEST_DIR/trash-selection"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/TrashSelfTest.swift" -o "$TEST_DIR/trash"
"$TEST_DIR/trash"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/PendingReviewSelfTest.swift" -o "$TEST_DIR/pending-review"
"$TEST_DIR/pending-review"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/DuplicateImportQueueSelfTest.swift" -o "$TEST_DIR/duplicate-import-queue"
"$TEST_DIR/duplicate-import-queue"

swiftc -O -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/PerformanceSelfTest.swift" -o "$TEST_DIR/performance"
"$TEST_DIR/performance"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/DeepSeekTaskKind.swift" \
    "$SOURCE_SNAPSHOT/DeepSeekConfiguration.swift" \
    "$SOURCE_SNAPSHOT/DeepSeekSettingsDraft.swift" \
    "$SOURCE_SNAPSHOT/DeepSeekAPISettings.swift" \
    "$SOURCE_SNAPSHOT/DeepSeekEndpointPolicy.swift" \
    "$SOURCE_SNAPSHOT/DeepSeekClientError.swift" \
    "$SOURCE_SNAPSHOT/DeepSeekChatClient.swift" \
    "$SOURCE_SNAPSHOT/DeepSeekAIClient.swift" \
    "$SELF_TEST_SNAPSHOT/DeepSeekAIClientSelfTest.swift" \
    -o "$TEST_DIR/deepseek"
"$TEST_DIR/deepseek"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/VisionAPIClassificationSelfTest.swift" -o "$TEST_DIR/vision-api-classification"
"$TEST_DIR/vision-api-classification"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/LibraryAuditSelfTest.swift" -o "$TEST_DIR/library-audit"
"$TEST_DIR/library-audit"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PreviewZoomMath.swift" \
    "$SOURCE_SNAPSHOT/PreviewPanMath.swift" \
    "$SELF_TEST_SNAPSHOT/PreviewZoomMathSelfTest.swift" \
    -o "$TEST_DIR/preview"
"$TEST_DIR/preview"

swiftc -O -parse-as-library \
    "$SOURCE_SNAPSHOT/GallerySelectionIndex.swift" \
    "$SELF_TEST_SNAPSHOT/GallerySelectionIndexSelfTest.swift" \
    -o "$TEST_DIR/gallery-selection-index"
"$TEST_DIR/gallery-selection-index"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/GallerySelectionController.swift" \
    "$SELF_TEST_SNAPSHOT/GallerySelectionControllerSelfTest.swift" \
    -o "$TEST_DIR/gallery-selection-controller"
"$TEST_DIR/gallery-selection-controller"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/GallerySelectionController.swift" \
    "$SOURCE_SNAPSHOT/WorkspaceSelectionModel.swift" \
    "$SELF_TEST_SNAPSHOT/WorkspaceSelectionModelSelfTest.swift" \
    -o "$TEST_DIR/workspace-selection-model"
"$TEST_DIR/workspace-selection-model"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/ContextualInspectorState.swift" \
    "$SELF_TEST_SNAPSHOT/ContextualInspectorStateSelfTest.swift" \
    -o "$TEST_DIR/contextual-inspector-state"
"$TEST_DIR/contextual-inspector-state"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/AssetActionTarget.swift" \
    "$SOURCE_SNAPSHOT/AssetRemovalPlan.swift" \
    "$SELF_TEST_SNAPSHOT/AssetRemovalPlanSelfTest.swift" \
    -o "$TEST_DIR/asset-removal-plan"
"$TEST_DIR/asset-removal-plan"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/WorkspaceSearchContext.swift" \
    "$SELF_TEST_SNAPSHOT/WorkspaceSearchContextSelfTest.swift" \
    -o "$TEST_DIR/workspace-search-context"
"$TEST_DIR/workspace-search-context"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/AssetAspectRatioFilterOption.swift" \
    "$SOURCE_SNAPSHOT/AssetFileFormat.swift" \
    "$SOURCE_SNAPSHOT/AssetDecisionFilter.swift" \
    "$SOURCE_SNAPSHOT/AssetQuery.swift" \
    "$SOURCE_SNAPSHOT/SavedFilterPreset.swift" \
    "$SOURCE_SNAPSHOT/WorkspaceDestination.swift" \
    "$SELF_TEST_SNAPSHOT/SavedFilterPresetSelfTest.swift" \
    -o "$TEST_DIR/saved-filter-preset"
"$TEST_DIR/saved-filter-preset"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingSourceTrashService.swift" \
    "$SOURCE_SNAPSHOT/AssetFrameQADataRoot.swift" \
    "$SELF_TEST_SNAPSHOT/AssetFrameQADataRootSelfTest.swift" \
    -o "$TEST_DIR/qa-data-root"
"$TEST_DIR/qa-data-root"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PreviewDecodePolicy.swift" \
    "$SELF_TEST_SNAPSHOT/PreviewDecodePolicySelfTest.swift" \
    -o "$TEST_DIR/preview-decode-policy"
"$TEST_DIR/preview-decode-policy"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/AssetJustifiedLayout.swift" \
    "$SELF_TEST_SNAPSHOT/AssetJustifiedLayoutSelfTest.swift" \
    -framework AppKit \
    -o "$TEST_DIR/asset-masonry-layout"
"$TEST_DIR/asset-masonry-layout"

swiftc -O -parse-as-library \
    "$SOURCE_SNAPSHOT/PreviewDecodePolicy.swift" \
    "$SOURCE_SNAPSHOT/SSDPreviewCache.swift" "$SOURCE_SNAPSHOT/PreviewCacheBudget.swift" \
    "$SOURCE_SNAPSHOT/PreviewImagePipeline.swift" \
    "$SELF_TEST_SNAPSHOT/PreviewPerformanceSelfTest.swift" \
    -framework AppKit -framework ImageIO \
    -o "$TEST_DIR/preview-performance"
"$TEST_DIR/preview-performance"

swiftc -O -parse-as-library "$SOURCE_SNAPSHOT/PreviewDecodePolicy.swift" "$SOURCE_SNAPSHOT/SSDPreviewCache.swift" "$SOURCE_SNAPSHOT/PreviewCacheBudget.swift" "$SOURCE_SNAPSHOT/PreviewImagePipeline.swift" "$SELF_TEST_SNAPSHOT/PreviewPipelineConcurrencySelfTest.swift" -framework AppKit -framework ImageIO -o "$TEST_DIR/preview-concurrency"
ASSETFRAME_QA_DATA_ROOT="$(mktemp -d /tmp/assetframe-qa.preview.XXXXXX)" "$TEST_DIR/preview-concurrency"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/ThumbnailSizing.swift" \
    "$SELF_TEST_SNAPSHOT/ThumbnailSizingSelfTest.swift" \
    -o "$TEST_DIR/thumbnail-sizing"
"$TEST_DIR/thumbnail-sizing"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/AssetDominantColor.swift" \
    "$SELF_TEST_SNAPSHOT/AssetColorPaletteSelfTest.swift" \
    -framework CoreGraphics -framework ImageIO \
    -o "$TEST_DIR/asset-color-palette"
"$TEST_DIR/asset-color-palette"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/AssetPreviewSession.swift" \
    "$SELF_TEST_SNAPSHOT/AssetPreviewSessionSelfTest.swift" \
    -o "$TEST_DIR/preview-session"
"$TEST_DIR/preview-session"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/GallerySnapshotBuilder.swift" \
    "$SELF_TEST_SNAPSHOT/GallerySnapshotSelfTest.swift" \
    -o "$TEST_DIR/gallery"
"$TEST_DIR/gallery"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/GalleryNavigationDirection.swift" \
    "$SOURCE_SNAPSHOT/GalleryGridNavigation.swift" \
    "$SOURCE_SNAPSHOT/GalleryPreviewNavigator.swift" \
    "$SELF_TEST_SNAPSHOT/GalleryGridNavigationSelfTest.swift" \
    -o "$TEST_DIR/gallery-navigation"
"$TEST_DIR/gallery-navigation"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/GalleryRangeSelection.swift" \
    "$SELF_TEST_SNAPSHOT/GalleryRangeSelectionSelfTest.swift" \
    -o "$TEST_DIR/gallery-range-selection"
"$TEST_DIR/gallery-range-selection"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/GalleryContextSelection.swift" \
    "$SELF_TEST_SNAPSHOT/GalleryContextSelectionSelfTest.swift" \
    -o "$TEST_DIR/gallery-context-selection"
"$TEST_DIR/gallery-context-selection"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/GalleryCardChrome.swift" \
    "$SELF_TEST_SNAPSHOT/GalleryCardChromeSelfTest.swift" \
    -framework AppKit \
    -o "$TEST_DIR/gallery-card-chrome"
"$TEST_DIR/gallery-card-chrome"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/FiveStarLayoutMode.swift" \
    "$SELF_TEST_SNAPSHOT/FiveStarLayoutModeSelfTest.swift" \
    -o "$TEST_DIR/five-star-layout-mode"
"$TEST_DIR/five-star-layout-mode"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/AppVersion.swift" \
    "$SOURCE_SNAPSHOT/OnlineServiceConfiguration.swift" \
    "$SOURCE_SNAPSHOT/FeedbackModels.swift" \
    "$SOURCE_SNAPSHOT/FeedbackClient.swift" \
    "$SOURCE_SNAPSHOT/OptimizationNote.swift" \
    "$SELF_TEST_SNAPSHOT/OptimizationNoteSelfTest.swift" \
    -o "$TEST_DIR/optimization-note"
"$TEST_DIR/optimization-note"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/AppVersion.swift" \
    "$SOURCE_SNAPSHOT/OnlineServiceConfiguration.swift" \
    "$SOURCE_SNAPSHOT/FeedbackModels.swift" \
    "$SOURCE_SNAPSHOT/FeedbackClient.swift" \
    "$SOURCE_SNAPSHOT/OptimizationNote.swift" \
    "$SELF_TEST_SNAPSHOT/FeedbackClientSelfTest.swift" \
    -o "$TEST_DIR/feedback-client"
"$TEST_DIR/feedback-client"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/AppVersion.swift" \
    "$SOURCE_SNAPSHOT/OnlineServiceConfiguration.swift" \
    "$SOURCE_SNAPSHOT/FeedbackModels.swift" \
    "$SOURCE_SNAPSHOT/FeedbackClient.swift" \
    "$SOURCE_SNAPSHOT/OptimizationNote.swift" \
    "$SELF_TEST_SNAPSHOT/FeedbackQueueSelfTest.swift" \
    -o "$TEST_DIR/feedback-queue"
"$TEST_DIR/feedback-queue"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/AssetTableField.swift" \
    "$SOURCE_SNAPSHOT/AssetTableImageScale.swift" \
    "$SOURCE_SNAPSHOT/AssetTableSection.swift" \
    "$SOURCE_SNAPSHOT/AssetTableGroupOption.swift" \
    "$SOURCE_SNAPSHOT/AssetTableViewPreset.swift" \
    "$SELF_TEST_SNAPSHOT/AssetTableConfigurationSelfTest.swift" \
    -o "$TEST_DIR/table"
"$TEST_DIR/table"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/AssetOrganizationSelfTest.swift" -o "$TEST_DIR/organization"
"$TEST_DIR/organization"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/LocalFolderTreeLayout.swift" \
    "$SELF_TEST_SNAPSHOT/LocalFolderTreeLayoutSelfTest.swift" \
    -o "$TEST_DIR/local-folder-tree-layout"
"$TEST_DIR/local-folder-tree-layout"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/LocalFolderScope.swift" \
    "$SELF_TEST_SNAPSHOT/LocalFolderScopeSelfTest.swift" \
    -o "$TEST_DIR/local-folder-scope"
"$TEST_DIR/local-folder-scope"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/SidebarQuickAccessItem.swift" \
    "$SOURCE_SNAPSHOT/SidebarQuickAccessCodec.swift" \
    "$SOURCE_SNAPSHOT/SidebarSearchMatcher.swift" \
    "$SELF_TEST_SNAPSHOT/SidebarQuickAccessSelfTest.swift" \
    -o "$TEST_DIR/sidebar-quick-access"
"$TEST_DIR/sidebar-quick-access"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/GalleryChildFolder.swift" \
    "$SELF_TEST_SNAPSHOT/GalleryChildFolderResolverSelfTest.swift" \
    -o "$TEST_DIR/gallery-child-folder-resolver"
"$TEST_DIR/gallery-child-folder-resolver"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/LocalFolderImportSelfTest.swift" -o "$TEST_DIR/local-folder-import"
"$TEST_DIR/local-folder-import"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/FiveStarManagedCopySelfTest.swift" -o "$TEST_DIR/five-star-managed-copy"
"$TEST_DIR/five-star-managed-copy"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/OriginalPlaceScanSafetySelfTest.swift" -o "$TEST_DIR/original-place-scan-safety"
"$TEST_DIR/original-place-scan-safety"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/FastIndexResumeSelfTest.swift" -o "$TEST_DIR/fast-index-resume"
"$TEST_DIR/fast-index-resume"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/ImportProgressIsolationSelfTest.swift" -o "$TEST_DIR/import-progress-isolation"
"$TEST_DIR/import-progress-isolation"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/ProjectIsolationSelfTest.swift" -o "$TEST_DIR/project-isolation"
"$TEST_DIR/project-isolation"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/FirstLaunchSelfTest.swift" -o "$TEST_DIR/first-launch"
"$TEST_DIR/first-launch"

# AssetDeliverySelfTest targets the disconnected script-breakdown prototype
# that Package.swift intentionally excludes from the production application.
# Keep its source as migration evidence, but do not report that archived
# prototype as part of the shipping AssetFrame regression suite.

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/ScriptAssetChecklistSelfTest.swift" -o "$TEST_DIR/script-checklist"
"$TEST_DIR/script-checklist"

# ProjectImageIndexSelfTest targets removed ProjectDatabase APIs from the
# archived script-breakdown prototype; it is not part of the shipping target.

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/MaterialDatabase.swift" \
    "$SOURCE_SNAPSHOT/SSDPreviewCache.swift" "$SOURCE_SNAPSHOT/PreviewCacheBudget.swift" \
    "$SOURCE_SNAPSHOT/ImportTiming.swift" \
    "$SOURCE_SNAPSHOT/ImportJobProgress.swift" \
    "$SOURCE_SNAPSHOT/ImportDirectoryScanner.swift" \
    "$SOURCE_SNAPSHOT/ImportResumeRecord.swift" \
    "$SOURCE_SNAPSHOT/MaterialImportController.swift" \
    "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" \
    "$SOURCE_SNAPSHOT/OriginalImageClipboard.swift" \
    "$SELF_TEST_SNAPSHOT/GlobalMaterialStoreSelfTest.swift" \
    -o "$TEST_DIR/global-material-store"

swiftc -O -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/MaterialDatabase.swift" \
    "$SOURCE_SNAPSHOT/SSDPreviewCache.swift" "$SOURCE_SNAPSHOT/PreviewCacheBudget.swift" \
    "$SOURCE_SNAPSHOT/ImportTiming.swift" \
    "$SOURCE_SNAPSHOT/ImportJobProgress.swift" \
    "$SOURCE_SNAPSHOT/ImportDirectoryScanner.swift" \
    "$SOURCE_SNAPSHOT/ImportResumeRecord.swift" \
    "$SOURCE_SNAPSHOT/MaterialImportController.swift" \
    "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" \
    "$SOURCE_SNAPSHOT/OriginalImageClipboard.swift" \
    "$SOURCE_SNAPSHOT/MaterialDelivery.swift" \
    "$SOURCE_SNAPSHOT/MaterialProductionActions.swift" \
    "$SOURCE_SNAPSHOT/MaterialMediaAnalysis.swift" \
    "$SOURCE_SNAPSHOT/MaterialPlaybackController.swift" \
    "$SELF_TEST_SNAPSHOT/MaterialProductionSelfTest.swift" \
    -o "$TEST_DIR/material-production"
"$TEST_DIR/material-production"
"$TEST_DIR/global-material-store"

swiftc -O -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/MaterialDatabase.swift" \
    "$SOURCE_SNAPSHOT/SSDPreviewCache.swift" "$SOURCE_SNAPSHOT/PreviewCacheBudget.swift" \
    "$SOURCE_SNAPSHOT/ImportTiming.swift" \
    "$SOURCE_SNAPSHOT/ImportJobProgress.swift" \
    "$SOURCE_SNAPSHOT/ImportDirectoryScanner.swift" \
    "$SOURCE_SNAPSHOT/ImportResumeRecord.swift" \
    "$SOURCE_SNAPSHOT/MaterialImportController.swift" \
    "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" \
    "$SOURCE_SNAPSHOT/OriginalImageClipboard.swift" \
    "$SELF_TEST_SNAPSHOT/MaterialImportPerformanceSelfTest.swift" \
    -o "$TEST_DIR/material-import-performance"
"$TEST_DIR/material-import-performance"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/ProjectLoadProgress.swift" \
    "$SOURCE_SNAPSHOT/ProjectDatabase.swift" \
    "$SOURCE_SNAPSHOT/FiveStarScope.swift" \
    "$SOURCE_SNAPSHOT/GlobalFiveStarSource.swift" \
    "$SOURCE_SNAPSHOT/GlobalFiveStarRecord.swift" \
    "$SOURCE_SNAPSHOT/GlobalFiveStarLink.swift" \
    "$SOURCE_SNAPSHOT/FiveStarAssetCategory.swift" \
    "$SOURCE_SNAPSHOT/OriginalImageClipboard.swift" \
    "$SOURCE_SNAPSHOT/GlobalFiveStarStore.swift" \
    "$SELF_TEST_SNAPSHOT/GlobalFiveStarStoreSelfTest.swift" \
    -o "$TEST_DIR/global-five-star-store"
"$TEST_DIR/global-five-star-store"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SELF_TEST_SNAPSHOT/AssetFileLocationSelfTest.swift" \
    -o "$TEST_DIR/asset-file-location"
"$TEST_DIR/asset-file-location"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/OriginalImageClipboard.swift" \
    "$SELF_TEST_SNAPSHOT/OriginalImageClipboardSelfTest.swift" \
    -o "$TEST_DIR/original-image-clipboard"
"$TEST_DIR/original-image-clipboard"

swiftc -parse-as-library \
    "$SOURCE_SNAPSHOT/PendingReviewStatus.swift" \
    "${MODEL_SUPPORT_SOURCES[@]}" \
    "$SOURCE_SNAPSHOT/Models.swift" \
    "$SOURCE_SNAPSHOT/AssetFileLocation.swift" \
    "$SOURCE_SNAPSHOT/LocalImageClassifier.swift" \
    "$SOURCE_SNAPSHOT/PendingImportLocalClassification.swift" \
    "$SELF_TEST_SNAPSHOT/PendingVisionClassificationSelfTest.swift" \
    -o "$TEST_DIR/pending-vision-classification"
"$TEST_DIR/pending-vision-classification"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/CodexGenerationIntakeSelfTest.swift" -o "$TEST_DIR/codex-generation-intake"
"$TEST_DIR/codex-generation-intake"

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SELF_TEST_SNAPSHOT/DirectGalleryImportSelfTest.swift" -o "$TEST_DIR/direct-gallery"
"$TEST_DIR/direct-gallery"

swiftc -parse-as-library "$SOURCE_SNAPSHOT/SSDPreviewCache.swift" "$SOURCE_SNAPSHOT/PreviewCacheBudget.swift" "$SOURCE_SNAPSHOT/PreviewDecodePolicy.swift" "$SOURCE_SNAPSHOT/PreviewImagePipeline.swift" "$SOURCE_SNAPSHOT/MaterialThumbnailFallback.swift" "$SELF_TEST_SNAPSHOT/SSDPreviewCacheSelfTest.swift" -o "$TEST_DIR/ssd-preview-cache"
ASSETFRAME_QA_DATA_ROOT="$(mktemp -d /tmp/assetframe-qa.cache.XXXXXX)" "$TEST_DIR/ssd-preview-cache"

zsh "$SELF_TEST_SNAPSHOT/source-drift-self-test.sh"

SOURCE_FINGERPRINT_AFTER="$(active_fingerprint)"
if [[ "$SOURCE_FINGERPRINT_BEFORE" != "$SOURCE_FINGERPRINT_AFTER" ]]; then
    echo "SOURCE_DRIFT: 测试期间源码、自测或脚本发生变化，测试结果作废并需要重跑。" >&2
    exit 3
fi

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/LibraryStorage.swift" "$SELF_TEST_SNAPSHOT/UnifiedLibrarySelfTest.swift" -o "$TEST_DIR/unified-library"
"$TEST_DIR/unified-library"
[[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }

swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SOURCE_SNAPSHOT/LibraryStorage.swift" "$SOURCE_SNAPSHOT/LibrarySession.swift" "$SOURCE_SNAPSHOT/PreviewDecodePolicy.swift" "$SOURCE_SNAPSHOT/PreviewImagePipeline.swift" "$SOURCE_SNAPSHOT/MaterialTrashService.swift" "$SOURCE_SNAPSHOT/MaterialPlaybackController.swift" "$SELF_TEST_SNAPSHOT/LibrarySessionSelfTest.swift" -o "$TEST_DIR/library-session"
ASSETFRAME_QA_DATA_ROOT="$(mktemp -d /tmp/assetframe-qa.session.XXXXXX)" "$TEST_DIR/library-session"
[[ "$SOURCE_FINGERPRINT_BEFORE" == "$(active_fingerprint)" ]] || { echo SOURCE_DRIFT; exit 3; }

    swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SELF_TEST_SNAPSHOT/MaterialFilterSelfTest.swift" -o "$TEST_DIR/material-filter"
    "$TEST_DIR/material-filter"
swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SELF_TEST_SNAPSHOT/MaterialClassificationSelfTest.swift" -o "$TEST_DIR/material-classification"
"$TEST_DIR/material-classification"
swiftc -parse-as-library "$SOURCE_SNAPSHOT/MaterialSourceAvailability.swift" "$SELF_TEST_SNAPSHOT/MaterialSourceAvailabilitySelfTest.swift" -o "$TEST_DIR/material-source-availability"
"$TEST_DIR/material-source-availability"
swiftc -parse-as-library "${COMMON_SOURCES[@]}" "$SOURCE_SNAPSHOT/MaterialDatabase.swift" "$SOURCE_SNAPSHOT/MaterialImportController.swift" "$SOURCE_SNAPSHOT/GlobalMaterialStore.swift" "$SELF_TEST_SNAPSHOT/LinkedFolderReadSelfTest.swift" -o "$TEST_DIR/linked-folders"
"$TEST_DIR/linked-folders"
echo "All AssetFrame self-tests passed"
