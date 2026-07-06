#!/usr/bin/env python3
"""Divoom MiniToo Atmosphere selector: the app's screen for picking one of
~21 animated/static screensaver-style backgrounds (VU meters, waveforms,
starfields, cityscapes, etc.), plus a separate overlay "Text effects"
("Mixing") option layered on top of the chosen background.

Decoded from a real Bluetooth HCI snoop capture of the official Divoom
Android app (same methodology as Photo Album -- see PROTOCOL.md and
~/Desktop/MiniTooProject/parse_btsnoop_rfcomm.py), not from APK tracing.

Real protocol, confirmed from the capture:
  - {"Command":"Lyric/Enter", ...} -- JSON, switches the device into the
    Atmosphere view.
  - {"Command":"Lyric/GetConfig", ...} -- JSON, queries current config.
  - {"Command":"Lyric/SetConfig","Background":<int 0-20>,"TextEffect":<int
    0-5>, ...} -- JSON, selects a background (0-indexed, ~21 total match the
    ~21-entry grid in the app) and independently a text-effect overlay
    (0=off/none, 1-5 = the 5 non-off entries under "Text effects/Mixing").
    Confirmed by capturing 15 distinct Background selections spanning the
    observed range (0,2,6,7,8,12,13,15,17,18,19,20) and all 6 TextEffect
    values (0-5) at a fixed Background -- both fields vary independently and
    take effect immediately with no other fields required.

Not yet decoded: which Background index corresponds to which named
screensaver in the grid (the capture only gives indices, not labels), and
what each TextEffect value actually renders as. Confirm on real hardware
before assuming any specific index means a specific visual.
"""
from __future__ import annotations

import argparse
import json
import socket
from pathlib import Path

import send_divoom_image
from divoom_clock import DEFAULT_DEVICE_ID, DEFAULT_DEVICE_PASSWORD, DEFAULT_TOKEN, DEFAULT_USER_ID

NUM_BACKGROUNDS = 21
NUM_TEXT_EFFECTS = 6


def submit(
    host: str,
    port: int,
    packets_path: Path,
    delay: float = 0.02,
    dry_run: bool = False,
    wait_for_reply: float = 0,
) -> dict:
    req = {"packets": str(packets_path.resolve()), "delay": delay, "dryRun": dry_run}
    if wait_for_reply:
        req["waitForReply"] = wait_for_reply
    with socket.create_connection((host, port), timeout=10 + wait_for_reply) as s:
        s.sendall(json.dumps(req).encode() + b"\n")
        s.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            b = s.recv(4096)
            if not b:
                break
            chunks.append(b)
    return json.loads(b"".join(chunks).strip())


def _json_packet(payload: dict) -> bytes:
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
    return send_divoom_image.frame(0x01, body)


def build_enter_packet(
    device_id: int = DEFAULT_DEVICE_ID,
    token: int = DEFAULT_TOKEN,
    user_id: int = DEFAULT_USER_ID,
) -> bytes:
    return _json_packet({"Command": "Lyric/Enter", "DeviceId": device_id, "Token": token, "UserId": user_id})


def build_get_config_packet(
    device_id: int = DEFAULT_DEVICE_ID,
    token: int = DEFAULT_TOKEN,
    user_id: int = DEFAULT_USER_ID,
) -> bytes:
    return _json_packet({"Command": "Lyric/GetConfig", "DeviceId": device_id, "Token": token, "UserId": user_id})


def build_set_config_packet(
    background: int,
    text_effect: int = 0,
    device_id: int = DEFAULT_DEVICE_ID,
    token: int = DEFAULT_TOKEN,
    user_id: int = DEFAULT_USER_ID,
) -> bytes:
    return _json_packet(
        {
            "Background": background,
            "Command": "Lyric/SetConfig",
            "DeviceId": device_id,
            "TextEffect": text_effect,
            "Token": token,
            "UserId": user_id,
        }
    )


def write_packets(packets: list[bytes], out_path: Path) -> Path:
    out = bytearray()
    for p in packets:
        out += len(p).to_bytes(2, "little") + p
    out_path.write_bytes(out)
    return out_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Control Divoom MiniToo's Atmosphere screen over the RFCOMM daemon")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=40583)
    parser.add_argument("--out-dir", type=Path, default=Path("captures/mac-send"))
    parser.add_argument("--daemon-dry-run", action="store_true")
    parser.add_argument("--build-only", action="store_true")

    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("enter", help="switch the device into the Atmosphere view")
    sub.add_parser("get", help="query current Atmosphere config")
    p_set = sub.add_parser("set", help="select a background and/or text effect")
    p_set.add_argument("--background", type=int, default=None, help=f"background index 0-{NUM_BACKGROUNDS - 1}")
    p_set.add_argument("--text-effect", type=int, default=0, help=f"text effect index 0-{NUM_TEXT_EFFECTS - 1} (0=off)")

    args = parser.parse_args()

    # Each JSON command is its own single-packet job, not bundled into one
    # multi-packet job -- the daemon's multi-packet path expects the chunked
    # image/photo-transfer request/ACK handshake, which plain JSON commands
    # like these never trigger. Bundling them made the daemon falsely report
    # failure ("final ACK not observed") even though every packet was still
    # actually sent.
    if args.action == "enter":
        steps = [("atmosphere-enter", build_enter_packet(), 0)]
    elif args.action == "get":
        steps = [("atmosphere-enter", build_enter_packet(), 0), ("atmosphere-getconfig", build_get_config_packet(), 1.5)]
    else:
        if args.background is None:
            parser.error("set requires --background")
        if not (0 <= args.background < NUM_BACKGROUNDS):
            parser.error(f"--background must be 0-{NUM_BACKGROUNDS - 1}")
        if not (0 <= args.text_effect < NUM_TEXT_EFFECTS):
            parser.error(f"--text-effect must be 0-{NUM_TEXT_EFFECTS - 1}")
        steps = [
            ("atmosphere-enter", build_enter_packet(), 0),
            (
                f"atmosphere-bg{args.background}-fx{args.text_effect}",
                build_set_config_packet(args.background, args.text_effect),
                0,
            ),
        ]

    args.out_dir.mkdir(parents=True, exist_ok=True)
    last_resp: dict = {}
    for name, packet, wait_for_reply in steps:
        out_path = write_packets([packet], args.out_dir / f"{name}-packets-lenpref.bin")
        print(f"packet={out_path}")
        if args.build_only:
            continue
        last_resp = submit(args.host, args.port, out_path, dry_run=args.daemon_dry_run, wait_for_reply=wait_for_reply)
        print("daemon:", json.dumps(last_resp, ensure_ascii=False))
        if not last_resp.get("ok"):
            return 2

    if args.build_only:
        return 0
    if args.action == "get" and last_resp.get("reply"):
        print("device state:", last_resp["reply"])
    return 0 if last_resp.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
