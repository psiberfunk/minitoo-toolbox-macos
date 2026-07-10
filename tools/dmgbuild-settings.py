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
window_rect = ((100, 100), (793, 496))
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
}
