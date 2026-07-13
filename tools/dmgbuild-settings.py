"""Deterministic Finder layout for the user-facing DMG.

The background is 793x496 logical pixels (with an @2x counterpart). Its two
reserved panels are centered at these coordinates, so Finder's real app and
INSTALLING.md icons land inside them rather than being baked into the artwork.
"""

from pathlib import Path

# dmgbuild executes settings files without defining ``__file__``. Both local
# verification and release CI invoke it from the repository root.
ROOT = Path.cwd()
APP = ROOT / "MiniToo Toolbox.app"
if not APP.is_dir():
    # This makes local verification convenient; release CI assembles at ROOT.
    APP = ROOT / "build" / "MiniToo Toolbox.app"

files = [str(APP), str(ROOT / "INSTALLING.md")]
format = "UDZO"
background = str(ROOT / "assets" / "dmg" / "dmg-background.png")

# window_rect's height is the whole Finder window frame, not the content
# viewport. A plain titled/closable/miniaturizable/resizable window with
# no toolbar reserves 32pt of title bar on top of the content area on this
# macOS version (measured via NSWindow.frameRect(forContentRect:styleMask:)),
# but that alone still left a ~1pt residual crop on the background's edge
# border even with Status Bar/Path Bar off (confirmed by manually resizing
# a real mounted copy until the crop disappeared: 793x529 was the minimum,
# vs. 793x528 from the title-bar math alone) — some additional fixed inset
# this macOS version's icon view reserves beyond pure window chrome.
# +4 covers that plus a small margin. This does NOT cover the case where
# the user's Finder has Status Bar/Path Bar on: those are the user's own
# global View-menu preference, not a per-window .DS_Store setting despite
# show_status_bar/show_pathbar below (confirmed ineffective by an A/B
# test — building with both forced True rendered identically to False).
# When shown, they visibly consume space from this same fixed-size
# content area rather than growing the window to compensate, cropping the
# bottom of the artwork for users who have them on.
window_rect = ((100, 100), (793, 496 + 32 + 4))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 112
text_size = 13

# Finder's `Iloc` coordinates address the upper-left of its icon cell, not
# the visual centre of the icon.  With this 112pt icon / 13pt label setup the
# centre is rendered 72pt down and to the right of the saved location.  The
# artwork's panels are centred at (195, 258) and (597, 258), so store their
# corresponding Finder locations rather than their visual centres.  Saving
# the panel centres directly here is what produced the 72pt lower-right
# offset visible in the released DMG.
_FINDER_ICON_CELL_CENTER_OFFSET = 72
icon_locations = {
    "MiniToo Toolbox.app": (195 - _FINDER_ICON_CELL_CENTER_OFFSET, 258 - _FINDER_ICON_CELL_CENTER_OFFSET),
    "INSTALLING.md": (597 - _FINDER_ICON_CELL_CENTER_OFFSET, 258 - _FINDER_ICON_CELL_CENTER_OFFSET),
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
