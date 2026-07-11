# Third-party software notices

## FFmpeg

Release builds bundle the `ffmpeg` command-line executable for video input.
It is built from the unmodified FFmpeg 8.1.2 source archive using:

```text
./configure --disable-gpl --disable-nonfree --disable-debug --disable-doc --disable-ffplay --disable-network --disable-shared --enable-static --disable-programs --enable-ffmpeg
```

This configuration intentionally excludes GPL and nonfree components. FFmpeg
is used under LGPL v2.1 or later. Each release that bundles the executable
also attaches the exact corresponding `ffmpeg-8.1.2.tar.xz` source archive.
Source: https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz

Intel macOS CI installs NASM before the FFmpeg build so FFmpeg can retain its
normal optimized x86 assembly path. NASM is a build-only tool and is not
bundled with the app.

## zstd

The app compiles and links a vendored copy of zstd 1.5.7's source
(`tools/vendor/zstd-1.5.7/`) directly into the menu-bar executable, replacing
the Python `zstandard` package the app previously depended on. Only the
compression-only subset of the source tree is vendored (`lib/common/` and
`lib/compress/`; `lib/decompress/` and `lib/dictBuilder/` are excluded, since
the app only ever compresses, never decompresses). zstd is used under the
BSD 2-Clause License; the unmodified license text is included at
`tools/vendor/zstd-1.5.7/LICENSE`. Source:
https://github.com/facebook/zstd/releases/tag/v1.5.7
