#!/usr/bin/env bash
# Bounded Foundation-only tests: no Xcode, simulator, network, or app installation.
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/wand-ios-conversation-filters.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/Sources/Wand" "$TEMP/Tests/WandTests"
cp Wand/ConversationListFilters.swift "$TEMP/Sources/Wand/"
cp WandTests/ConversationListFiltersTests.swift "$TEMP/Tests/WandTests/"
cat > "$TEMP/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WandConversationFilterTests", targets: [
    .target(name: "Wand"),
    .testTarget(name: "WandTests", dependencies: ["Wand"]),
])
SWIFT
swift test --package-path "$TEMP" --jobs 2
