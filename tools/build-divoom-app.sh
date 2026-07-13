#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/tools"
BUILD="$ROOT/build"
SWIFT_BUILD="$BUILD/swiftpm"
APP="$BUILD/Divoom MiniToo.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
# A space-separated list lets CI build one native slice per job, while a
# developer can make a universal app locally with DIVOOM_ARCHS="arm64 x86_64".
ARCHS="${DIVOOM_ARCHS:-$(uname -m)}"
# GitHub release builds supply their workflow run number below. A direct
# local package is not a GitHub run, so label it honestly and give its bundle
# a monotonically increasing source-revision number rather than pretending it
# is always "build 1".
LOCAL_BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
APP_VERSION="${DIVOOM_APP_VERSION:-0.1.0-alpha.local}"
BUILD_VERSION="${DIVOOM_BUILD_VERSION:-$LOCAL_BUILD_NUMBER}"
SOURCE_REPOSITORY="${DIVOOM_SOURCE_REPOSITORY:-psiberfunk/divoom-minitoo-osx}"
SOURCE_BRANCH="${DIVOOM_SOURCE_BRANCH:-$(git -C "$ROOT" branch --show-current 2>/dev/null || echo local)}"
UPDATE_CHANNEL="${DIVOOM_UPDATE_CHANNEL:-$SOURCE_BRANCH}"
UPDATE_FEED_URL="${DIVOOM_UPDATE_FEED_URL:-}"
SPARKLE_PUBLIC_KEY="${DIVOOM_SPARKLE_PUBLIC_KEY:-}"
BUILD_COMMIT="${DIVOOM_BUILD_COMMIT:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)}"
BUILD_RUN="${DIVOOM_BUILD_RUN:-local-$BUILD_VERSION}"

mkdir -p "$BUILD"
mkdir -p "$SWIFT_BUILD"
for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "unsupported architecture: $ARCH" >&2; exit 2 ;;
  esac

  SCRATCH="$SWIFT_BUILD/$ARCH"
  echo "Building Swift Package menu-bar app ($ARCH)..."
  swift build --scratch-path "$SCRATCH" --configuration release --arch "$ARCH" --product DivoomMiniToo
  echo "Building Swift Package daemon ($ARCH)..."
  swift build --scratch-path "$SCRATCH" --configuration release --arch "$ARCH" --product DivoomDaemon
  BIN_PATH="$(swift build --scratch-path "$SCRATCH" --configuration release --arch "$ARCH" --show-bin-path)"
  cp "$BIN_PATH/DivoomMiniToo" "$BUILD/divoom-menubar-$ARCH"
  cp "$BIN_PATH/DivoomDaemon" "$BUILD/divoom-daemon-$ARCH"
  if [[ ! -d "$BUILD/Sparkle.framework" ]]; then
    ditto "$BIN_PATH/Sparkle.framework" "$BUILD/Sparkle.framework"
  fi
done

build_universal_binary() {
  local output="$1"
  shift
  if [[ "$#" -eq 1 ]]; then
    cp "$1" "$output"
  else
    lipo -create "$@" -output "$output"
  fi
}

daemon_slices=()
menubar_slices=()
for ARCH in $ARCHS; do
  daemon_slices+=("$BUILD/divoom-daemon-$ARCH")
  menubar_slices+=("$BUILD/divoom-menubar-$ARCH")
done
build_universal_binary "$BUILD/divoom-daemon" "${daemon_slices[@]}"
build_universal_binary "$BUILD/divoom-menubar" "${menubar_slices[@]}"
# Keep the documented developer CLI paths current as well as the app bundle.
cp "$BUILD/divoom-daemon" "$TOOLS/divoom-daemon"
cp "$BUILD/divoom-menubar" "$TOOLS/divoom-menubar"

echo "Packaging $APP..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES/tools" "$CONTENTS/Frameworks"

cp "$BUILD/divoom-menubar" "$MACOS/DivoomMiniToo"
cp "$BUILD/divoom-daemon" "$RESOURCES/tools/divoom-daemon"
ditto "$BUILD/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
cp "$ROOT/PROTOCOL.md" "$RESOURCES/PROTOCOL.md"
cp "$ROOT/assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"
if [[ -x "$BUILD/ffmpeg/ffmpeg" ]]; then
  cp "$BUILD/ffmpeg/ffmpeg" "$RESOURCES/tools/ffmpeg"
  chmod +x "$RESOURCES/tools/ffmpeg"
fi
chmod +x "$MACOS/DivoomMiniToo" "$RESOURCES/tools/divoom-daemon"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>DivoomMiniToo</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>local.divoom.minitoo</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Divoom MiniToo</string>
  <key>CFBundleDisplayName</key>
  <string>Divoom MiniToo</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>DivoomSourceRepository</key>
  <string>$SOURCE_REPOSITORY</string>
  <key>DivoomSourceBranch</key>
  <string>$SOURCE_BRANCH</string>
  <key>DivoomUpdateChannel</key>
  <string>$UPDATE_CHANNEL</string>
  <key>DivoomUpdateFeedURL</key>
  <string>$UPDATE_FEED_URL</string>
  <key>SUFeedURL</key>
  <string>$UPDATE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <false/>
  <key>SUAllowsAutomaticUpdates</key>
  <false/>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>DivoomBuildCommit</key>
  <string>$BUILD_COMMIT</string>
  <key>DivoomBuildRun</key>
  <string>$BUILD_RUN</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Divoom MiniToo opens a Bluetooth RFCOMM channel to send images to the display.</string>
</dict>
</plist>
PLIST

# Prefer any available non-ad-hoc codesigning identity (e.g. a free "Apple
# Development" personal-team cert from Xcode, or a paid Developer ID). A
# stable (non-ad-hoc) identity keeps the same Team ID across rebuilds, so
# macOS TCC recognizes the app as the same requester and doesn't re-prompt
# for Bluetooth access every time the binary is recompiled and re-signed.
# On CI no signing identity is expected. With pipefail enabled, grep's normal
# "no match" status must not abort packaging before the ad-hoc fallback.
SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -oE '"[^"]+"' | tr -d '"' || true)"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "Signing app with $SIGNING_IDENTITY..."
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP" >/dev/null
elif command -v codesign >/dev/null 2>&1; then
  echo "warning: no codesigning identity found in keychain; falling back to ad-hoc signing (Bluetooth permission will re-prompt on every rebuild)" >&2
  codesign --force --deep --sign - "$APP" >/dev/null
fi

cat <<EOF

Built: $APP

Install:
  cp -R "$APP" /Applications/

Open:
  open "$APP"

On launch, the app automatically starts the Swift daemon without deliberately disconnecting Bluetooth, then keeps RFCOMM open when available.
EOF
