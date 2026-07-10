#!/usr/bin/env python3
"""Single frozen entry point for the menu-bar app's Python-backed actions."""

from __future__ import annotations

import sys

import divoom_album
import divoom_clock
import divoom_send


COMMANDS = {
    "send": divoom_send.main,
    "clock": divoom_clock.main,
    "album": divoom_album.main,
}


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print("usage: divoom-helper {send|clock|album} [arguments...]", file=sys.stderr)
        return 2
    command = sys.argv[1]
    sys.argv = [f"divoom-helper {command}", *sys.argv[2:]]
    return COMMANDS[command]()


if __name__ == "__main__":
    raise SystemExit(main())
