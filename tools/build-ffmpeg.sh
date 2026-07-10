#!/usr/bin/env bash
set -euo pipefail

# Builds the FFmpeg command-line tool as a separate LGPL-only executable.
# The exact pristine source archive is retained for release-asset compliance.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${FFMPEG_VERSION:-8.1.2}"
BUILD="$ROOT/build/ffmpeg"
SOURCE_ARCHIVE="$BUILD/ffmpeg-$VERSION.tar.xz"
SOURCE_DIR="$BUILD/ffmpeg-$VERSION"

mkdir -p "$BUILD"
if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$SOURCE_ARCHIVE"
fi
rm -rf "$SOURCE_DIR"
tar -xf "$SOURCE_ARCHIVE" -C "$BUILD"
pushd "$SOURCE_DIR" >/dev/null
configure_args=(
  --disable-gpl --disable-nonfree --disable-debug --disable-doc --disable-ffplay
  --disable-network --disable-shared --enable-static --disable-programs --enable-ffmpeg
)
./configure "${configure_args[@]}"
make -j"$(sysctl -n hw.ncpu)"
popd >/dev/null
cp "$SOURCE_DIR/ffmpeg" "$BUILD/ffmpeg"
