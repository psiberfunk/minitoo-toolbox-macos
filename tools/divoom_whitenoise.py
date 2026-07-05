#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import socket
from pathlib import Path

import send_divoom_image

DEFAULT_DEVICE_ID = 600111083
DEFAULT_DEVICE_PASSWORD = 1777733348
DEFAULT_TOKEN = 1777741943
DEFAULT_USER_ID = 404779143

NUM_CHANNELS = 8

# Confirmed by ear against real hardware, 2026-07-05.
CHANNEL_NAMES = ["fan", "frogs", "fire", "waves", "rain", "river", "birdsong", "singingbowls"]


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


def build_whitenoise_packet(
    on_off: int,
    volume: list[int],
    time_min: int = 0,
    end_status: int = 0,
    device_id: int = DEFAULT_DEVICE_ID,
    device_password: int = DEFAULT_DEVICE_PASSWORD,
    token: int = DEFAULT_TOKEN,
    user_id: int = DEFAULT_USER_ID,
) -> bytes:
    # WhiteNoiseSetRequest fields, from com/divoom/Divoom/http/request/whiteNoise/WhiteNoiseSetRequest.java.
    # MiniToo is WifiBlueArchEnum.BlueArchMode, so WhiteNoiseModel.e() sends this
    # straight over Bluetooth SPP_JSON (q.s().B(...)), same path as SetClockSelectId.
    payload = {
        "Command": "WhiteNoise/Set",
        "OnOff": on_off,
        "Time": time_min,
        "EndStatus": end_status,
        "Volume": volume,
        "DeviceId": device_id,
        "DevicePassword": device_password,
        "Token": token,
        "UserId": user_id,
    }
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
    return send_divoom_image.frame(0x01, body)


def build_whitenoise_get_packet(
    device_id: int = DEFAULT_DEVICE_ID,
    device_password: int = DEFAULT_DEVICE_PASSWORD,
    token: int = DEFAULT_TOKEN,
    user_id: int = DEFAULT_USER_ID,
) -> bytes:
    payload = {
        "Command": "WhiteNoise/Get",
        "DeviceId": device_id,
        "DevicePassword": device_password,
        "Token": token,
        "UserId": user_id,
    }
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
    return send_divoom_image.frame(0x01, body)


def main() -> int:
    parser = argparse.ArgumentParser(description="Control Divoom MiniToo white noise sounds over the RFCOMM daemon")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=40583)
    parser.add_argument("--out-dir", type=Path, default=Path("captures/mac-send"))
    parser.add_argument("--daemon-dry-run", action="store_true")
    parser.add_argument("--build-only", action="store_true")

    sub = parser.add_subparsers(dest="action", required=True)

    p_get = sub.add_parser("get", help="query current white noise state")

    p_set = sub.add_parser("set", help="turn on one channel at a given volume, all others silent")
    p_set.add_argument("channel", help=f"channel index 0-{NUM_CHANNELS - 1} or name: {', '.join(CHANNEL_NAMES)}")
    p_set.add_argument("volume", type=int, help="volume 0-100 for that channel")
    p_set.add_argument("--time", type=int, default=0, help="sleep timer minutes, 0=permanent")

    p_off = sub.add_parser("off", help="turn off white noise (OnOff=0, all channels silent)")

    args = parser.parse_args()

    if args.action == "get":
        packet = build_whitenoise_get_packet()
        name = "whitenoise-get"
    elif args.action == "off":
        packet = build_whitenoise_packet(on_off=0, volume=[0] * NUM_CHANNELS)
        name = "whitenoise-off"
    else:
        if args.channel.lower() in CHANNEL_NAMES:
            channel = CHANNEL_NAMES.index(args.channel.lower())
        else:
            try:
                channel = int(args.channel)
            except ValueError:
                parser.error(f"channel must be an index 0-{NUM_CHANNELS - 1} or one of: {', '.join(CHANNEL_NAMES)}")
        if not (0 <= channel < NUM_CHANNELS):
            parser.error(f"channel must be 0-{NUM_CHANNELS - 1}")
        volume = [0] * NUM_CHANNELS
        volume[channel] = max(0, min(100, args.volume))
        packet = build_whitenoise_packet(on_off=1, volume=volume, time_min=args.time)
        name = f"whitenoise-{CHANNEL_NAMES[channel]}-{args.volume}"

    args.out_dir.mkdir(parents=True, exist_ok=True)
    out_path = args.out_dir / f"{name}-packets-lenpref.bin"
    out_path.write_bytes(len(packet).to_bytes(2, "little") + packet)

    print(f"packet={out_path} len={len(packet)}")
    print(packet.hex())

    if args.build_only:
        return 0
    resp = submit(args.host, args.port, out_path, dry_run=args.daemon_dry_run)
    print("daemon:", json.dumps(resp, ensure_ascii=False))
    return 0 if resp.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
