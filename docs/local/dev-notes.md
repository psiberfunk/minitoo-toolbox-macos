# Dev notes (fork-local)

Not for upstream — personal working notes for developing this fork.

## Current code layout (fork-only, not all upstream yet)
- `tools/DivoomDaemon.swift` — standalone daemon binary, holds the actual
  `IOBluetooth` RFCOMM channel, JSON jobs over a local TCP socket.
- `tools/DivoomMenuBar.swift` — menu-bar app: daemon lifecycle, menu UI,
  `DivoomRawFrame` packet builder + native fast-path sender, device-address
  preference.
- `tools/DivoomControlCenter.swift`, `DivoomPreferences.swift`,
  `DivoomDeviceSetup.swift`, `DivoomAtmosphereIcons.swift` — SwiftUI
  windows, one `ObservableObject` model per screen. Several of these only
  exist on `personal`/open PR branches, not yet merged upstream.
- `tools/divoom_*.py` — Python CLI tools for features developed/tested
  that way.
- `tools/DivoomRFCOMM.swift` / `DivoomRFCOMMSend.swift` — standalone
  dev/debug scripts, not part of the shipped app.

## Decision: not rebasing on ztomer/divoom_lib
Zero mentions of "MiniToo" in its ~70K lines; its similarly-named "Timoo"
is a different, much lower-resolution product; its own white-noise routing
has the same wrong HTTP-only assumption already found and fixed
independently here. Its `bt_spp_rfcomm.py` transport is worth reading for
patterns if the daemon's RFCOMM robustness ever becomes a real pain point,
not worth adopting as a dependency.

## Dev/testing pace
Don't rapid-fire kill/rebuild/relaunch/send cycles against the real device
during a dev session — this can wedge the Mac's own Bluetooth stack
independent of any code change (symptom: every command reports success
while the device visibly does nothing). Check `ps -ef | grep blueutil` for
a stuck child before re-blaming the latest code change.
