#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/tools"
BUILD="$ROOT/build"
APP="$BUILD/Divoom MiniToo.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
# A space-separated list lets CI build one native slice per job, while a
# developer can make a universal app locally with DIVOOM_ARCHS="arm64 x86_64".
ARCHS="${DIVOOM_ARCHS:-$(uname -m)}"
APP_VERSION="${DIVOOM_APP_VERSION:-0.1.0-alpha.1}"
BUILD_VERSION="${DIVOOM_BUILD_VERSION:-1}"

mkdir -p "$BUILD"

mkdir -p "$BUILD"
for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "unsupported architecture: $ARCH" >&2; exit 2 ;;
  esac

  TARGET="$ARCH-apple-macos12.0"
  echo "Building Swift daemon ($ARCH)..."
  swiftc -target "$TARGET" "$TOOLS/DivoomDaemon.swift" \
    -framework Foundation \
    -framework IOBluetooth \
    -framework Network \
    -o "$BUILD/divoom-daemon-$ARCH"

  echo "Building vendored zstd ($ARCH)..."
  bash "$TOOLS/build-zstd.sh" "$ARCH"
  ZSTD_LIB="$TOOLS/vendor/zstd-1.5.7/lib"
  ZSTD_OBJS=("$BUILD/zstd/$ARCH"/*.o)

  echo "Building menu-bar app executable ($ARCH)..."
  swiftc -target "$TARGET" "$TOOLS/DivoomMenuBar.swift" "$TOOLS/DivoomControlCenter.swift" "$TOOLS/DivoomPreferences.swift" "$TOOLS/DivoomAtmosphereIcons.swift" "$TOOLS/DivoomDeviceSetup.swift" "$TOOLS/DivoomBluetooth.swift" "$TOOLS/DivoomZstd.swift" "$TOOLS/DivoomClockFrame.swift" "$TOOLS/DivoomChunkedUpload.swift" "$TOOLS/DivoomImageResize.swift" "$TOOLS/DivoomAlbumEncode.swift" "$TOOLS/DivoomMediaEncode.swift" "$TOOLS/DivoomProcess.swift" \
    "${ZSTD_OBJS[@]}" \
    -import-objc-header "$TOOLS/vendor/zstd-1.5.7/DivoomZstdBridge.h" \
    -Xcc -I"$ZSTD_LIB" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Network \
    -framework CoreGraphics \
    -framework CoreImage \
    -framework ImageIO \
    -framework UniformTypeIdentifiers \
    -o "$BUILD/divoom-menubar-$ARCH"
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
mkdir -p "$MACOS" "$RESOURCES/tools"

cp "$BUILD/divoom-menubar" "$MACOS/DivoomMiniToo"
cp "$BUILD/divoom-daemon" "$RESOURCES/tools/divoom-daemon"
cp "$TOOLS/divoom_send.py" "$RESOURCES/tools/divoom_send.py"
cp "$TOOLS/divoom_clock.py" "$RESOURCES/tools/divoom_clock.py"
cp "$TOOLS/divoom_display.py" "$RESOURCES/tools/divoom_display.py"
cp "$TOOLS/divoom_whitenoise.py" "$RESOURCES/tools/divoom_whitenoise.py"
cp "$TOOLS/divoom_album.py" "$RESOURCES/tools/divoom_album.py"
cp "$TOOLS/divoom_atmosphere.py" "$RESOURCES/tools/divoom_atmosphere.py"
cp "$TOOLS/send_divoom_image.py" "$RESOURCES/tools/send_divoom_image.py"
cp "$ROOT/PROTOCOL.md" "$RESOURCES/PROTOCOL.md"
cp "$ROOT/assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"
if [[ -x "$BUILD/ffmpeg/ffmpeg" ]]; then
  cp "$BUILD/ffmpeg/ffmpeg" "$RESOURCES/tools/ffmpeg"
  chmod +x "$RESOURCES/tools/ffmpeg"
fi
for FROZEN_TOOL in divoom-helper; do
  if [[ -x "$BUILD/frozen/$FROZEN_TOOL" ]]; then
    # The menu app selects frozen helpers by host architecture. CI builds one
    # native helper per job; local builds place the current host's helper here.
    FROZEN_ARCH="${DIVOOM_FROZEN_ARCH:-$(uname -m)}"
    mkdir -p "$RESOURCES/tools/$FROZEN_ARCH"
    cp "$BUILD/frozen/$FROZEN_TOOL" "$RESOURCES/tools/$FROZEN_ARCH/$FROZEN_TOOL"
    chmod +x "$RESOURCES/tools/$FROZEN_ARCH/$FROZEN_TOOL"
  fi
done
chmod +x "$MACOS/DivoomMiniToo" "$RESOURCES/tools/divoom-daemon"

if [[ -x "$BUILD/frozen/divoom-helper" ]]; then
  echo "Using frozen Python tools; no virtualenv is bundled."
elif [[ -x "$ROOT/.venv/bin/python" ]]; then
  echo "Bundling Python venv..."
  ditto "$ROOT/.venv" "$RESOURCES/.venv"
  # Preserve the existing local-development behavior. Release builds use the
  # frozen executables above instead of attempting to relocate a venv.
  PY_TARGET="$(realpath "$ROOT/.venv/bin/python")"
  PY_NAME="$(basename "$PY_TARGET")"
  rm -f "$RESOURCES/.venv/bin/$PY_NAME"
  cp "$PY_TARGET" "$RESOURCES/.venv/bin/$PY_NAME"
  chmod +x "$RESOURCES/.venv/bin/$PY_NAME"
else
  echo "warning: $ROOT/.venv/bin/python not found; packaged app will fall back to system python3" >&2
fi

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
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
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

On launch, the app disconnects the Divoom audio profile once, starts the Swift daemon, and keeps RFCOMM open.
EOF
