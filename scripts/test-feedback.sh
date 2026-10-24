#!/usr/bin/env bash
# Run production Foundation-only feedback transport logic without a device app.
# TaskCommentsTests now imports UIKit; run it with ./scripts/run-tests.sh TaskCommentsTests.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import pathlib, re
canonical = pathlib.Path('../src/feedback-feature-map.ts')
if canonical.exists():
    declaration = canonical.read_text().split('export const FEEDBACK_API_FEATURES = {', 1)[1].split('} as const', 1)[0]
    mirrored = pathlib.Path('Wand/ClientFeedback.swift').read_text().split('static let apiFeatures: [String: String] = [', 1)[1].split('\n    ]', 1)[0]
    pattern = r'"?([\w-]+)"?\s*:\s*"(\w+)"'
    expected, actual = dict(re.findall(pattern, declaration)), dict(re.findall(pattern, mirrored))
    assert expected and expected == actual, 'iOS feedback route map differs from FEEDBACK_API_FEATURES'
    print(f'Canonical feedback route map parity: {len(expected)} entries passed', flush=True)
else:
    print('Canonical main-repository map unavailable; running native table tests only', flush=True)
PY
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/wand-ios-feedback-tests.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/Sources/Wand" "$TEMP/Tests/WandTests"
cp Wand/ClientFeedback.swift Wand/ClientFeedbackTransport.swift Wand/SelfSignedSession.swift Wand/WandEndpoint.swift "$TEMP/Sources/Wand/"
cp scripts/feedback-test-support.swift "$TEMP/Sources/Wand/"
cp WandTests/ClientFeedbackTests.swift WandTests/ClientFeedbackTransportTests.swift "$TEMP/Tests/WandTests/"
cat > "$TEMP/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WandFeedbackTests", targets: [
    .target(name: "Wand"),
    .testTarget(name: "WandTests", dependencies: ["Wand"]),
])
SWIFT
swift test --package-path "$TEMP"
printf "%s\n" "TaskCommentsTests requires UIKit: run ./scripts/run-tests.sh TaskCommentsTests (not executed by this Foundation harness)."
