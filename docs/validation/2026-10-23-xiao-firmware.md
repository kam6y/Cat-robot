# XIAO ESP32C3 首ファームウェア 検証記録

- 設計書: `docs/superpowers/specs/2026-10-23-xiao-firmware-ble-design.md`
- 計画: `docs/superpowers/plans/2026-10-23-xiao-firmware.md`
- 環境: MacBook Air（M4）、macOS 26、PlatformIO Core 6.2.0、platform `espressif32@8.0.0`（Arduino-ESP32 3.3.12、toolchain riscv32 14.2.0）、board `seeed_xiao_esp32c3`
- 本機: XIAO ESP32C3、USB `/dev/cu.usbmodem101`、ベース MAC `E0:72:A1:1D:5E:8C`（設計書 §3.2）
- 約束: 実測は日付・条件つきで書く。実測していないことは「未実施」と書く。会話内容・鍵・トークンは書かない

## Task 1 ビルド環境（2026-10-23、利用者不在）

| 項目 | 結果 |
|---|---|
| `pio run -e xiao`（初回） | SUCCESS。RAM 4.1%、Flash 21.1% |
| `pio test -e native` | 1 件 PASS（Config の定数） |
| 書き込み・起動行の実物 | **未実施**。通常の `xiao` ビルドは起動 500 ms 後に BOOT_CENTER で首を動かすため、初回書き込みは利用者在席時に行う（計画の無人制約） |

## Task 2〜5・7 ホスト単体テスト（2026-10-23）

`pio test -e native`: Protocol 10、Axis 5、Gesture 7、SerialParser 7、Smoke 1（Planner 14 は codex の Task 4、隔離コピーで 44/44 PASS を確認）。実機は関与しない。

## Task 10 Mac 用試験ツール（2026-10-23、利用者不在、動作要求は送っていない）

| 確認 | 結果 |
|---|---|
| `uv run tools/ble_client.py --help` / `uv run tools/serial_cli.py --help` | 動作。依存（bleak 3.0.2、pyserial 3.5）は PEP 723 で uv が解決 |
| `catneck_proto.decode_status` を Task 2 の golden bytes `85 FF 2D 00 03 04 07 03 00 00 03 FA` で照合 | yaw −12.3、pitch 4.5、flags 0x0403、seq 7、state 3、err 3、save 250 → 一致 |
| `encode_move(20, −5, 100)` | `01 C8 00 CE FF 64`（`test_serial_parser` の HEX 試験と同じ列）。Calibration/Limits/Info の encode→decode 往復も一致 |
| シリアル CLI `STATUS`（本機は旧 AC5 試験ファームのまま） | `OK STATUS v=AC5 ...` を 3 回連続で受信。`uptime` が単調増加 = open/close でリセットされていない |
| BLE `scan` | 本機はまだ BLE ファームでないため対象なし。加えて scan 自体が 18 秒で戻らなかった（Bluetooth はオン）。このターミナルへの Bluetooth 権限ダイアログが未許可の可能性が高い。`scan`/`info`/`watch` の確認は Task 9 の書き込み後・利用者在席時に行う → **未実施** |
| 初回ペアリング（macOS のダイアログ） | **未実施** |

### 発見: シリアルポートを開くと XIAO がリセットされる

- pyserial の既定どおり「DTR/RTS を下げて開く」と、XIAO が `rst:0x15 (USB_UART_CHIP_RESET)` で再起動し ROM の起動行と `BOOT AC5 OUTPUTS_OFF pins=3,5` が出た（2026-10-23 実測）。ESP32-C3 の USB Serial/JTAG は「RTS オン・DTR オフ」でチップをリセットする。macOS が open 時に両方をオンにし、pyserial が DTR → RTS の順でオフにする途中でこの組み合わせを通るため
- DTR/RTS を上げたまま開き、`termios` で HUPCL を外して close 後も上げたままにする方式では、2 回連続の open/close で起動行なし、その後の `STATUS` 3 回でも `uptime` が途切れなかった（同日実測）。`tools/serial_cli.py` の `open_port` はこの方式
- 通常の `xiao` ビルドでは再起動のたびに BOOT_CENTER が出るので、この対策は「書き込みやリセットのたびに首が暴れる」（設計書 §2 アンチゴール）の回避に直結する
- `pio device monitor` も同じ経路なので `platformio.ini` に `monitor_dtr = 1` / `monitor_rts = 1` を入れた。`pio device monitor` でリセットされないことの実測は **未実施**（Task 8 の bring-up で確認する）

## 未実施一覧（利用者在席時に行う）

- `xiao_bringup`（PWM なし）の書き込みと起動行、`pio device monitor` の無リセット確認（Task 8）
- BLE の scan / info / watch、macOS のペアリング、`CatRobot-XXXX` の実名（Task 9・10）
- 動作要求を伴う確認すべて（move / gesture / demo / latency / cal save）と受入試験（Task 12）
