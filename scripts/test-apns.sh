#!/usr/bin/env bash
# Foundation policy regression; no device, login, APNs traffic or private key required.
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/wand-ios-apns-tests.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/Sources/Wand" "$TEMP/Tests/WandTests"
cp Wand/RemoteNotifications.swift "$TEMP/Sources/Wand/"
cp WandTests/APNsTests.swift "$TEMP/Tests/WandTests/"
printf "%s\n" "// swift-tools-version: 5.9" "import PackageDescription" 'let package = Package(name: "WandAPNsTests", targets: [.target(name: "Wand"), .testTarget(name: "WandTests", dependencies: ["Wand"])])' > "$TEMP/Package.swift"
swift test --package-path "$TEMP"
