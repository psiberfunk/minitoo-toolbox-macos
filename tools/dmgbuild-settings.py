"""Deterministic Finder layout for the user-facing DMG.

The background is 793x496 logical pixels (with an @2x counterpart). Its two
reserved panels are centered at these coordinates, so Finder's real app and
INSTALLING.md icons land inside them rather than being baked into the artwork.
"""

from pathlib import Path

# dmgbuild executes settings files without defining ``__file__``. Both local
# verification and release CI invoke it from the repository root.
ROOT = Path.cwd()
APP = ROOT / "Divoom MiniToo.app"
if not APP.is_dir():
    # This makes local verification convenient; release CI assembles at ROOT.
    APP = ROOT / "build" / "Divoom MiniToo.app"

files = [str(APP), str(ROOT / "INSTALLING.md")]
format = "UDZO"
background = str(ROOT / "assets" / "dmg" / "dmg-background.png")

# window_rect's height is the whole Finder window frame, not the content
# viewport — a plain titled/closable/miniaturizable/resizable window (no
# toolbar, matching show_toolbar below) reserves 32pt of title bar on top
# of the content area on this macOS version (measured directly via
# NSWindow.frameRect(forContentRect:styleMask:), not guessed). Without
# that allowance the 496pt-tall background doesn't fully fit the content
# viewport, forcing a vertical scrollbar to see the rest of it.
window_rect = ((100, 100), (793, 496 + 32))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {
    "Divoom MiniToo.app": (195, 258),
    "INSTALLING.md": (597, 258),
    # dmgbuild names the compiled HiDPI background ".background.tiff" and
    # relies on the leading dot plus the `hide` setting below (SetFile -a V,
    # confirmed set) to stay invisible. Neither survives a user's Finder
    # having "show hidden files" on (AppleShowAllFiles=1) — that reveals
    # dotfiles AND invisible-flagged files alike, with no OS-level way for
    # a shipped DMG to override the end user's own Finder preference. So
    # this position is not a hiding mechanism, just damage control for
    # that case: keep it inside the visible canvas (unlike an earlier
    # off-canvas attempt at (396, 1200), which expanded the icon view's
    # scrollable area and produced a large scrollbar) and out of the way
    # in a corner, instead of leaving it to Finder's own auto-placement
    # (which put it far below the fold, again requiring a big scroll).
    ".background.tiff": (30, 30),
}
hide = [".background.tiff"]
