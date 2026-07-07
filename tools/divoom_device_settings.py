#!/usr/bin/env python3
"""Divoom MiniToo Device Settings: notification-sound level, temperature
unit, date format, 24-hour clock, Bluetooth auto-reconnect, remember
power-on volume, and auto power-off -- miscellaneous device settings that
turn out to share one single JSON command, not per-setting opcodes.

Decoded from two real Bluetooth HCI snoop captures of the official Divoom
Android app (2026-07-06 and 2026-07-07; same methodology as Photo
Album/Atmosphere -- see PROTOCOL.md and
~/Desktop/MiniTooProject/parse_btsnoop_rfcomm.py), not from APK tracing.

Real protocol, confirmed from the captures: the app keeps one large local
settings object and re-sends the *entire* thing as a single
{"Command":"Sys/SetConf", ...} JSON command (opcode 0x01) every time any
one field changes -- full state, not a delta. No Sys/GetConf was ever
observed; the app never reads the config back, it just trusts its own
cached state. See PROTOCOL.md's "Device Settings" section for the full
field list and what's confirmed vs. assumed.

Two settings on the same app screen -- "Shake Shake" and "Tap and Play" --
were confirmed to produce *no* Sys/SetConf field change at all across two
resends in the second capture, matching the observation that neither
triggered any save/sync indicator in the app. They're Android/phone-local
settings that never reach the MiniToo over Bluetooth, so there is nothing
to implement for them here.

This CLI always starts from the BASELINE object below and overrides only
the field(s) the user asks to change, mirroring what the real app does --
avoids clobbering the other ~30 fields (some of which look like settings
for other Divoom product lines sharing this same command) with guessed
values.
"""
from __future__ import annotations

import argparse
import json
import socket
from pathlib import Path

import send_divoom_image
from divoom_clock import DEFAULT_DEVICE_ID, DEFAULT_DEVICE_PASSWORD, DEFAULT_TOKEN, DEFAULT_USER_ID

# Captured 2026-07-06 against a real MiniToo. Account/location fields
# (DeviceId/Token/UserId/DevicePassword/Latitude/Longitude/TimeZone*)
# replaced with this project's existing shared placeholders / neutral
# blanks rather than the phone's real account+GPS values seen in the
# capture -- the device has no GPS/WiFi of its own, so these are inert
# passengers for MiniToo either way.
BASELINE: dict = {
    "AutoPowerOff": 0,
    "BluetoothAutoConnect": 0,
    "ColorTemp": 0,
    "Command": "Sys/SetConf",
    "DateFormat": 0,
    "DeviceAutoUpdate": 1,
    "DeviceId": DEFAULT_DEVICE_ID,
    "DevicePassword": DEFAULT_DEVICE_PASSWORD,
    "DisableMic": 0,
    "GyrateAngle": 0,
    "HighLight": 0,
    "Language": 0,
    "Latitude": 0.0,
    "LcdImageArray": ["", "", "", "", ""],
    "LocationCityId": 0,
    "LocationCityName": "",
    "LocationMode": 0,
    "LockScreenTime": 600,
    "Longitude": 0.0,
    "MirrorFlag": 0,
    "NotificationSound": 30,
    "OnOffVolume": 1,
    "ScreenProtection": 0,
    "ShowGrid1632": 1,
    "StartupFileId": "",
    "TemperatureMode": 0,
    "Time24Flag": 1,
    "TimeZoneMode": 0,
    "TimeZoneName": "",
    "TimeZoneValue": "",
    "Token": DEFAULT_TOKEN,
    "UserId": DEFAULT_USER_ID,
    "WhiteBalanceB": 100,
    "WhiteBalanceG": 100,
    "WhiteBalanceR": 100,
    "Wind": 0,
}

# Confirmed 2026-07-07 by cycling all six in order and reading the on-device labels.
DATE_FORMAT_NAMES = {
    0: "yyyy-mm-dd",
    1: "dd-mm-yyyy",
    2: "mm-dd-yyyy",
    3: "yyyy.mm.dd",
    4: "dd.mm.yyyy",
    5: "mm.dd.yyyy",
}
TEMPERATURE_MODE_NAMES = {0: "Celsius", 1: "Fahrenheit"}
# Confirmed 2026-07-07 by cycling all six in order; only the minute values are
# confirmed, the on-screen labels for the non-zero entries weren't read directly.
AUTO_POWER_OFF_MINUTES = [0, 30, 60, 180, 360, 720]


def submit(
    host: str,
    port: int,
    packets_path: Path,
    delay: float = 0.02,
    dry_run: bool = False,
) -> dict:
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


def build_set_conf_packet(overrides: dict) -> bytes:
    payload = {**BASELINE, **overrides}
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
    return send_divoom_image.frame(0x01, body)


def write_packets(packets: list[bytes], out_path: Path) -> Path:
    out = bytearray()
    for p in packets:
        out += len(p).to_bytes(2, "little") + p
    out_path.write_bytes(out)
    return out_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Set Divoom MiniToo device settings (Sys/SetConf) over the RFCOMM daemon")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=40583)
    parser.add_argument("--out-dir", type=Path, default=Path("captures/mac-send"))
    parser.add_argument("--daemon-dry-run", action="store_true")
    parser.add_argument("--build-only", action="store_true")

    parser.add_argument(
        "--notification-sound", type=int, default=None, metavar="0-100",
        help="notification sound level (observed 13/30/54 in a real capture; exact ceiling unconfirmed)",
    )
    parser.add_argument(
        "--temperature-mode", type=int, choices=[0, 1], default=None,
        help="0=Celsius, 1=Fahrenheit (confirmed by direct on-device observation)",
    )
    parser.add_argument(
        "--date-format", type=int, choices=[0, 1, 2, 3, 4, 5], default=None,
        help=f"0-5, confirmed: {', '.join(f'{i}={n}' for i, n in DATE_FORMAT_NAMES.items())}",
    )
    parser.add_argument(
        "--time24", type=int, choices=[0, 1], default=None,
        help="1=24-hour clock, 0=12-hour -- confirmed by direct hardware testing",
    )
    parser.add_argument(
        "--bluetooth-auto-connect", type=int, choices=[0, 1], default=None,
        help="1=enabled, 0=disabled -- confirmed by a real capture",
    )
    parser.add_argument(
        "--remember-power-on-volume", type=int, choices=[0, 1], default=None,
        help="1=enabled, 0=disabled -- confirmed by a real capture (OnOffVolume field)",
    )
    parser.add_argument(
        "--auto-power-off", type=int, choices=AUTO_POWER_OFF_MINUTES, default=None,
        help=f"minutes, confirmed values: {AUTO_POWER_OFF_MINUTES} (0=never)",
    )

    args = parser.parse_args()

    overrides: dict = {}
    if args.notification_sound is not None:
        if not (0 <= args.notification_sound <= 100):
            parser.error("--notification-sound must be 0-100")
        overrides["NotificationSound"] = args.notification_sound
    if args.temperature_mode is not None:
        overrides["TemperatureMode"] = args.temperature_mode
    if args.date_format is not None:
        overrides["DateFormat"] = args.date_format
    if args.time24 is not None:
        overrides["Time24Flag"] = args.time24
    if args.bluetooth_auto_connect is not None:
        overrides["BluetoothAutoConnect"] = args.bluetooth_auto_connect
    if args.remember_power_on_volume is not None:
        overrides["OnOffVolume"] = args.remember_power_on_volume
    if args.auto_power_off is not None:
        overrides["AutoPowerOff"] = args.auto_power_off

    if not overrides:
        parser.error(
            "nothing to set -- pass at least one of --notification-sound/--temperature-mode/"
            "--date-format/--time24/--bluetooth-auto-connect/--remember-power-on-volume/--auto-power-off"
        )

    args.out_dir.mkdir(parents=True, exist_ok=True)
    packet = build_set_conf_packet(overrides)
    out_path = write_packets([packet], args.out_dir / "device-settings-setconf-packets-lenpref.bin")
    print(f"packet={out_path}")
    print(f"overrides={overrides}")
    if args.build_only:
        return 0

    resp = submit(args.host, args.port, out_path, dry_run=args.daemon_dry_run)
    print("daemon:", json.dumps(resp, ensure_ascii=False))
    if "TemperatureMode" in overrides:
        print(f"temperature mode: {TEMPERATURE_MODE_NAMES.get(overrides['TemperatureMode'])}")
    if "DateFormat" in overrides:
        print(f"date format: {DATE_FORMAT_NAMES.get(overrides['DateFormat'])}")
    if "AutoPowerOff" in overrides:
        print(f"auto power off: {overrides['AutoPowerOff']} min")
    return 0 if resp.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
