#!/usr/bin/env bash
# 在 macOS 上构建 Wand iOS 壳，产出一个【未签名】的 .ipa。
#
# 为什么不签名：免费 Apple ID 方案下，签名是在【安装时】由 sideload 工具
# （AltStore / SideStore / Sideloadly）用你自己的 Apple ID 现场完成的——它会
# 把这个未签名 IPA 重新签上你的开发者证书 + 设备描述文件再装进手机。
# 所以这里只负责编译出干净的 app 包，签名交给安装工具。
#
# 用法：
#   ./build.sh <version>            # 例如：./build.sh 1.16.0
#
# 输出：
#   build/Wand.app
#   dist/wand-v<version>.ipa   （未签名，拖进 AltStore/Sideloadly 即可）

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "❌ build.sh 只能在 macOS 上运行（当前系统 $(uname)），需要 Xcode 工具链" >&2
  exit 1
fi

for command in xcodebuild swift zip; do
if ! command -v "$command" >/dev/null 2>&1; then
  echo "❌ 找不到 $command，请先安装并配置 macOS 开发环境。" >&2
  exit 1
fi
done

resolve_xcode_dir() {
  local candidate
  for candidate in /Applications/Xcode*.app/Contents/Developer; do
    [[ -x "$candidate/usr/bin/xcodebuild" ]] || continue
    echo "$candidate"
    return 0
  done

  return 1
}

latest_tag_version() {
  local tag_source="."
  local tag
  if [[ "$(git -C .. ls-files --stage -- ios 2>/dev/null | awk 'NR == 1 { print $1 }')" == "160000" ]]; then
    tag_source=".."
  fi
  tag="$(git -C "$tag_source" tag --sort=-v:refname --list 'v[0-9]*' | head -1 | sed 's/^v//' || true)"
  if [[ -z "$tag" ]]; then
    tag="$(git tag --sort=-v:refname --list 'v[0-9]*' | head -1 | sed 's/^v//' || true)"
  fi
  echo "${tag:-0.0.0}"
}

if [[ $# -ge 1 ]]; then
  VERSION="$1"
else
  VERSION="$(latest_tag_version)-debug.$(date +%m%d%H%M)"
fi
BUILD_STAMP="${WAND_BUILD_STAMP:-}"
if [[ -z "$BUILD_STAMP" && "$VERSION" =~ -debug\.([0-9]{8})$ ]]; then
  BUILD_STAMP="$(date +%Y)${BASH_REMATCH[1]}"
fi
if [[ -n "$BUILD_STAMP" && ! "$BUILD_STAMP" =~ ^[0-9]{12}$ ]]; then
  echo "❌ WAND_BUILD_STAMP 必须是 YYYYMMDDHHMM（收到：$BUILD_STAMP）" >&2
  exit 1
fi
# 数字 build 号：major*10000 + minor*100 + patch；debug 再附时间戳，避免同号无法覆盖安装。
VERSION_CODE=$(echo "$VERSION" | awk -F. '{patch=$3; sub(/[-+].*/, "", patch); printf "%d", $1*10000+$2*100+patch}')
if [[ "$VERSION" == *-* ]]; then
  VERSION_CODE="${VERSION_CODE}.$(date +%m%d%H%M)"
fi

cd "$(dirname "$0")"
PROJECT_ROOT="$(pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
DIST_DIR="$PROJECT_ROOT/dist"
ICONSET_DIR="$PROJECT_ROOT/Wand/Assets.xcassets/AppIcon.appiconset"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> 生成 App 图标（1024 单尺寸）"
swift "$PROJECT_ROOT/scripts/generate-icons.swift" "$ICONSET_DIR"

# Liquid Glass 前置条件：必须用 Xcode 26+（iOS 26 SDK）编译链接。
# 老 SDK 编出的包在 iOS 26 设备上会被系统按「兼容模式」渲染成旧扁平外观。
# CI（ios-build.yml）已钉 runs-on: macos-26（默认 Xcode 26.x）；本地构建请自查。
if ! XCODE_VERSION_OUTPUT="$(xcodebuild -version 2>&1)"; then
  XCODE_DIR="$(resolve_xcode_dir || true)"
  if [[ -z "$XCODE_DIR" ]]; then
    echo "❌ xcodebuild 当前不可用：$XCODE_VERSION_OUTPUT" >&2
    echo "   请先安装完整的 Xcode 并执行："
    echo "   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
  fi

  echo "⚠️ 当前未使用完整 Xcode，尝试改用：$XCODE_DIR"
  export DEVELOPER_DIR="$XCODE_DIR"
  if ! XCODE_VERSION_OUTPUT="$(xcodebuild -version 2>&1)"; then
    echo "❌ 切换到 $XCODE_DIR 后仍无法调用 xcodebuild：$XCODE_VERSION_OUTPUT" >&2
    exit 1
  fi
fi

XCODE_MAJOR=$(printf '%s\n' "$XCODE_VERSION_OUTPUT" | awk 'NR==1 { gsub("\\..*$", "", $2); print $2 }')
if (( XCODE_MAJOR < 26 )); then
  echo "⚠️  当前 Xcode 主版本 $XCODE_MAJOR < 26：产物不会启用 iOS 26 Liquid Glass 外观" >&2
fi

echo "==> xcodebuild（iphoneos，未签名）"
xcodebuild \
  -project Wand.xcodeproj \
  -scheme Wand \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR/dd" \
  -destination "generic/platform=iOS" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION_CODE" \
  WAND_BUILD_STAMP="$BUILD_STAMP" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_SRC="$BUILD_DIR/dd/Build/Products/Release-iphoneos/Wand.app"
APP_DST="$BUILD_DIR/Wand.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "❌ 找不到产物 $APP_SRC" >&2
  exit 1
fi
cp -R "$APP_SRC" "$APP_DST"

echo "==> 打包未签名 IPA（Payload/Wand.app → zip）"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
cp -R "$APP_DST" "$STAGING/Payload/"

IPA_OUT="$DIST_DIR/wand-v${VERSION}.ipa"
# -X 不存额外属性，-q 安静；IPA 本质就是个 zip
( cd "$STAGING" && zip -qry "$IPA_OUT" Payload )

IPA_DIST_DIR="${IPA_DIST_DIR:-}"
if [[ -n "$IPA_DIST_DIR" ]]; then
  mkdir -p "$IPA_DIST_DIR"
  DIST_IPA="$IPA_DIST_DIR/wand-v${VERSION}.ipa"
  cp "$IPA_OUT" "$DIST_IPA"
  printf '%s\n' "$VERSION" > "$IPA_DIST_DIR/.last-debug-version"
  echo "==> 本地分发 IPA: $DIST_IPA"
fi

echo ""
echo "✅ 完成"
echo "   .app: $APP_DST"
echo "   IPA : $IPA_OUT  （未签名）"
if [[ -n "${DIST_IPA:-}" ]]; then
  echo "   dist: $DIST_IPA"
fi
echo ""
echo "下一步：签发后放到 ~/.wand/ios/，客户端即可检查并 OTA 安装。"
echo "        未签名包仍可用 SideStore / AltStore / Sideloadly 安装。详见 README.md。"
