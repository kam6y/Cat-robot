# /// script
# requires-python = ">=3.10"
# dependencies = ["pyserial==3.5"]
# ///
"""CatRobot 首ファームウェア用のシリアル CLI（設計書 §4.7）。

例:
  uv run tools/serial_cli.py --port /dev/cu.usbmodem101 STATUS
  uv run tools/serial_cli.py --port /dev/cu.usbmodem101 --watch
  uv run tools/serial_cli.py --port /dev/cu.usbmodem101 --encode ping 7   # → HEX 09 07

ポートを開くとき DTR/RTS を上げたまま保ち、XIAO のリセット（再起動 → BOOT_CENTER の動作）を起こさない（open_port 参照）。
"""

from __future__ import annotations

import argparse
import sys
import termios
import time

import serial

from catneck_proto import encode_text_command, hex_line


def open_port(port: str, baud: int) -> serial.Serial:
    """XIAO をリセットしないように開く。

    ESP32-C3 の USB Serial/JTAG は「RTS オン・DTR オフ」の組み合わせでチップをリセットする。
    macOS は open 時に両方をオンにするので、pyserial の既定（open 直後に DTR → RTS の順でオフ）だと
    その途中で「RTS オン・DTR オフ」を通ってリセットされる（2026-10-23 に実測: rst:0x15 USB_UART_CHIP_RESET）。
    両方オンのまま開き、HUPCL を外して close 後もオンのままにすると、open/close でリセットされない（同日実測）。
    """
    ser = serial.Serial()
    ser.port = port
    ser.baudrate = baud
    ser.timeout = 0.1
    ser.dtr = True
    ser.rts = True
    ser.open()
    attrs = termios.tcgetattr(ser.fd)
    attrs[2] &= ~termios.HUPCL
    termios.tcsetattr(ser.fd, termios.TCSANOW, attrs)
    time.sleep(0.2)  # USB CDC 側が「ホスト接続」を認識するまで少し待つ（直後の送信は応答が落ちることがある）
    ser.reset_input_buffer()
    return ser


def read_lines(ser: serial.Serial, quiet_seconds: float, max_seconds: float) -> int:
    """quiet_seconds 無入力になるか max_seconds 経つまで行を表示する。表示した行数を返す。"""
    start = time.monotonic()
    last = start
    count = 0
    while True:
        line = ser.readline()
        now = time.monotonic()
        if line:
            print(line.decode("utf-8", errors="replace").rstrip("\r\n"), flush=True)
            count += 1
            last = now
        elif now - last >= quiet_seconds or now - start >= max_seconds:
            return count


def send_line(ser: serial.Serial, line: str) -> None:
    ser.write((line + "\n").encode("ascii"))
    ser.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description="CatRobot 首ファームウェアのシリアル CLI")
    parser.add_argument("--port", required=True, help="例: /dev/cu.usbmodem101")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--quiet", type=float, default=1.0, help="応答待ちを打ち切る無入力秒数（SAVE は 3 程度）")
    parser.add_argument("--max", type=float, default=10.0, help="応答待ちの上限秒数")
    parser.add_argument("--watch", action="store_true", help="WATCH ON を送り Ctrl-C まで流し読み（終了時 WATCH OFF）")
    parser.add_argument("--encode", action="store_true",
                        help="引数を BLE と同じコマンド（move/gesture/stop/center/torque/cal/save/limits/ping）として符号化し HEX 行で送る")
    parser.add_argument("words", nargs="*", help="送る 1 行（例: STATUS / MOVE 20 -5 / GESTURE nod 15）")
    args = parser.parse_args()

    if args.encode:
        try:
            line = hex_line(encode_text_command(args.words))
        except (ValueError, KeyError) as e:
            print(f"符号化エラー: {e}", file=sys.stderr)
            return 2
    else:
        line = " ".join(args.words)
    if not line and not args.watch:
        parser.error("送る行か --watch を指定してください")

    try:
        ser = open_port(args.port, args.baud)
    except serial.SerialException as e:
        print(f"ポートを開けません: {e}", file=sys.stderr)
        return 1
    try:
        if line:
            for attempt in (1, 2):
                print(f"> {line}", flush=True)
                send_line(ser, line)
                if read_lines(ser, args.quiet, args.max) > 0:
                    break
                if attempt == 1:
                    print("(応答なし。もう一度送ります)", file=sys.stderr, flush=True)
            else:
                print("(応答なし)", file=sys.stderr, flush=True)
                return 1
        if args.watch:
            print("> WATCH ON  (Ctrl-C で終了)", flush=True)
            send_line(ser, "WATCH ON")
            try:
                while True:
                    read_lines(ser, quiet_seconds=1e9, max_seconds=0.5)
            except KeyboardInterrupt:
                pass
            finally:
                send_line(ser, "WATCH OFF")
                read_lines(ser, 0.5, 2.0)
        return 0
    finally:
        ser.close()


if __name__ == "__main__":
    sys.exit(main())
