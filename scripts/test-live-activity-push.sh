#!/usr/bin/env bash
# Test real server-generated content-state against the production Swift Codable declaration. No device/network/secrets.
set -euo pipefail
cd "$(dirname "$0")/.."
MAIN="$(cd .. && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/wand-live-activity-tests.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/Sources/Wand" "$TEMP/Tests/WandTests"
cp Wand/RemoteNotifications.swift Wand/LiveActivityPush.swift "$TEMP/Sources/Wand/"
cp WandTests/LiveActivityPushTests.swift "$TEMP/Tests/WandTests/"
python3 - "$TEMP" <<'PY'
from pathlib import Path
import sys
text=Path("Wand/SessionActivityAttributes.swift").read_text().split("\nextension SessionActivityAttributes.SessionEntry {",1)[0]
assert "struct ContentState: Codable" in text
text=text.replace("import ActivityKit\n","").replace(": ActivityAttributes {",": Codable {",1)
Path(sys.argv[1],"Sources/Wand/SessionActivityAttributes.swift").write_text(text)
PY
export WAND_ACTIVITY_FIXTURE="$TEMP/content.json"
(cd "$MAIN" && ./node_modules/.bin/tsx --eval 'import {writeFileSync} from "node:fs"; import {projectLiveActivity,liveActivityPayload} from "./src/live-activity-state.ts"; const now=1800000000000; const s={id:"wire-session",sessionKind:"structured",status:"running",provider:"pi",title:"当前任务",queuedMessages:[],structuredState:{inFlight:true,engine:"core",turnStartedAt:new Date(now-30000).toISOString()}}; const before=projectLiveActivity([s,{...s,id:"wire-done"}],[],"server_a",now-5000); const done={...s,id:"wire-done",status:"idle",structuredState:{...s.structuredState,inFlight:false}}; const p=projectLiveActivity([s,done],before.entries,"server_a",now); writeFileSync(process.env.WAND_ACTIVITY_FIXTURE,liveActivityPayload(p.content,p.event,now/1000));')
printf "%s\n" "// swift-tools-version: 5.9" "import PackageDescription" 'let package = Package(name: "WandLiveActivityTests", targets: [.target(name: "Wand"), .testTarget(name: "WandTests", dependencies: ["Wand"])])' > "$TEMP/Package.swift"
swift test --package-path "$TEMP"
