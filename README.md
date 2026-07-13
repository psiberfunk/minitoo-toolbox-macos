# MiniToo Toolbox for macOS

MiniToo Toolbox is an independently maintained macOS app for controlling a
Divoom MiniToo over Bluetooth Classic. It provides a native Control Center,
menu-bar controls, media sending, device configuration, and a local RFCOMM
control service—without hardcoding a device address or bundling a Python
runtime in the shipped app.

## Project status and upstream credit

This project began as a downstream fork of
[alvinunreal/divoom-minitoo-osx](https://github.com/alvinunreal/divoom-minitoo-osx).
Thank you to its upstream author for the original foundation. MiniToo Toolbox
is now developed and released as its own independently maintained project:
its `main` branch, releases, updater channel, user interface, and feature set
are no longer the upstream development line. It is not an official Divoom app
and is not endorsed by Divoom or the upstream project.

The MiniToo protocol is unofficial and reverse-engineered. Read
[PROTOCOL.md](PROTOCOL.md) before developing against it; its safety section
blocks known-risk opcodes.

## Download and install

Download the latest universal DMG from this repository's **main-latest**
prerelease, then follow [INSTALLING.md](INSTALLING.md). The app currently uses
ad-hoc signing, so macOS may require one explicit first-launch approval.

Pre-rename/Personal-channel builds are retired and no longer receive in-app
updates. Their remaining users should install the current Main DMG manually.

## What you can do

All completed features are available from the actual macOS UI.

| Area | Available now |
| --- | --- |
| Media | Send 128×128 or full-screen 160×128 still images, GIFs, and video. |
| Photos | Add persistent still photos to the MiniToo Photo Album. |
| Display | Brightness, screen on/off, and Custom Face selection. |
| Atmosphere | Background and text-effect controls, with device-state readback where available. |
| Sound/tools | White Noise, Noise Meter, Stopwatch, Countdown, Pixel Slot launcher, and one-way Time Sync. |
| Settings | Notification level, temperature/date/clock formats, Bluetooth auto-reconnect, remembered volume, and auto power-off. |
| macOS experience | Scan/select a device, Preferences, menu-bar status, Control Center, optional Dock presence, battery display, and guided control-service recovery. |

Features that have not been confirmed from an Android HCI capture and direct
hardware testing remain unavailable rather than guessing at device commands.
Alarms and Scoreboard are examples of deliberately disabled controls.

## First-time setup

1. Power on the MiniToo and make sure another phone/tablet is not actively
   using its control connection.
2. Launch MiniToo Toolbox. It opens **Set Up Your MiniToo** if no device is
   saved.
3. Choose **Scan for Devices**, then **Use This Device** for your MiniToo.
   macOS may show its pairing prompt.
4. The app stores the selected Bluetooth address and uses it on later launches.
   Change it in **Preferences → Device → Change Device…**.

The device address is never hardcoded in this project.

## Connection and recovery

The menu distinguishes the generic Bluetooth link, the local macOS audio
route, and end-to-end device control. A filled diamond means all measured
components are ready; an outline means the MiniToo is not linked; a half-filled
diamond indicates partial or checking state. Bluetooth-off is shown explicitly.

The app starts its RFCOMM control service without deliberately disconnecting
audio. If a stale inherited connection is proven unusable, it performs one
recovery attempt. For later failures, use **Debugging Tools → Disconnect
MiniToo Bluetooth + Retry Control Service…**; that action can interrupt audio
and is deliberately confirmation-gated.

## Updates

Updater-enabled builds ask once whether to check automatically. Updates are
signed and locked to the repository/channel embedded in the app; a normal Main
build checks only the Main feed, not GitHub's generic “latest release.”
Preferences shows the source, branch, channel, commit, and build number and
offers **Check for Updates…**.

During the current ad-hoc-signing period, the update dialog offers a visible,
default-checked option to remove quarantine from the verified replacement app
before relaunch. It affects that app only; it does not change Gatekeeper
globally. Developer ID signing and notarization remain future work.

## Build from source

Requirements: macOS, Xcode Command Line Tools, and a MiniToo running firmware
343008 or later. The app is native Swift; Python is only needed for optional
standalone development/protocol tools. FFmpeg is bundled in release builds for
GIF/video decoding under LGPL terms.

```bash
bash tools/build-divoom-app.sh
cp -R "build/MiniToo Toolbox.app" /Applications/
open "/Applications/MiniToo Toolbox.app"
```

To make a universal local build on a matching Mac:

```bash
DIVOOM_ARCHS="arm64 x86_64" bash tools/build-divoom-app.sh
```

Run protocol/encoding tests with:

```bash
swift test
```

Those tests do not exercise Bluetooth hardware. A hardware-affecting feature
is only considered confirmed after direct observation on a physical MiniToo.

## Developer tools

The daemon listens locally on `127.0.0.1:40583`. The repository also retains
Python command-line tools for development and protocol work; they are not
bundled in the app. See [PROTOCOL.md](PROTOCOL.md) for packet framing and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled dependencies.

Logs and generated packet artifacts live in:

```text
~/Library/Application Support/MiniTooToolbox/
```

## Known limitations

- Device settings are last-sent values, not a device readback.
- Clock sync is one-way; the MiniToo clock cannot be read from the app.
- The device's own on-screen settings view may display stale text until you
  leave and re-enter that device menu.
- A control service cannot prove that macOS audio is playing, or reveal which
  other host may own a Bluetooth profile.
- The protocol is unofficial. Never transmit a new opcode without following
  the capture-first safety process in [PROTOCOL.md](PROTOCOL.md).

## Acknowledgements and third-party notices

MiniToo Toolbox retains attribution to its upstream foundation and to bundled
third-party components. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
for notices that apply to distributed dependencies.
