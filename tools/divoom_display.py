#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import socket
from pathlib import Path

import send_divoom_image

# Raw SppProc$CMD_TYPE opcodes (see PROTOCOL.md), reverse-engineered from the
# official Divoom Android app (com.divoom.Divoom.bluetooth.CmdManager).
CMD_SET_SYSTEM_BRIGHT = 0x74  # SPP_SET_SYSTEM_BRIGHT(116)


def submit(host: str, port: int, packets_path: Path, delay: float = 0.012, dry_run: bool = False) -> dict:
    req = {"packets": str(packets_path.resolve()), "delay": delay, "dryRun": dry_run}
    with socket.create_connection((host, port), timeout=10) as s:
        s.sendall(json.dumps(req).encode() + b"\n")
        s.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            b = s.recv(4096)
            if not b:
                break
            chunks.append(b)
    return json.loads(b"".join(chunks).strip())


def build_brightness_packet(level: int) -> bytes:
    level = max(0, min(100, level))
    return send_divoom_image.frame(CMD_SET_SYSTEM_BRIGHT, bytes([level]))


def write_packet(out_dir: Path, name: str, packet: bytes) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{name}-packets-lenpref.bin"
    out_path.write_bytes(len(packet).to_bytes(2, "little") + packet)
    return out_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Send Divoom MiniToo display settings over the RFCOMM daemon")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=40583)
    parser.add_argument("--out-dir", type=Path, default=Path("captures/mac-send"))
    parser.add_argument("--daemon-dry-run", action="store_true")
    parser.add_argument("--build-only", action="store_true")

    sub = parser.add_subparsers(dest="action", required=True)

    p_bright = sub.add_parser("brightness", help="set screen brightness 0-100")
    p_bright.add_argument("level", type=int, help="brightness level 0-100")

    args = parser.parse_args()

    packet = build_brightness_packet(args.level)
    name = f"brightness-{args.level}"

    out_path = write_packet(args.out_dir, name, packet)
    print(f"packet={out_path} len={len(packet)}")
    print(packet.hex())

    if args.build_only:
        return 0
    resp = submit(args.host, args.port, out_path, dry_run=args.daemon_dry_run)
    print("daemon:", json.dumps(resp, ensure_ascii=False))
    return 0 if resp.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
