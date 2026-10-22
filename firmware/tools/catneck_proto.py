"""CatRobot 首ファームウェア プロトコル版 1 の符号化・復号（設計書 §4.6）。

ble_client.py と serial_cli.py が共有する。依存なし（標準ライブラリのみ）。
多バイトはリトルエンディアン。角度は 0.1° 単位 int16、速度は 0.1°/s 単位 uint16。
"""

from __future__ import annotations

import struct

SERVICE_UUID = "c47b0000-6d1f-4b9e-9c9a-2a3b4c5d6e7f"
CHAR_COMMAND = "c47b0001-6d1f-4b9e-9c9a-2a3b4c5d6e7f"
CHAR_STATUS = "c47b0002-6d1f-4b9e-9c9a-2a3b4c5d6e7f"
CHAR_CALIBRATION = "c47b0003-6d1f-4b9e-9c9a-2a3b4c5d6e7f"
CHAR_LIMITS = "c47b0004-6d1f-4b9e-9c9a-2a3b4c5d6e7f"
CHAR_INFO = "c47b0005-6d1f-4b9e-9c9a-2a3b4c5d6e7f"

NAME_PREFIX = "CatRobot-"

FLAG_BITS = [
    ("LINK", 1 << 0),
    ("TORQUE", 1 << 1),
    ("MOVING", 1 << 2),
    ("BROWNOUT", 1 << 3),
    ("SATURATED", 1 << 4),
    ("CAL_DIRTY", 1 << 5),
    ("GESTURE", 1 << 6),
    ("REJECTED", 1 << 7),
    ("RETURNING", 1 << 8),
    ("PAIR_OPEN", 1 << 9),
    ("SAVE_ERROR", 1 << 10),
]
FLAG = {name: bit for name, bit in FLAG_BITS}

STATE_NAMES = {
    0: "BOOT",
    1: "BOOT_CENTER",
    2: "IDLE",
    3: "ACTIVE",
    4: "RETURNING",
    5: "RELAX_WAIT",
}

GESTURE_IDS = {
    "nod": 1,
    "shake": 2,
    "tilt_l": 3,
    "tilt_r": 4,
    "look_up": 5,
    "look_down": 6,
}

STATUS_SIZE = 12
CALIBRATION_SIZE = 6
LIMITS_SIZE = 8
INFO_SIZE = 8


def deci(value: float) -> int:
    """度（または °/s）→ 0.1 単位の整数（四捨五入）。"""
    return int(round(float(value) * 10.0))


def _u8(value: int, name: str) -> int:
    value = int(value)
    if not 0 <= value <= 255:
        raise ValueError(f"{name} は 0〜255 で指定してください: {value}")
    return value


# ---- Command 特性へ書くバイト列 -------------------------------------------------

def encode_move(yaw_deg: float, pitch_deg: float, speed: int = 0) -> bytes:
    return struct.pack("<BhhB", 0x01, deci(yaw_deg), deci(pitch_deg), _u8(speed, "speed"))


def encode_gesture(gesture: str | int, amp_deg: float, repeats: int = 1, speed: int = 0) -> bytes:
    gesture_id = GESTURE_IDS[gesture.lower()] if isinstance(gesture, str) else int(gesture)
    if not 1 <= gesture_id <= 6:
        raise ValueError(f"GESTURE id は 1〜6: {gesture_id}")
    amp = min(255, max(0, deci(amp_deg)))  # uint8 の上限 25.5° で飽和
    return struct.pack("<BBBBB", 0x02, gesture_id, amp, _u8(repeats, "repeats"), _u8(speed, "speed"))


def encode_stop() -> bytes:
    return b"\x03"


def encode_center(speed: int = 0) -> bytes:
    return struct.pack("<BB", 0x04, _u8(speed, "speed"))


def encode_torque(on: bool) -> bytes:
    return struct.pack("<BB", 0x05, 1 if on else 0)


def encode_set_cal(yaw_off_deg: float, pitch_off_deg: float, invert: int) -> bytes:
    return struct.pack("<BhhB", 0x06, deci(yaw_off_deg), deci(pitch_off_deg), _u8(invert, "invert"))


def encode_save_cal(req: int) -> bytes:
    req = _u8(req, "req")
    if req == 0:
        raise ValueError("SAVE_CAL の req は 1〜255")
    return struct.pack("<BB", 0x07, req)


def encode_set_limits(yaw_vel: float, pitch_vel: float, yaw_ang: float, pitch_ang: float) -> bytes:
    return struct.pack("<BHHhh", 0x08, deci(yaw_vel), deci(pitch_vel), deci(yaw_ang), deci(pitch_ang))


def encode_ping(seq: int) -> bytes:
    return struct.pack("<BB", 0x09, _u8(seq, "seq"))


# ---- 特性の Read / Write ------------------------------------------------------

def decode_status(data: bytes) -> dict:
    """Status（12 B）→ dict。キー: yaw, pitch（度）, flags, seq, state, voltage（V）, rejected, save_seq。"""
    if len(data) != STATUS_SIZE:
        raise ValueError(f"Status は {STATUS_SIZE} B のはずが {len(data)} B")
    yaw, pitch, flags, seq, state, voltage, rejected, save_seq = struct.unpack("<hhHBBHBB", bytes(data))
    return {
        "yaw": yaw / 10.0,
        "pitch": pitch / 10.0,
        "flags": flags,
        "seq": seq,
        "state": state,
        "voltage": voltage / 100.0,
        "rejected": rejected,
        "save_seq": save_seq,
    }


def flag_names(flags: int) -> list[str]:
    return [name for name, bit in FLAG_BITS if flags & bit]


def has_flag(status: dict, name: str) -> bool:
    return bool(status["flags"] & FLAG[name])


def format_status(status: dict) -> str:
    names = ",".join(flag_names(status["flags"])) or "-"
    state = STATE_NAMES.get(status["state"], str(status["state"]))
    return (
        f"yaw={status['yaw']:+.1f} pitch={status['pitch']:+.1f} flags=0x{status['flags']:04X}[{names}] "
        f"seq={status['seq']} state={state} err={status['rejected']} save={status['save_seq']}"
    )


def decode_calibration(data: bytes) -> dict:
    if len(data) != CALIBRATION_SIZE:
        raise ValueError(f"Calibration は {CALIBRATION_SIZE} B のはずが {len(data)} B")
    yaw_off, pitch_off, invert, saved = struct.unpack("<hhBB", bytes(data))
    return {"yaw_off": yaw_off / 10.0, "pitch_off": pitch_off / 10.0, "invert": invert, "saved": saved}


def encode_calibration(yaw_off_deg: float, pitch_off_deg: float, invert: int) -> bytes:
    """Calibration 特性への Write（6 B。saved 欄は無視される）。"""
    return struct.pack("<hhBB", deci(yaw_off_deg), deci(pitch_off_deg), _u8(invert, "invert"), 0)


def decode_limits(data: bytes) -> dict:
    if len(data) != LIMITS_SIZE:
        raise ValueError(f"Limits は {LIMITS_SIZE} B のはずが {len(data)} B")
    yaw_vel, pitch_vel, yaw_ang, pitch_ang = struct.unpack("<HHhh", bytes(data))
    return {
        "yaw_vel": yaw_vel / 10.0,
        "pitch_vel": pitch_vel / 10.0,
        "yaw_ang": yaw_ang / 10.0,
        "pitch_ang": pitch_ang / 10.0,
    }


def encode_limits(yaw_vel: float, pitch_vel: float, yaw_ang: float, pitch_ang: float) -> bytes:
    return struct.pack("<HHhh", deci(yaw_vel), deci(pitch_vel), deci(yaw_ang), deci(pitch_ang))


def decode_info(data: bytes) -> dict:
    if len(data) != INFO_SIZE:
        raise ValueError(f"Info は {INFO_SIZE} B のはずが {len(data)} B")
    proto, major, minor, patch, hw, caps, _reserved = struct.unpack("<BBBBBBH", bytes(data))
    return {"proto": proto, "fw": f"{major}.{minor}.{patch}", "hw": hw, "caps": caps}


def format_info(info: dict) -> str:
    return f"proto={info['proto']} fw={info['fw']} hw={info['hw']} caps=0x{info['caps']:02X}"


# ---- シリアル経路の HEX 行 --------------------------------------------------------

def hex_line(payload: bytes) -> str:
    """生のプロトコルバイト列をシリアルの `HEX` 行にする（例: `HEX 09 07`）。"""
    return "HEX " + " ".join(f"{b:02X}" for b in payload)


def encode_text_command(words: list[str]) -> bytes:
    """`move 20 -5 [speed]` のような語列を Command バイト列にする（serial_cli --encode 用）。"""
    if not words:
        raise ValueError("コマンドが空です")
    verb, args = words[0].lower(), words[1:]
    if verb == "move" and 2 <= len(args) <= 3:
        return encode_move(float(args[0]), float(args[1]), int(args[2]) if len(args) == 3 else 0)
    if verb == "gesture" and 2 <= len(args) <= 4:
        gesture = int(args[0]) if args[0].isdigit() else args[0]
        repeats = int(args[2]) if len(args) >= 3 else 1
        speed = int(args[3]) if len(args) == 4 else 0
        return encode_gesture(gesture, float(args[1]), repeats, speed)
    if verb == "stop" and not args:
        return encode_stop()
    if verb == "center" and len(args) <= 1:
        return encode_center(int(args[0]) if args else 0)
    if verb == "torque" and len(args) == 1:
        return encode_torque(args[0] == "1")
    if verb == "cal" and len(args) == 3:
        return encode_set_cal(float(args[0]), float(args[1]), int(args[2]))
    if verb == "save" and len(args) == 1:
        return encode_save_cal(int(args[0]))
    if verb == "limits" and len(args) == 4:
        return encode_set_limits(*(float(a) for a in args))
    if verb == "ping" and len(args) <= 1:
        return encode_ping(int(args[0]) if args else 0)
    raise ValueError(f"符号化できない行: {' '.join(words)}")
