#!/usr/bin/env python3
"""Divoom MiniToo photo-album upload: the official app's persistent
on-device photo storage, architecturally distinct from this project's
live/ephemeral 0x8b direct-write path (send_divoom_image.py).

Decoded from a real Bluetooth HCI snoop capture of the official Divoom
Android app performing this exact action against a real MiniToo -- not
from static APK analysis, which turned out to describe an unused/outdated
code path (BluePhotoModel's JSON album-management + 12-byte photo header
+ eZip encoding all turned out to be wrong; see the memory file for the
full story of how that was ruled out).

Real protocol, confirmed byte-for-byte against the capture:
  1. {"Command":"Photo/Enter", ...} -- JSON, switches to photo view. This is
     the ONLY JSON command involved; there is no Photo/NewAlbum,
     Photo/LocalAddToAlbum, or Photo/PlayAlbum, and no album/ClockId
     addressing of any kind. It's genuinely one flat gallery.
  2. SPP_LOCAL_PICTURE (0x8F) binary transfer of a small custom "blob":
     - Announce: 5-byte body: [0x00][blob_size u32 little-endian].
     - Chunks: [0x01][blob_size u32 LE][chunk_index u16 LE][<=256B payload].
  3. The blob itself: [marker=0x1f][frame_count=1][speed u16 big-endian]
     [row_blocks][col_blocks][jpeg_length u32 big-endian][raw JPEG bytes].
     row_blocks=8, col_blocks=10 => 128x160, i.e. the full panel. The
     content is a plain, standard JPEG (not WebP, not eZip).
"""
from __future__ import annotations

import argparse
import json
import socket
from io import BytesIO
from pathlib import Path

from PIL import Image

import send_divoom_image
from divoom_clock import DEFAULT_DEVICE_ID, DEFAULT_DEVICE_PASSWORD, DEFAULT_TOKEN, DEFAULT_USER_ID

SPP_LOCAL_PICTURE = 0x8F
BLOB_MARKER = 0x1F
PANEL_WIDTH = 160
PANEL_HEIGHT = 128


def u32le(n: int) -> bytes:
    return n.to_bytes(4, "little")


def u32be(n: int) -> bytes:
    return n.to_bytes(4, "big")


def u16be(n: int) -> bytes:
    return n.to_bytes(2, "big")


def submit(host: str, port: int, packets_path: Path, delay: float = 0.02, dry_run: bool = False) -> dict:
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


def write_packets(packets: list[bytes], out_path: Path) -> Path:
    out = bytearray()
    for p in packets:
        out += len(p).to_bytes(2, "little") + p
    out_path.write_bytes(out)
    return out_path


def photo_enter_packet() -> bytes:
    payload = {
        "Command": "Photo/Enter",
        "DeviceId": DEFAULT_DEVICE_ID,
        "Token": DEFAULT_TOKEN,
        "UserId": DEFAULT_USER_ID,
    }
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
    return send_divoom_image.frame(0x01, body)


def build_photo_blob(jpeg_bytes: bytes, row_blocks: int = 8, col_blocks: int = 10, speed: int = 2000) -> bytes:
    header = bytes([BLOB_MARKER, 1]) + u16be(speed) + bytes([row_blocks, col_blocks]) + u32be(len(jpeg_bytes))
    return header + jpeg_bytes


def photo_upload_packets(blob: bytes) -> list[bytes]:
    header_body = bytes([0x00]) + u32le(len(blob))
    packets = [send_divoom_image.frame(SPP_LOCAL_PICTURE, header_body)]
    chunk_size = 256
    for seq, off in enumerate(range(0, len(blob), chunk_size)):
        chunk = blob[off : off + chunk_size]
        body = bytes([0x01]) + u32le(len(blob)) + seq.to_bytes(2, "little") + chunk
        packets.append(send_divoom_image.frame(SPP_LOCAL_PICTURE, body))
    return packets


def cmd_add_photo(args: argparse.Namespace) -> int:
    src = Image.open(args.image).convert("RGB")
    # Cover-crop to the panel's aspect ratio, matching the full-screen
    # resolution the real capture used (row_blocks=8, col_blocks=10).
    dst_ratio = args.width / args.height
    src_ratio = src.width / src.height
    if src_ratio > dst_ratio:
        new_width = round(src.height * dst_ratio)
        left = (src.width - new_width) // 2
        box = (left, 0, left + new_width, src.height)
    else:
        new_height = round(src.width / dst_ratio)
        top = (src.height - new_height) // 2
        box = (0, top, src.width, top + new_height)
    img = src.crop(box).resize((args.width, args.height), Image.Resampling.LANCZOS)

    stem = args.image.stem
    preview_path = args.out_dir / f"{stem}-album-preview-4x.png"
    img.resize((img.width * 4, img.height * 4), Image.Resampling.NEAREST).save(preview_path)

    buf = BytesIO()
    img.save(buf, format="JPEG", quality=args.quality)
    jpeg_bytes = buf.getvalue()

    blob = build_photo_blob(jpeg_bytes, row_blocks=args.height // 16, col_blocks=args.width // 16, speed=args.speed)
    packets = [photo_enter_packet()] + photo_upload_packets(blob)

    out = write_packets(packets, args.out_dir / f"album-add-photo-packets-lenpref.bin")
    print(f"jpeg={len(jpeg_bytes)}B ({args.width}x{args.height}) blob={len(blob)}B packets={len(packets)} file={out}")
    print(f"preview={preview_path}")
    if args.build_only:
        return 0
    resp = submit(args.host, args.port, out, delay=args.delay, dry_run=args.daemon_dry_run)
    print("daemon:", json.dumps(resp, ensure_ascii=False))
    return 0 if resp.get("ok") else 2


def main() -> int:
    parser = argparse.ArgumentParser(description="Upload a photo into the Divoom MiniToo's persistent on-device photo album")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=40583)
    parser.add_argument("--out-dir", type=Path, default=Path("captures/mac-send"))
    parser.add_argument("--daemon-dry-run", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_add = sub.add_parser("add-photo", help="Photo/Enter + SPP_LOCAL_PICTURE JPEG upload")
    p_add.add_argument("image", type=Path)
    p_add.add_argument("--width", type=int, default=PANEL_WIDTH)
    p_add.add_argument("--height", type=int, default=PANEL_HEIGHT)
    p_add.add_argument("--quality", type=int, default=90)
    p_add.add_argument("--speed", type=int, default=2000)
    p_add.add_argument("--delay", type=float, default=0.02)
    p_add.set_defaults(func=cmd_add_photo)

    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
