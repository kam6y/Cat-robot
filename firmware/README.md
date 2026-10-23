# Cat Robot 首ファームウェア（XIAO ESP32C3）

iPhone アプリから BLE で首（ヨー・ピッチの 2 軸サーボ）を動かすファームウェアと、Mac 用の試験ツール。設計は
[設計書](../docs/superpowers/specs/2026-10-23-xiao-firmware-ble-design.md)、実測は
[検証記録](../docs/validation/2026-10-23-xiao-firmware.md) にある。

## 導入（Mac）

```sh
brew install platformio   # PlatformIO Core 6.2.0 で確認
brew install uv           # 試験ツール（Python）の依存解決に使う
```

platform は `espressif32@8.0.0`（公式、Arduino-ESP32 3.3.12）に固定している。初回ビルドでツールチェーンを自動で取得する。
pioarduino への切り替えは不要だった（公式 v8.0.0 で XIAO のビルドが通った）。

## 4 つのコマンド

`firmware/` で実行する。

```sh
pio run -e xiao                                                   # ビルド（実機用。サーボ出力あり）
pio run -e xiao -t upload --upload-port /dev/cu.usbmodem101       # 書き込み
pio device monitor -p /dev/cu.usbmodem101 -b 115200               # シリアルモニタ（Ctrl-C で終了）
pio test -e native                                                # ホスト単体テスト（実機不要）
```

- ポート名は `ls /dev/cu.usbmodem*` で探す（本機は `/dev/cu.usbmodem101`。USB の差し口で番号が変わる）
- `pio run -e xiao_bringup -t upload …` はサーボ出力だけを無効にした同じファームウェア。利用者が付いていないときの
  書き込み・シリアル・BLE の確認にはこれを使う。通常の `xiao` は電源投入 500 ms 後に中立を出力して首を動かしうる
- シリアルポートを開くと XIAO がリセットされることがある（ESP32-C3 の USB Serial/JTAG は「RTS オン・DTR オフ」でリセット）。
  `platformio.ini` の `monitor_dtr = 1` / `monitor_rts = 1` と `tools/serial_cli.py` はこれを避ける開き方をしている

## 19 V と USB の注意

- 19 V を入れたまま Mac に USB でつないでよい配線（D1 で逆流しない）だが、19 V 投入中に Mac から XIAO が見えなかった
  観測がある（設計書 §7 R1）。見えないときは 19 V を切って USB だけで確認する
- USB がつながっている間は 19 V を切っても XIAO は再起動しない。再起動を伴う試験では USB も抜くか RESET を押す
- 書き込みやリセットのたびに首は 1 回だけ中立へ合わせる動作をする（位置検出がないため）。中立付近で止めてから電源を切る
- 待機中（IDLE）は PWM を止めるが、DS3218 は一度指令を受けると最後の位置を保持し続ける（サーボ電源の再投入で解ける。
  2026-10-23 実測、要件定義書 §7.4）。首を手で動かしたいときは 19 V を切る

## 試験ツール（Mac）

依存（bleak 3.0.2、pyserial 3.5）はファイル冒頭の PEP 723 ブロックで固定していて、`uv run` が解決する。

```sh
uv run tools/serial_cli.py --port /dev/cu.usbmodem101 STATUS        # 1 行送って応答を表示
uv run tools/serial_cli.py --port /dev/cu.usbmodem101 --watch       # WATCH ON の流し読み（Ctrl-C で WATCH OFF）
uv run tools/serial_cli.py --port /dev/cu.usbmodem101 --encode ping 7   # HEX 09 07 を送る（BLE と同じ復号器を通す）

uv run tools/ble_client.py scan                 # CatRobot-XXXX を探す（初回は Bluetooth の権限ダイアログ）
uv run tools/ble_client.py info                 # Info を読む（暗号化不要）
uv run tools/ble_client.py watch --seconds 3    # Status 通知（初回はペアリングのダイアログ）
uv run tools/ble_client.py move 20 -5 --speed 50
uv run tools/ble_client.py gesture nod 15 --repeats 2
uv run tools/ble_client.py demo                 # 6 種 × small/medium/large
uv run tools/ble_client.py latency --count 10   # MOVE 書き込み → MOVING=1 の遅延
uv run tools/ble_client.py cal save             # 設計書 §4.6 の手順で保存して照合
```

各サブコマンドは接続を保ったまま 1 Hz で PING を送り、完了（MOVING=0 を 0.5 秒、GESTURE=0 など）まで待って切断する。
切断すると首は安全復帰（中立へ戻って 2 秒後に PWM 停止）する。`--hold N` で完了後に N 秒保てる。`--no-ping` は PING を
送らずに保持し、3 秒無通信の安全復帰を STATUS で見せる。`gesture` は所要時間、`reconnect` は 2 回目の接続時間を表示する。

BLE の初回: ターミナルに macOS の Bluetooth 権限を許可する（許可しないと `scan` が戻らない）。ペアリングは Just Works で
ダイアログなし。ツールは接続直後に暗号化が必要な Status を読んでペアリングを起こす。`Insufficient Encryption (15)` が続く
ときは途中で止まったペアリングの残骸なので、シリアルで `BONDS CLEAR` を送ってから接続し直す（Mac 側にボンドが残って
いる場合の再ペアリングは未検証）。

シリアルの行は `HELP` で一覧が出る。`MOVE 20 -5`、`GESTURE nod 15`、`STOP`、`CENTER`、`TORQUE 0|1`、`PING [seq]`、
`CAL <yaw_off> <pitch_off> <invert>`、`SAVE [req]`、`LIMITS <yaw_v> <pitch_v> <yaw_a> <pitch_a>`、`GAIN <yaw> <pitch>`、
`HEX <bytes>`、`STATUS`、`WATCH ON|OFF`、`INFO`、`BONDS CLEAR`、`PAIR OPEN`。角度は度（小数可）、応答は `OK …` か `ERR <理由>`。

## ゲイン校正（設計書 §4.3、定型動作の試験より前に行う）

DS3218 は 180° 仕様（500〜2500 µs）なので既定ゲインは 11.11 µs/°。購入記録の読み違い（270° 仕様 = 7.41）に備え、
小さい角度から確かめる。

1. `TORQUE 1` のあと `CENTER` で中立にし、頭部に載せた iPhone の「計測」アプリの水準器の読み θ0 を記録する
2. `MOVE 0 5 30` で +5° を指令し、読み θ5 を記録する。Δ = θ5 − θ0 が負なら `CAL 0 0 2`（ピッチ反転）を送って 1 からやり直す
   （iPhone の水準器は +5° だと 0〜1° にしか読めないので、向きの判定だけに使い、差分は +15°/+30° で取る。精度が要るときは
   側面から写真を撮って角度を測る。本機は 2026-10-23 にピッチ反転 `inv=0,1` を保存済み、+15°/+30° が目視一致でゲインは既定のまま）
3. `MOVE 0 15 30`、`MOVE 0 30 30` で同様に差分を取り、ゲイン = 現在のゲイン × 指令角 / Δ を計算する
4. `CENTER` で中立に戻してから `GAIN <yaw> <pitch>` を送る（静止・中立でないと `ERR RANGE`）。`SAVE` で反転とオフセットも保存する
5. `MOVE 0 30 30` を再指令し、差分が 30° ± 1° であることを確認する
6. ヨーも同じ型でも独立に確かめる（机の分度器か iPhone のコンパスの方位差で 0° と +30° の差分を読む）

## 構成

```
platformio.ini      # env: xiao（実機）, xiao_bringup（サーボ出力なし）, native（ホスト単体テスト）
src/main.cpp        # 入口。20 ms の tick で Supervisor を回し、サーボ・BLE・シリアルへ
src/Console.*       # シリアルの行を解釈して Supervisor へ
src/platform/       # ServoDriver（ESP32Servo）、NvsStorage（Preferences）、SerialTransport、BleTransport（NimBLE）
lib/catneck/        # コア（Arduino 非依存）: Protocol / Axis / Planner / Gesture / Supervisor / SerialParser
test/               # Unity テスト（pio test -e native）
tools/              # Mac 用: ble_client.py、serial_cli.py、catneck_proto.py（共有の符号化・復号）
```
