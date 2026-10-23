#!/bin/zsh
set -euo pipefail

fixture="$(mktemp -d /tmp/assetframe-source-drift.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/Sources/AssetFrame" "$fixture/SelfTests"
print -r -- 'let value = 1' > "$fixture/Sources/AssetFrame/Fixture.swift"
print -r -- 'fixture' > "$fixture/SelfTests/Fixture.txt"
print -r -- '// swift-tools-version: 6.0' > "$fixture/Package.swift"

fingerprint() {
    (
        cd "$fixture"
        find Sources/AssetFrame SelfTests -type f -print | LC_ALL=C sort | while IFS= read -r file; do
            printf '%s  %s\n' "$(shasum -a 256 "$file" | awk '{print $1}')" "$file"
        done
        printf '%s  Package.swift\n' "$(shasum -a 256 Package.swift | awk '{print $1}')"
    ) | shasum -a 256 | awk '{print $1}'
}

before="$(fingerprint)"
print -r -- 'let value = 2' > "$fixture/Sources/AssetFrame/Fixture.swift"
after="$(fingerprint)"
[[ "$before" != "$after" ]] || { print -u2 -- 'SOURCE_DRIFT fixture was not detected'; exit 1; }
print -r -- 'Source drift fixture self-test passed'
