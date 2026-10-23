# /// script
# requires-python = ">=3.10"
# dependencies = ["bleak==3.0.2"]
# ///
"""CatRobot 首ファームウェア用の Mac BLE 試験クライアント（設計書 §4.6、計画 Task 10）。

例:
  uv run tools/ble_client.py scan
  uv run tools/ble_client.py info
  uv run tools/ble_client.py watch --seconds 3
  uv run tools/ble_client.py move 20 -5 --speed 50
  uv run tools/ble_client.py gesture nod 15 --repeats 2
  uv run tools/ble_client.py cal save
  uv run tools/ble_client.py demo --hold 2

接続先は --name CatRobot-XXXX か --address <UUID>。省略時はサービス UUID または名前で 1 台だけ見つかればそれを使う。
各サブコマンドは接続を保ったまま 1 Hz で PING を送りつつ完了を待ち、--hold 秒保ってから切断する。
切断すると首は安全復帰（中立へ戻って脱力）する。これは仕様どおり。
Info 以外の特性は暗号化リンクが必要なので、初回は macOS のペアリングダイアログが出る。
"""

from __future__ import annotations

import argparse
import asyncio
import statistics
import sys
import time

from bleak import BleakClient, BleakError, BleakScanner

from catneck_proto import (
    CHAR_CALIBRATION,
    CHAR_COMMAND,
    CHAR_INFO,
    CHAR_LIMITS,
    CHAR_STATUS,
    GESTURE_IDS,
    NAME_PREFIX,
    SERVICE_UUID,
    decode_calibration,
    decode_info,
    decode_limits,
    decode_status,
    encode_center,
    encode_gesture,
    encode_move,
    encode_ping,
    encode_save_cal,
    encode_set_cal,
    encode_set_limits,
    encode_stop,
    encode_torque,
    format_info,
    format_status,
    has_flag,
)

# 設計書 付録 B の振幅（度）: small / medium / large
DEMO_AMPLITUDES = {
    "nod": (5, 10, 15),
    "shake": (8, 15, 25),
    "tilt_l": (8, 12, 15),
    "tilt_r": (8, 12, 15),
    "look_up": (8, 14, 20),
    "look_down": (8, 14, 20),
}


def is_cat_robot(device, adv) -> bool:
    name = device.name or adv.local_name or ""
    return SERVICE_UUID in (u.lower() for u in adv.service_uuids) or name.startswith(NAME_PREFIX)


async def scan(timeout: float) -> list:
    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    return [(device, adv) for device, adv in found.values() if is_cat_robot(device, adv)]


async def find_device(name: str | None, address: str | None, timeout: float):
    if address:
        device = await BleakScanner.find_device_by_address(address, timeout=timeout)
        if device is None:
            raise SystemExit(f"アドレス {address} が {timeout:.0f} 秒以内に見つかりません")
        return device
    if name:
        device = await BleakScanner.find_device_by_name(name, timeout=timeout)
        if device is None:
            raise SystemExit(f"名前 {name} が {timeout:.0f} 秒以内に見つかりません")
        return device
    candidates = await scan(timeout)
    if not candidates:
        raise SystemExit(f"CatRobot が {timeout:.0f} 秒以内に見つかりません（電源と xiao ビルドの書き込みを確認）")
    if len(candidates) > 1:
        names = ", ".join(f"{d.name or '?'} ({d.address})" for d, _ in candidates)
        raise SystemExit(f"複数見つかりました。--name か --address で指定してください: {names}")
    return candidates[0][0]


class Session:
    """接続 1 本ぶんの Status 購読とキープアライブ。"""

    def __init__(self, client: BleakClient):
        self.client = client
        self.latest: dict | None = None
        self.log_status = False
        self._waiters: list[asyncio.Future] = []
        self._seq = 0
        self._keepalive: asyncio.Task | None = None

    def _on_status(self, _characteristic, data: bytearray) -> None:
        status = decode_status(bytes(data))
        status["t"] = time.monotonic()
        self.latest = status
        if self.log_status:
            print(format_status(status))
        for future in self._waiters:
            if not future.done():
                future.set_result(status)
        self._waiters.clear()

    async def subscribe(self) -> None:
        await self.client.start_notify(CHAR_STATUS, self._on_status)

    async def read_status(self) -> dict:
        status = decode_status(bytes(await self.client.read_gatt_char(CHAR_STATUS)))
        status["t"] = time.monotonic()
        return status

    async def next_status(self, timeout: float) -> dict | None:
        future = asyncio.get_running_loop().create_future()
        self._waiters.append(future)
        try:
            return await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError:
            return None

    async def write(self, payload: bytes) -> None:
        await self.client.write_gatt_char(CHAR_COMMAND, payload, response=False)

    async def ping(self) -> None:
        self._seq = self._seq % 255 + 1
        await self.write(encode_ping(self._seq))

    def start_keepalive(self, period: float = 1.0) -> None:
        self._keepalive = asyncio.create_task(self._keepalive_loop(period))

    async def _keepalive_loop(self, period: float) -> None:
        try:
            while True:
                await self.ping()
                await asyncio.sleep(period)
        except BleakError as e:
            print(f"PING の送信に失敗: {e}")

    async def stop_keepalive(self) -> None:
        if self._keepalive is not None:
            self._keepalive.cancel()
            try:
                await self._keepalive
            except asyncio.CancelledError:
                pass
            self._keepalive = None

    async def wait_until(self, predicate, timeout: float) -> dict | None:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            status = await self.next_status(min(remaining, 1.0))
            if status is not None and predicate(status):
                return status

    async def wait_settled(self, timeout: float = 15.0) -> dict | None:
        """MOVING=0 を 0.5 秒連続で観測するまで待つ（呼び出し後に届いた Status から数える）。"""
        deadline = time.monotonic() + timeout
        quiet_since: float | None = None
        while time.monotonic() < deadline:
            status = await self.next_status(1.0)
            if status is None:
                continue
            if has_flag(status, "MOVING"):
                quiet_since = None
                continue
            if quiet_since is None:
                quiet_since = status["t"]
            elif status["t"] - quiet_since >= 0.5:
                return status
        return None

    async def wait_gesture_done(self, timeout: float = 60.0) -> dict | None:
        started = await self.wait_until(lambda s: has_flag(s, "GESTURE"), 1.0)
        if started is None:
            if self.latest is not None and has_flag(self.latest, "REJECTED"):
                print("GESTURE が拒否されました（REJECTED）")
                return self.latest
            print("GESTURE=1 を 1 秒以内に観測できませんでした（拒否か、ごく短い動作）")
        return await self.wait_until(lambda s: not has_flag(s, "GESTURE"), timeout)


def report(label: str, status: dict | None) -> int:
    if status is None:
        print(f"{label}: 完了を確認できませんでした（タイムアウト）")
        return 1
    print(f"{label}: {format_status(status)}")
    return 0


async def read_calibration(client: BleakClient) -> dict:
    return decode_calibration(bytes(await client.read_gatt_char(CHAR_CALIBRATION)))


async def cmd_cal_save(session: Session) -> int:
    client = session.client
    snapshot = await read_calibration(client)
    print(f"意図値（保存前の Calibration）: {snapshot}")
    current = session.latest or await session.read_status()
    req = current["save_seq"] % 255 + 1  # 直前の save_seq と異なる 1〜255
    done = None
    for attempt in range(1, 4):
        await session.write(encode_save_cal(req))
        done = await session.wait_until(lambda s: s["save_seq"] == req, 1.0)
        if done is not None:
            break
        print(f"save_seq={req} の Status が 1 秒以内に来ません。同じ req で再送（{attempt}/3）")
    if done is None:
        print("保存結果を確認できませんでした")
        return 1
    if has_flag(done, "SAVE_ERROR"):
        print(f"保存失敗（SAVE_ERROR）: {format_status(done)}")
        return 1
    after = await read_calibration(client)
    matches = after["saved"] == 1 and all(after[k] == snapshot[k] for k in ("yaw_off", "pitch_off", "invert"))
    print(f"保存後の Calibration: {after}")
    print("保存成功: 値が一致し saved=1" if matches else "保存は完了したが値が意図と一致しません（SET_CAL からやり直し）")
    return 0 if matches else 1


async def cmd_latency(session: Session, count: int) -> int:
    await session.wait_settled(5.0)
    samples: list[float] = []
    for i in range(count):
        yaw = 10.0 if i % 2 == 0 else -10.0
        started = time.monotonic()
        await session.write(encode_move(yaw, 0.0, 0))
        moving = await session.wait_until(lambda s: has_flag(s, "MOVING"), 2.0)
        if moving is None:
            print(f"{i + 1}: MOVING=1 を観測できません")
        else:
            samples.append((moving["t"] - started) * 1000.0)
            print(f"{i + 1}: {samples[-1]:.0f} ms")
        await session.wait_settled()
    if not samples:
        return 1
    print(f"MOVE 書き込み → MOVING=1: 中央値 {statistics.median(samples):.0f} ms、"
          f"最小 {min(samples):.0f} ms、最大 {max(samples):.0f} ms（{len(samples)}/{count} 件）")
    return 0


async def cmd_demo(session: Session) -> int:
    failures = 0
    for name, amplitudes in DEMO_AMPLITUDES.items():
        for amp in amplitudes:
            print(f"GESTURE {name} {amp}°")
            await session.write(encode_gesture(name, amp))
            if report("  完了", await session.wait_gesture_done()) != 0:
                failures += 1
            await asyncio.sleep(1.0)  # PING はキープアライブが 1 Hz で送り続ける
    print("demo 完了" if failures == 0 else f"demo: {failures} 件の完了を確認できませんでした")
    return 0 if failures == 0 else 1


async def dispatch(args, session: Session) -> int:
    cmd = args.cmd
    if cmd == "move":
        await session.write(encode_move(args.yaw, args.pitch, args.speed))
        return report("move", await session.wait_settled())
    if cmd == "center":
        await session.write(encode_center(args.speed))
        return report("center", await session.wait_settled())
    if cmd == "gesture":
        started = time.monotonic()
        await session.write(encode_gesture(args.gesture_name, args.amp, args.repeats, args.speed))
        done = await session.wait_gesture_done()
        print(f"  所要 {time.monotonic() - started:.2f} s（書き込みから GESTURE フラグが下りた通知まで。通知は変化時に即時）")
        return report("gesture", done)
    if cmd == "stop":
        await session.write(encode_stop())
        return report("stop", await session.next_status(2.0))
    if cmd == "torque":
        await session.write(encode_torque(args.on == 1))
        return report("torque", await session.next_status(2.0))
    if cmd == "cal":
        if args.op == "get":
            print(f"Calibration: {await read_calibration(session.client)}")
            return 0
        if args.op == "set":
            await session.write(encode_set_cal(args.yaw_off, args.pitch_off, args.invert))
            return report("cal set", await session.next_status(2.0))
        return await cmd_cal_save(session)
    if cmd == "limits":
        if args.op == "get":
            print(f"Limits: {decode_limits(bytes(await session.client.read_gatt_char(CHAR_LIMITS)))}")
            return 0
        await session.write(encode_set_limits(args.yaw_vel, args.pitch_vel, args.yaw_ang, args.pitch_ang))
        return report("limits set", await session.next_status(2.0))
    if cmd == "keepalive":
        end = time.monotonic() + args.seconds
        while time.monotonic() < end:
            await asyncio.sleep(1.0)
            if session.latest is not None:
                print(format_status(session.latest))
        return 0
    if cmd == "latency":
        return await cmd_latency(session, args.count)
    if cmd == "demo":
        return await cmd_demo(session)
    raise SystemExit(f"未対応のサブコマンド: {cmd}")


BLUETOOTH_HINT = ("スキャンが始まりません。Bluetooth がオンか、このターミナルに Bluetooth の権限があるか"
                  "（システム設定 → プライバシーとセキュリティ → Bluetooth。初回は許可ダイアログが出る）を確認してください")


async def with_scan_deadline(coro, scan_timeout: float):
    """CoreBluetooth が権限待ちで poweredOn にならないと discover が戻らないので、上限を設ける。"""
    try:
        return await asyncio.wait_for(coro, scan_timeout + 15.0)
    except asyncio.TimeoutError:
        raise SystemExit(BLUETOOTH_HINT) from None


async def cmd_scan(args) -> int:
    candidates = await with_scan_deadline(scan(args.scan_timeout), args.scan_timeout)
    if not candidates:
        print("CatRobot は見つかりませんでした")
        return 1
    for device, adv in candidates:
        print(f"{device.name or adv.local_name or '?'}  address={device.address}  rssi={adv.rssi}  "
              f"services={[u for u in adv.service_uuids]}")
    return 0


async def cmd_reconnect(args) -> int:
    device = await with_scan_deadline(find_device(args.name, args.address, args.scan_timeout), args.scan_timeout)
    for round_no in (1, 2):
        started = time.monotonic()
        async with BleakClient(device, timeout=args.connect_timeout) as client:
            info = decode_info(bytes(await client.read_gatt_char(CHAR_INFO)))
            status = decode_status(bytes(await client.read_gatt_char(CHAR_STATUS)))  # 暗号化の再確立まで含める
            print(f"接続 {round_no}: {format_info(info)} / {format_status(status)}"
                  f"（接続開始から暗号化 Read 完了まで {time.monotonic() - started:.2f} s）")
        print(f"切断 {round_no}")
        if round_no == 1:
            await asyncio.sleep(1.0)
    print("reconnect 成功（設計書 §4.9 / T-FW-7: 2 回目が 5 秒以内）")
    return 0


async def run(args) -> int:
    if args.cmd == "scan":
        return await cmd_scan(args)
    if args.cmd == "reconnect":
        return await cmd_reconnect(args)
    device = await with_scan_deadline(find_device(args.name, args.address, args.scan_timeout), args.scan_timeout)

    def on_disconnect(_client) -> None:
        print("切断されました")

    client = BleakClient(device, disconnected_callback=on_disconnect, timeout=args.connect_timeout)
    await client.connect()
    print(f"接続: {device.name or '?'} ({device.address})")
    session: Session | None = None
    try:
        if args.cmd == "info":
            print(format_info(decode_info(bytes(await client.read_gatt_char(CHAR_INFO)))))
            return 0
        session = Session(client)
        # 暗号化が必要な Status を先に読んでペアリングを起こす。Command は応答なし書き込みなので、
        # 未ペアのまま書いても ATT エラーが返らず macOS はペアリングを始めない。Notify も暗号化後にしか届かない
        await session.read_status()
        await session.subscribe()
        if args.cmd == "watch":
            session.log_status = True
            await asyncio.sleep(args.seconds)
            return 0
        if not args.no_ping:
            session.start_keepalive()
        rc = await dispatch(args, session)
        if args.hold > 0:
            print(f"{args.hold:.0f} 秒保持（{'PING なし: 3 秒で安全復帰するはず' if args.no_ping else 'PING 継続'}）…")
            session.log_status = args.no_ping  # PING なしの保持中は STATUS を流して復帰の経過を見せる
            await asyncio.sleep(args.hold)
            session.log_status = False
        return rc
    except BleakError as e:
        # 切断時のエラーで本体のエラーを隠さない（暗号化が必要な特性でのペアリング失敗など）
        print(f"BLE エラー（{args.cmd}）: {e}", file=sys.stderr)
        return 1
    finally:
        if session is not None:
            await session.stop_keepalive()
        print("切断します（首は安全復帰して脱力します）")
        try:
            await client.disconnect()
        except BleakError as e:
            print(f"切断時のエラー（無視）: {e}", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="CatRobot 首ファームウェアの BLE 試験クライアント")
    parser.add_argument("--name", help="例: CatRobot-5E8E")
    parser.add_argument("--address", help="CoreBluetooth の UUID（scan で表示）")
    parser.add_argument("--scan-timeout", type=float, default=5.0)
    parser.add_argument("--connect-timeout", type=float, default=20.0)
    parser.add_argument("--hold", type=float, default=0.0, help="完了後に接続を保つ秒数（既定 0）")
    parser.add_argument("--no-ping", action="store_true", help="キープアライブ PING を送らない（3 秒無通信の安全復帰を見る）")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan", help="CatRobot を探す")
    sub.add_parser("info", help="Info を読む（暗号化不要）")
    p = sub.add_parser("watch", help="Status 通知を表示")
    p.add_argument("--seconds", type=float, default=5.0)
    p = sub.add_parser("move", help="MOVE")
    p.add_argument("yaw", type=float)
    p.add_argument("pitch", type=float)
    p.add_argument("--speed", type=int, default=0, help="速度上限の %%（0 = 100）")
    p = sub.add_parser("gesture", help="GESTURE")
    # dest を分ける: 位置引数 name は --name（機器名）を上書きしてしまう
    p.add_argument("gesture_name", metavar="name", choices=sorted(GESTURE_IDS, key=GESTURE_IDS.get))
    p.add_argument("amp", type=float, help="振幅（度、最大 25.5）")
    p.add_argument("--repeats", type=int, default=1)
    p.add_argument("--speed", type=int, default=0)
    sub.add_parser("stop", help="STOP")
    p = sub.add_parser("center", help="CENTER")
    p.add_argument("--speed", type=int, default=0)
    p = sub.add_parser("torque", help="TORQUE")
    p.add_argument("on", type=int, choices=(0, 1))
    p = sub.add_parser("cal", help="Calibration: get / set YOFF POFF INVERT / save")
    cal_sub = p.add_subparsers(dest="op", required=True)
    cal_sub.add_parser("get")
    q = cal_sub.add_parser("set")
    q.add_argument("yaw_off", type=float)
    q.add_argument("pitch_off", type=float)
    q.add_argument("invert", type=int, help="bit0 ヨー、bit1 ピッチ")
    cal_sub.add_parser("save", help="設計書 §4.6 の手順で保存し照合")
    p = sub.add_parser("limits", help="Limits: get / set YV PV YA PA（0 = 変更しない）")
    lim_sub = p.add_subparsers(dest="op", required=True)
    lim_sub.add_parser("get")
    q = lim_sub.add_parser("set")
    q.add_argument("yaw_vel", type=float)
    q.add_argument("pitch_vel", type=float)
    q.add_argument("yaw_ang", type=float)
    q.add_argument("pitch_ang", type=float)
    p = sub.add_parser("keepalive", help="PING を 1 Hz で送り続ける")
    p.add_argument("--seconds", type=float, default=10.0)
    sub.add_parser("demo", help="6 種 × small/medium/large を順に再生")
    p = sub.add_parser("latency", help="MOVE 書き込み → MOVING=1 の遅延")
    p.add_argument("--count", type=int, default=10)
    sub.add_parser("reconnect", help="接続 → Info → 切断を 2 回")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        print("中断")
        return 130
    except BleakError as e:
        print(f"BLE エラー: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
