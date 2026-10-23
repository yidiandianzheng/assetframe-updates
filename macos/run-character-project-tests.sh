#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/assetframe-project-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=()
for name in CharacterProfile CharacterMarkdown CharacterProjectModules CharacterProjectScanner CharacterWorkflowBridge CharacterExtractionClient DeepSeekConfiguration DeepSeekChatClient DeepSeekClientError DeepSeekEndpointPolicy; do
    SOURCES+=("$SCRIPT_DIR/Sources/AssetFrame/$name.swift")
done
swiftc -swift-version 6 -parse-as-library "${SOURCES[@]}" "$SCRIPT_DIR/SelfTests/CharacterProjectModulesSelfTest.swift" -o "$TEST_DIR/projects"
"$TEST_DIR/projects"
swiftc -swift-version 6 -parse-as-library "${SOURCES[@]}" "$SCRIPT_DIR/SelfTests/CharacterWorkflowBridgeSelfTest.swift" -o "$TEST_DIR/workflow"
"$TEST_DIR/workflow"
