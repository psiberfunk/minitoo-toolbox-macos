# Install MiniToo Toolbox

1. Download and open `MiniToo-Toolbox-macos-universal.dmg`.
2. Drag **MiniToo Toolbox.app** to either the system **Applications** folder
   or your user **Applications** folder (`~/Applications`).
3. Open **Terminal**, paste the following, and press Return:

```zsh
APP="$HOME/Applications/MiniToo Toolbox.app"
xattr -dr com.apple.quarantine "$APP"
open "$APP"
```

If you put the app in the system-wide **Applications** folder instead, replace
`$HOME/Applications` with `/Applications` in the first line. The command must
match the folder where the app was actually copied.

If the user-specific `~/Applications` location does not work on your Mac, try
the system-wide `/Applications` location before filing a bug report.

Run this only for the app you downloaded from this project's GitHub release.
It removes macOS's download-quarantine attribute from MiniToo Toolbox only; it
does not disable Gatekeeper globally.

If you prefer not to use Terminal, try opening the app once, then go to
**System Settings → Privacy & Security → Open Anyway** and confirm **Open**.
