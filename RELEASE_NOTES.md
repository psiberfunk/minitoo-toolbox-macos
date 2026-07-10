# Divoom MiniToo alpha

This is an early personal alpha build for macOS 12 and later.

- Native Bluetooth scan/pairing; no Homebrew `blueutil` dependency.
- Normal 128×128 Send Media (still images, GIFs, and video) and Photo Album
  uploads have been hardware-tested on a MiniToo.
- FFmpeg is bundled for video conversion; the exact corresponding source
  archive is attached to this release under LGPL v2.1 or later.
- **Known hold:** Send Media full-screen (160×128) is disabled after a
  regression caused an unacknowledged device crash. Photo Album's separate
  160×128 JPEG protocol remains available.
- Video preview displays the first encoded frame; the device receives the
  animation frames.
- White Noise transport works; its display-mode behavior is accepted as-is.

The app is ad-hoc signed and not notarized. On first launch, try to open it,
then use **System Settings → Privacy & Security → Open Anyway** and confirm
**Open**. See the included `INSTALLING.md` for the user-run Terminal fallback
if that button is unavailable.
