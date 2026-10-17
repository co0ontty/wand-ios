#!/usr/bin/env bash
# Build a locally signed Ad Hoc IPA. Does not contact the developer portal or install devices.
# IOS_APP_PROFILE / IOS_WIDGET_PROFILE / IOS_TARGET_UDID are required.
# IPA_DIST_DIR is optional; deployment only happens after full local verification.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SIGNING_CONFIG="${WAND_IOS_SIGNING_CONFIG:-$HOME/.config/wand-build/ios-adhoc.env}"
if [[ -f "$SIGNING_CONFIG" ]]; then
  source "$SIGNING_CONFIG"
elif [[ -n "${WAND_IOS_SIGNING_CONFIG:-}" ]]; then
  echo "iOS signing configuration not found: $SIGNING_CONFIG" >&2
  exit 1
fi
NATIVE_BUILD_ENV="${WAND_NATIVE_BUILD_ENV:-$HOME/.config/wand-build/environment.sh}"
if [[ -f "$NATIVE_BUILD_ENV" ]]; then
  source "$NATIVE_BUILD_ENV"
elif [[ -n "${WAND_NATIVE_BUILD_ENV:-}" ]]; then
  echo "Native build environment file not found: $NATIVE_BUILD_ENV" >&2
  exit 1
fi
[[ "$(uname)" == Darwin ]] || { echo 'macOS and Xcode are required.' >&2; exit 1; }
: "${IOS_APP_PROFILE:?Set IOS_APP_PROFILE to the App Ad Hoc profile}"
: "${IOS_WIDGET_PROFILE:?Set IOS_WIDGET_PROFILE to the Widget Ad Hoc profile}"
: "${IOS_TARGET_UDID:?Set IOS_TARGET_UDID to the registered test device}"
for command in python3 xcodebuild swift security codesign; do
  command -v "$command" >/dev/null
done

TAG="$(git -C "$ROOT/.." tag --sort=-v:refname --list 'v[0-9]*' | head -1)"
VERSION="${1:-${TAG#v}-debug.$(date +%m%d%H%M)}"
if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-debug\.[0-9]{8})?$ ]]; then
  echo 'Version must be major.minor.patch or major.minor.patch-debug.MMDDHHMM.' >&2
  exit 1
fi
VERSION_CODE="$(echo "$VERSION" | awk -F. '{sub(/-.*/, "", $3); printf "%d", $1*10000+$2*100+$3}')"
BUILD_STAMP="${WAND_BUILD_STAMP:-$(date +%Y%m%d%H%M)}"
[[ "$BUILD_STAMP" =~ ^[0-9]{12}$ ]] || { echo 'Invalid WAND_BUILD_STAMP.' >&2; exit 1; }
if [[ "$VERSION" == *-debug.* ]]; then
  VERSION_CODE="$VERSION_CODE.${VERSION##*-debug.}"
fi
BUILD_ROOT="${WAND_ADHOC_BUILD_DIR:-${WAND_BUILD_STORAGE_ROOT:-$ROOT/build}/ios/adhoc/$VERSION}"
[[ "$BUILD_ROOT" == /* && ! -e "$BUILD_ROOT" ]] || { echo 'Build directory must be a new absolute path.' >&2; exit 1; }
if type wand_assert_external_build_path >/dev/null 2>&1; then
  wand_assert_external_build_path "$BUILD_ROOT"
fi
mkdir -p "$(dirname "$BUILD_ROOT")"
python3 "$ROOT/scripts/adhoc-signing.py" prepare \
  --app-profile "$IOS_APP_PROFILE" --widget-profile "$IOS_WIDGET_PROFILE" \
  --udid "$IOS_TARGET_UDID" --work "$BUILD_ROOT"

# All per-target signing overrides live in this build, not the shared dirty project.
# No -allowProvisioningUpdates: never create identities/profiles or register devices implicitly.
swift "$ROOT/scripts/generate-icons.swift" "$ROOT/Wand/Assets.xcassets/AppIcon.appiconset"
xcodebuild -project "$ROOT/Wand.xcodeproj" -scheme Wand -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$BUILD_ROOT/dd" \
  -archivePath "$BUILD_ROOT/Wand.xcarchive" -xcconfig "$BUILD_ROOT/Signing.xcconfig" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION_CODE" WAND_BUILD_STAMP="$BUILD_STAMP" archive
xcodebuild -exportArchive -archivePath "$BUILD_ROOT/Wand.xcarchive" \
  -exportOptionsPlist "$BUILD_ROOT/ExportOptions.plist" -exportPath "$BUILD_ROOT/export"
IPA="$BUILD_ROOT/wand-v$VERSION.ipa"
mv "$BUILD_ROOT/export/Wand.ipa" "$IPA"
python3 "$ROOT/scripts/adhoc-signing.py" verify --work "$BUILD_ROOT" \
  --udid "$IOS_TARGET_UDID" --ipa "$IPA" --version "$VERSION" --build-number "$VERSION_CODE"

if [[ -n "${IPA_DIST_DIR:-}" ]]; then
  PUBLISH_ARGS=(--work "$BUILD_ROOT" --destination "$IPA_DIST_DIR")
  if [[ -n "${IOS_DISTRIBUTION_CONFIG:-}" ]]; then
    PUBLISH_ARGS+=(--config "$IOS_DISTRIBUTION_CONFIG")
  fi
  python3 "$ROOT/scripts/adhoc-signing.py" publish "${PUBLISH_ARGS[@]}"
fi
echo "Verified Ad Hoc IPA: $IPA"
echo 'No device installation was performed. Use the existing HTTPS /ios/install page.'
