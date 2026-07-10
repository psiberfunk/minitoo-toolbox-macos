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
