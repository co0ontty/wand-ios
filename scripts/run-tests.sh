#!/usr/bin/env bash
# 构建并运行 iOS WandTests（模拟器 XCTest）。
#
# 用法：
#   ./scripts/run-tests.sh                                  # 全部 WandTests
#   ./scripts/run-tests.sh WandTests.FocusComposerTests      # 单个测试类
#   ./scripts/run-tests.sh WandTests.FocusComposerTests/testExpandedEditorUsesFullWidthForEmptySingleAndMultilineDrafts
#   DERIVED_DATA=/tmp/wand-ios-tests ./scripts/run-tests.sh  # 自定义派生数据
#   SIMULATOR_ID=<udid> ./scripts/run-tests.sh               # 指定已存在的模拟器
#
# 为什么需要这个脚本（不要各处手拼 xcodebuild）：
#   1. `parallelizable` 在 Wand.xcscheme 里已设为 "NO"，但任何调用方仍可能
#      用命令行参数重新打开并行。本脚本显式传 `-parallel-testing-enabled NO`，
#      避免 xcodebuild 克隆多个模拟器把整机 CPU/IO 打满（曾实测克隆 5 个、
#      约 1086 个模拟器子进程、load average 877）。
#   2. 先 `build-for-testing` 再 `test-without-building`，编译失败立即退出，
#      不会去复用旧测试产物冒充本轮结果。
#   3. 统一 CODE_SIGNING_ALLOWED=NO（模拟器不需要签名）。
set -euo pipefail

# Local opt-in storage policy; unconfigured machines and CI retain normal paths.
NATIVE_BUILD_ENV="${WAND_NATIVE_BUILD_ENV:-$HOME/.config/wand-build/environment.sh}"
if [[ -f "$NATIVE_BUILD_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$NATIVE_BUILD_ENV"
elif [[ -n "${WAND_NATIVE_BUILD_ENV:-}" ]]; then
  echo "Native build environment file not found: $NATIVE_BUILD_ENV" >&2
  exit 1
fi

if [[ "$(uname)" != "Darwin" ]]; then
  echo "错误：run-tests.sh 只能在安装了 Xcode 的 macOS 上运行。" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

# 与 build.sh 一致：xcode-select 指向 CommandLineTools 时回退到完整 Xcode。
if ! xcodebuild -version >/dev/null 2>&1; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "❌ xcodebuild 不可用：请安装完整 Xcode 并执行 sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "错误：找不到 xcrun。" >&2
  exit 1
fi

DEFAULT_DD="$PWD/.debug-derived-data"
if [[ -n "${WAND_BUILD_STORAGE_ROOT:-}" ]]; then
  DEFAULT_DD="$WAND_BUILD_STORAGE_ROOT/ios/tests"
fi
DERIVED_DATA="${DERIVED_DATA:-$DEFAULT_DD}"
if type wand_assert_external_build_path >/dev/null 2>&1; then
  wand_assert_external_build_path "$DERIVED_DATA"
fi
mkdir -p "$DERIVED_DATA"
DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"

FILTER="${1:-}"
BUILD_LOG="$DERIVED_DATA/build-for-testing.log"
TEST_LOG="$DERIVED_DATA/xctest.log"

# 编译阶段用通用目的地：不需要具体设备，模拟器不可用时仍能拿到编译验证。
# 测试阶段才落到具体设备上（test 不接受 generic/platform）。
BUILD_ARGS=(
  -project Wand.xcodeproj
  -scheme Wand
  -configuration Debug
  -destination 'generic/platform=iOS Simulator'
  -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
)

echo "==> build-for-testing（日志：${BUILD_LOG}）"
if xcodebuild "${BUILD_ARGS[@]}" build-for-testing >"$BUILD_LOG" 2>&1; then
  grep -E 'warning: .*Wand/.*\.swift|TEST BUILD SUCCEEDED' "$BUILD_LOG" || true
else
  STATUS=$?
  grep -E 'error:|TEST BUILD FAILED' "$BUILD_LOG" || true
  echo "构建失败（退出码 ${STATUS}），未运行任何旧测试产物：${BUILD_LOG}" >&2
  exit "$STATUS"
fi

if [[ "${BUILD_ONLY:-0}" == "1" ]]; then
  echo "==> BUILD_ONLY=1，跳过模拟器运行"
  exit 0
fi

# 模拟器设备集不可用时给出明确原因，而不是让 xcodebuild 抛一大段 XML。
if ! xcrun simctl list devices available >/dev/null 2>&1; then
  echo "❌ 无法读取模拟器设备集（CoreSimulator 不可用）；编译已通过，测试未运行。" >&2
  echo "   常见原因：~/Library/Developer/CoreSimulator/Devices 指向的卷不可读或已损坏。" >&2
  echo "   排查：xcrun simctl list devices available" >&2
  exit 1
fi

# 显式指定模拟器；未指定时取第一个可用 iPhone。
if [[ -n "${SIMULATOR_ID:-}" ]]; then
  DESTINATION_ID="$SIMULATOR_ID"
else
  DESTINATION_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')"
  if [[ -z "$DESTINATION_ID" ]]; then
    echo "❌ 没有可用的 iPhone 模拟器；请在 Xcode 里安装 iOS runtime 或创建一台设备。" >&2
    exit 1
  fi
fi

echo "==> 模拟器 $DESTINATION_ID"
TEST_ARGS=(
  -project Wand.xcodeproj
  -scheme Wand
  -configuration Debug
  -destination "platform=iOS Simulator,id=$DESTINATION_ID"
  -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
)

if [[ -n "$FILTER" ]]; then
  # 允许 "WandTests/FooTests"、"WandTests.FooTests"、"FooTests" 三种写法。
  NORMALIZED="${FILTER#WandTests/}"
  NORMALIZED="${NORMALIZED#WandTests.}"
  TEST_ARGS+=("-only-testing:WandTests/$NORMALIZED")
else
  TEST_ARGS+=(-only-testing:WandTests)
fi

echo "==> test-without-building（日志：${TEST_LOG}）"
set +e
xcodebuild "${TEST_ARGS[@]}" test-without-building >"$TEST_LOG" 2>&1
STATUS=$?
set -e
grep -E 'error:|Test Case .* failed|Executed [0-9]+ tests|\*\* TEST' "$TEST_LOG" | tail -30 || true
if [[ $STATUS -ne 0 ]]; then
  echo "测试失败（退出码 ${STATUS}）：${TEST_LOG}" >&2
  exit "$STATUS"
fi
# xcodebuild 可能以 0 退出但没有任何用例执行；必须有真实汇总证据。
grep -Eq 'Executed [1-9][0-9]* tests?, with ([0-9]+ tests? skipped and )?0 failures' "$TEST_LOG" || {
  echo "未发现通过的 XCTest 汇总：$TEST_LOG" >&2
  exit 1
}
echo "==> 全部通过"
