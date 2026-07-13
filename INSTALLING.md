# Install MiniToo Toolbox

1. Download and open `MiniToo-Toolbox-macos-universal.dmg`.
2. Drag **MiniToo Toolbox.app** to **Applications**.
3. Open **Terminal**, paste the following, and press Return:

```zsh
xattr -dr com.apple.quarantine "/Applications/MiniToo Toolbox.app"
open "/Applications/MiniToo Toolbox.app"
```

Run this only for the app you downloaded from this project's GitHub release.
It removes macOS's download-quarantine attribute from MiniToo Toolbox only; it
does not disable Gatekeeper globally.

If you prefer not to use Terminal, try opening the app once, then go to
**System Settings → Privacy & Security → Open Anyway** and confirm **Open**.
