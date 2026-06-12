#!/usr/bin/env bash
# 创建/复用一个专用 iOS 模拟器，重新编译、安装并启动 Wand。
#
# 用法：
#   ./debug.sh
#   SIMULATOR_NAME="Wand Debug Pro" DEVICE_TYPE="iPhone 17 Pro" ./debug.sh

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "错误：debug.sh 只能在安装了 Xcode 的 macOS 上运行。" >&2
  exit 1
fi

for command in xcodebuild xcrun; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "错误：找不到 $command，请先安装并选择 Xcode Command Line Tools。" >&2
    exit 1
  fi
done

cd "$(dirname "$0")"

SIMULATOR_NAME="${SIMULATOR_NAME:-Wand Debug}"
DEVICE_TYPE="${DEVICE_TYPE:-iPhone Air}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.debug-derived-data}"
PROJECT="Wand.xcodeproj"
SCHEME="Wand"
BUNDLE_ID="com.wand.app"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/Wand.app"

retry() {
  local attempts="$1"
  shift
  local attempt=1
  until "$@"; do
    if (( attempt >= attempts )); then
      return 1
    fi
    echo "提示：操作失败，5 秒后重试（$attempt/$attempts）…"
    sleep 5
    xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
    xcrun simctl bootstatus "$SIMULATOR_ID" -b
    attempt=$((attempt + 1))
  done
}

RUNTIME_ID="$(
  xcrun simctl list runtimes available |
    sed -nE 's/.*(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[^ )]+).*/\1/p' |
    tail -1
)"
if [[ -z "$RUNTIME_ID" ]]; then
  echo "错误：没有找到可用的 iOS Simulator Runtime，请先在 Xcode 中安装。" >&2
  exit 1
fi

DEVICE_TYPE_ID="$(
  xcrun simctl list devicetypes |
    awk -F'[()]' -v name="$DEVICE_TYPE" '$1 ~ "^" name " $" { print $2; exit }'
)"
if [[ -z "$DEVICE_TYPE_ID" ]]; then
  DEVICE_TYPE_ID="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
  echo "提示：找不到设备类型“$DEVICE_TYPE”，改用 iPhone 17 Pro。"
fi

SIMULATOR_ID="$(
  xcrun simctl list devices available |
    awk -F'[()]' -v name="$SIMULATOR_NAME" '$1 ~ "^[[:space:]]*" name " $" { print $2; exit }'
)"

if [[ -z "$SIMULATOR_ID" ]]; then
  echo "==> 创建调试模拟器：$SIMULATOR_NAME"
  SIMULATOR_ID="$(xcrun simctl create "$SIMULATOR_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"
fi

echo "==> 启动模拟器：$SIMULATOR_NAME ($SIMULATOR_ID)"
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$SIMULATOR_ID" -b

echo "==> 重新编译 Wand"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "错误：找不到编译产物 $APP_PATH" >&2
  exit 1
fi

echo "==> 确保调试模拟器仍在运行"
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b

echo "==> 安装 Wand"
retry 3 xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

if ! xcrun simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" app >/dev/null 2>&1; then
  echo "错误：Wand 编译成功，但未能安装到 $SIMULATOR_NAME。" >&2
  exit 1
fi

echo "==> 打开 Wand"
xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" 2>/dev/null || true
retry 3 xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID"

echo ""
echo "完成：Wand 已在 $SIMULATOR_NAME 中启动。"
