# Divoom MiniToo alpha

This is an early independently maintained alpha build for macOS 12 and later.
It is a substantial downstream expansion of the original upstream menu-bar app.

## Highlights

- **Control Center:** a native, icon-grid Control Center brings the MiniToo's
  controls together in one place, alongside the compact menu-bar controls.
- **Media and on-device photos:** send normal 128×128 or full-screen 160×128
  still images, GIFs, and video. Add still photos to the MiniToo's persistent
  Photo Album, which survives device restarts. Video previews show the first
  encoded frame while the device receives the animation.
- **Display and ambience controls:** brightness, display on/off, Custom Faces
  1–3, White Noise (per-channel levels and device-state readback), and
  Atmosphere backgrounds/text effects are available from the UI.
- **Device settings:** configure notification level, temperature and date
  format, 12/24-hour clock, Bluetooth auto-reconnect, remembered power-on
  volume, and auto power-off. The MiniToo does not expose readback for these
  settings, so the app labels the saved values as last sent rather than live
  device state.
- **MiniToo tools:** Noise Meter, Stopwatch, Countdown, the Pixel Slot
  launcher, and Time Sync have been hardware-tested. Time Sync can set a
  custom clock value or current Mac time; its optional automatic mode repeats
  the one-way sync every 10 minutes and after a macOS clock change. Scoreboard
  and Alarms remain visibly unavailable rather than sending unverified
  commands.
- **More resilient setup and status:** scan for and select a MiniToo from the
  app—its Bluetooth address is never hardcoded—then see distinct Bluetooth,
  local-audio, and control-service health states. The app also recovers its
  control service more carefully after launch or a dropped connection.
- **Polished Mac experience:** an app icon, Preferences (including optional
  Dock icon and battery display), and a purpose-built DMG installer.
- **Signed Main-channel updates:** after first-launch consent, the app can
  check its embedded, branch-locked signed update feed and download only the
  newest compatible Main release. Preferences shows the exact source and
  build information.

FFmpeg remains bundled for GIF/video decoding; the corresponding source archive
is attached to this release under LGPL v2.1 or later.

The app is ad-hoc signed and not notarized. After dragging it from the DMG to
Applications, use the short Terminal command in the included `INSTALLING.md` to
remove quarantine from this app only and launch it. Alternatively, try opening
the app once, then use **System Settings → Privacy & Security → Open Anyway**
and confirm **Open**.

When installing a verified in-app update, the app also offers an explicit,
default-checked quarantine-removal choice before restart. It applies only to
that staged app update; it never changes Gatekeeper globally. Tested behavior
is one Gatekeeper clearance for the initial DMG install, with no additional
Gatekeeper step for subsequent in-app updates.
