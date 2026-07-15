# Install MiniToo Toolbox

1. Download and open `MiniToo-Toolbox-macos-universal.dmg`.
2. Drag **MiniToo Toolbox.app** to the system **Applications** folder.
3. Open **Terminal**, paste the following, and press Return:

```zsh
APP="/Applications/MiniToo Toolbox.app"
xattr -dr com.apple.quarantine "$APP"
open "$APP"
```

The user-specific `~/Applications` folder should also work, but it has had
less release testing. If you use it, replace `/Applications` with
`$HOME/Applications` in the first line; the command must match the folder
where the app was copied. If that location does not work, try `/Applications`
before filing a bug report.

Run this only for the app you downloaded from this project's GitHub release.
It removes macOS's download-quarantine attribute from MiniToo Toolbox only; it
does not disable Gatekeeper globally.

If you prefer not to use Terminal, try opening the app once, then go to
**System Settings → Privacy & Security → Open Anyway** and confirm **Open**.
