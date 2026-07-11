#!/usr/bin/env bash
set -euo pipefail

# Compiles the vendored zstd 1.5.7 compression-only sources
# (tools/vendor/zstd-1.5.7/) into per-architecture object files, for direct
# linking into the menu-bar app's swiftc build. Unlike build-ffmpeg.sh, the
# source is vendored in-repo rather than downloaded — only decompress/
# dictBuilder are excluded (this app only ever compresses), so there is
# nothing to fetch, just compile.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/tools/vendor/zstd-1.5.7"
LIB="$VENDOR/lib"
ARCH="${1:?usage: build-zstd.sh <arch> (arm64|x86_64)}"
BUILD="$ROOT/build/zstd/$ARCH"
CACHE_MANIFEST="$BUILD/.cache-manifest"
BUILD_SCRIPT_HASH="$(shasum -a 256 "$0" | awk '{print $1}')"
SOURCE_HASH="$(find "$LIB" -type f \( -name '*.c' -o -name '*.h' \) -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"

case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 2 ;;
esac

cache_is_valid() {
  [[ -f "$CACHE_MANIFEST" ]] || return 1
  grep -Fxq "architecture=$ARCH" "$CACHE_MANIFEST" || return 1
  grep -Fxq "source_sha256=$SOURCE_HASH" "$CACHE_MANIFEST" || return 1
  grep -Fxq "build_script_sha256=$BUILD_SCRIPT_HASH" "$CACHE_MANIFEST" || return 1
  local obj
  while IFS= read -r obj; do
    [[ -f "$obj" ]] || return 1
  done < "$BUILD/.object-list"
}

mkdir -p "$BUILD"
if cache_is_valid; then
  echo "Using cached zstd 1.5.7 objects ($ARCH)."
  exit 0
fi
rm -f "$BUILD"/*.o "$CACHE_MANIFEST" "$BUILD/.object-list"

TARGET="$ARCH-apple-macos12.0"
object_list=()
while IFS= read -r -d '' src; do
  name="$(basename "$src" .c)"
  obj="$BUILD/$name.o"
  clang -target "$TARGET" -O2 -I"$LIB" -I"$LIB/common" -I"$LIB/compress" -c "$src" -o "$obj"
  object_list+=("$obj")
done < <(find "$LIB/common" "$LIB/compress" -name '*.c' -print0 | sort -z)

printf '%s\n' "${object_list[@]}" > "$BUILD/.object-list"
{
  printf 'architecture=%s\n' "$ARCH"
  printf 'source_sha256=%s\n' "$SOURCE_HASH"
  printf 'build_script_sha256=%s\n' "$BUILD_SCRIPT_HASH"
} > "$CACHE_MANIFEST"
echo "Built ${#object_list[@]} zstd object files ($ARCH) -> $BUILD"
