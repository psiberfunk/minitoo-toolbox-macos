# Installing Divoom MiniToo

1. Unzip the downloaded release, open the `Divoom MiniToo Release` folder,
   and drag `Divoom MiniToo.app` to **Applications**.
2. Try to open the app once. macOS will show an Apple-verification warning;
   choose **Done**.
3. Open **System Settings → Privacy & Security**, scroll to the **Security**
   section, and click **Open Anyway** for Divoom MiniToo. Confirm **Open** and
   enter your Mac password if asked. The button is available for about an hour
   after the blocked launch.

The app is ad-hoc signed for this alpha and is not notarized by Apple yet, so
this one-time confirmation is expected. Only override this warning for a copy
you downloaded from this project's GitHub release and, if desired, verified
against its published SHA-256 checksum.

## Terminal fallback

If your macOS version does not offer **Open Anyway**, you can remove the
download quarantine attribute yourself, then launch the app:

```zsh
xattr -dr com.apple.quarantine "/Applications/Divoom MiniToo.app"
open "/Applications/Divoom MiniToo.app"
```

This is intentionally shown as a command you run yourself rather than a
clickable bypass script. A downloaded script is itself subject to Gatekeeper,
and it should not silently weaken a Mac's security controls.
