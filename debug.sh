#!/bin/zsh
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
CLEAN_BUILD="${CLEAN_BUILD:-1}"
SIMCTL_TIMEOUT_SECONDS="${SIMCTL_TIMEOUT_SECONDS:-20}"
SIMCTL_BOOT_TIMEOUT_SECONDS="${SIMCTL_BOOT_TIMEOUT_SECONDS:-60}"
SIMCTL_BOOT_STATUS_TIMEOUT_SECONDS="${SIMCTL_BOOT_STATUS_TIMEOUT_SECONDS:-120}"
SIMCTL_OPERATION_TIMEOUT_SECONDS="${SIMCTL_OPERATION_TIMEOUT_SECONDS:-60}"

run_with_timeout() {
  local seconds="$1"
  local label="$2"
  shift 2

  set +e
  local output
  output="$(
    /usr/bin/perl -e '
      use strict;
      use warnings;

      my $seconds = shift @ARGV;
      my $pid = fork();
      die "fork failed: $!\n" unless defined $pid;

      if ($pid == 0) {
        exec @ARGV or die "exec failed: $!\n";
      }

      my $timed_out = 0;
      local $SIG{ALRM} = sub {
        $timed_out = 1;
        kill "TERM", $pid;
        select undef, undef, undef, 0.2;
        kill "KILL", $pid;
      };

      alarm $seconds;
      waitpid $pid, 0;
      my $status = $?;
      alarm 0;

      exit 124 if $timed_out;
      exit 1 if $status == -1;
      exit 128 + ($status & 127) if $status & 127;
      exit $status >> 8;
    ' "$seconds" "$@" 2>&1
  )"
  local command_status="$?"
  set -e

  if [[ "$command_status" -eq 124 ]]; then
    echo "错误：$label 超过 ${seconds}s 未返回，CoreSimulator 可能卡住了。" >&2
    echo "提示：如果看到 root 用户的 CoreSimulator 进程，请先运行：" >&2
    echo "  sudo pkill -9 -f 'CoreSimulator|SimulatorTrampoline|SimLaunchHost|launchd_sim|iPhoneOS.SimulatorRuntime|CoreSimulatorBridge'" >&2
    return 124
  fi

  if [[ "$command_status" -ne 0 ]]; then
    printf "%s\n" "$output" >&2
    return "$command_status"
  fi

  printf "%s\n" "$output"
}

warn_root_coresimulator() {
  local root_processes
  root_processes="$(
    ps -axo pid=,user=,comm= |
      awk '$2 == "root" && $0 ~ /CoreSimulator|SimulatorTrampoline|SimLaunchHost|launchd_sim/ { print "  " $1 " " $3 }'
  )"
  if [[ -n "$root_processes" ]]; then
    echo "警告：检测到 root 用户的 CoreSimulator 进程，simctl 可能会卡住："
    echo "$root_processes"
  fi
}

retry() {
  local attempts="$1"
  local label="$2"
  shift 2
  local attempt=1
  until run_with_timeout "$SIMCTL_OPERATION_TIMEOUT_SECONDS" "$label" "$@"; do
    if (( attempt >= attempts )); then
      return 1
    fi
    echo "提示：操作失败，5 秒后重试（$attempt/$attempts）…"
    sleep 5
    run_with_timeout "$SIMCTL_BOOT_TIMEOUT_SECONDS" "启动模拟器" xcrun simctl boot "$SIMULATOR_ID" >/dev/null || true
    run_with_timeout "$SIMCTL_BOOT_STATUS_TIMEOUT_SECONDS" "等待模拟器启动完成" xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null
    attempt=$((attempt + 1))
  done
}

RUNTIME_ID="${IOS_RUNTIME_ID:-}"
if [[ -z "$RUNTIME_ID" ]]; then
  RUNTIME_LIST="$(run_with_timeout "$SIMCTL_TIMEOUT_SECONDS" "查询 iOS Simulator Runtime" xcrun simctl list runtimes available)"
  RUNTIME_ID="$(
    printf "%s\n" "$RUNTIME_LIST" |
      sed -nE '/iOS [0-9.]+ .* - [A-Z0-9]+[a-z]\)/!s/.*(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[^ )]+).*/\1/p' |
      tail -1
  )"
fi
if [[ -z "$RUNTIME_ID" ]]; then
  RUNTIME_ID="$(
    printf "%s\n" "$RUNTIME_LIST" |
      sed -nE 's/.*(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[^ )]+).*/\1/p' |
      tail -1
  )"
fi
if [[ -z "$RUNTIME_ID" ]]; then
  echo "错误：没有找到可用的 iOS Simulator Runtime，请先在 Xcode 中安装。" >&2
  exit 1
fi
warn_root_coresimulator

DEVICE_TYPE_ID="$(
  run_with_timeout "$SIMCTL_TIMEOUT_SECONDS" "查询 iOS Simulator 设备类型" xcrun simctl list devicetypes |
    awk -F'[()]' -v name="$DEVICE_TYPE" '$1 ~ "^" name " $" { print $2; exit }'
)"
if [[ -z "$DEVICE_TYPE_ID" ]]; then
  DEVICE_TYPE_ID="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
  echo "提示：找不到设备类型“$DEVICE_TYPE”，改用 iPhone 17 Pro。"
fi

SIMULATOR_ID="$(
  run_with_timeout "$SIMCTL_TIMEOUT_SECONDS" "查询 iOS Simulator 设备列表" xcrun simctl list devices available |
    awk -F'[()]' -v name="$SIMULATOR_NAME" '$1 ~ "^[[:space:]]*" name " $" { print $2; exit }'
)"

if [[ -z "$SIMULATOR_ID" ]]; then
  echo "==> 创建调试模拟器：$SIMULATOR_NAME"
  SIMULATOR_ID="$(run_with_timeout "$SIMCTL_OPERATION_TIMEOUT_SECONDS" "创建调试模拟器" xcrun simctl create "$SIMULATOR_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"
fi

echo "==> 启动模拟器：$SIMULATOR_NAME ($SIMULATOR_ID)"
run_with_timeout "$SIMCTL_BOOT_TIMEOUT_SECONDS" "启动模拟器" xcrun simctl boot "$SIMULATOR_ID" >/dev/null || true
open -a Simulator
run_with_timeout "$SIMCTL_BOOT_STATUS_TIMEOUT_SECONDS" "等待模拟器启动完成" xcrun simctl bootstatus "$SIMULATOR_ID" -b

echo "==> 重新编译 Wand"
if [[ "$CLEAN_BUILD" == "1" ]]; then
  case "$DERIVED_DATA_PATH" in
    "$PWD"/.debug-derived-data | "$PWD"/.debug-derived-data/*)
      if ! rm -rf "$DERIVED_DATA_PATH"; then
        DERIVED_DATA_PATH="${TMPDIR:-/tmp}/wand-ios-debug-derived-data-$UID"
        APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/Wand.app"
        echo "提示：无法清理 ios/.debug-derived-data，改用 $DERIVED_DATA_PATH。"
        rm -rf "$DERIVED_DATA_PATH"
      fi
      ;;
    *)
      echo "提示：DERIVED_DATA_PATH 不在 ios/.debug-derived-data 下，跳过自动清理。"
      ;;
  esac
fi
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
run_with_timeout "$SIMCTL_BOOT_TIMEOUT_SECONDS" "启动模拟器" xcrun simctl boot "$SIMULATOR_ID" >/dev/null || true
run_with_timeout "$SIMCTL_BOOT_STATUS_TIMEOUT_SECONDS" "等待模拟器启动完成" xcrun simctl bootstatus "$SIMULATOR_ID" -b

echo "==> 安装 Wand"
retry 3 "安装 Wand" xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

if ! run_with_timeout "$SIMCTL_OPERATION_TIMEOUT_SECONDS" "验证 Wand 安装" xcrun simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" app >/dev/null; then
  echo "错误：Wand 编译成功，但未能安装到 $SIMULATOR_NAME。" >&2
  exit 1
fi

echo "==> 打开 Wand"
run_with_timeout "$SIMCTL_OPERATION_TIMEOUT_SECONDS" "停止已运行的 Wand" xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null || true
retry 3 "打开 Wand" xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID"

echo ""
echo "完成：Wand 已在 $SIMULATOR_NAME 中启动。"
