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

## Task 8 実機アダプタとシリアル経路（2026-10-23、利用者不在、`xiao_bringup` ビルド = サーボ出力なし）

| 確認 | 結果 |
|---|---|
| `pio run -e xiao` / `pio run -e xiao_bringup` | 両方 SUCCESS（xiao: RAM 4.2%、Flash 26.4%。bringup: Flash 25.4%）。警告は ESP32Servo ライブラリ内の未使用変数のみ |
| `pio run -e xiao_bringup -t upload --upload-port /dev/cu.usbmodem101` | SUCCESS（184.93 kB、Hash verified）。旧 AC5 試験ファームを上書き |
| 起動行（USB リセットで取得） | `CATNECK fw=0.1.0 proto=1 hw=E17 reset=USB brownout=0 pwm=off`（ROM の `rst:0x15 (USB_UART_CHIP_RESET)` の後） |
| `INFO` | `INFO fw=0.1.0 proto=1 hw=E17 ble=none reset=USB brownout=0 pwm=off cal=0.0,0.0 inv=0,0 gain=11.11,11.11 saved=0 tick_max_us=17087 tick_avg_us=107` |
| `STATUS` | `STATUS yaw=0.0 pitch=0.0 flags=0x0020 seq=0 state=2 err=0 save=0`（CAL_DIRTY = 保存値なし、state 2 = IDLE） |
| `HELP` | 7 行の一覧 |
| `PING 5` → `STATUS` | `OK` → `seq=5` |
| `HEX 09 07` → `STATUS` | `OK` → `seq=7`（BLE と同じ復号器を通る経路の確認） |
| `LIMITS 0 0 0 0` | `OK`（変更なし） |
| `SAVE`（req 省略） | `OK seq=1` → `STATUS` の `save=1`、flags 0x0000（CAL_DIRTY が下りた）、`INFO` の `saved=1`。NVS への実書き込みと読み戻しが成立 |
| `FOO` | `ERR UNKNOWN` |
| `WATCH ON` / `WATCH OFF` | 200 ms ごとに STATUS 行（3 秒で 16 行）/ `OK` で停止 |
| 動作要求（MOVE/GESTURE/CENTER/TORQUE/CAL） | **送っていない**（無人の約束。bring-up は出力なしだが HEX 経由でも送らない） |
| tick 所要時間 | 静止時 平均 48〜107 µs、最大 17,087 µs（起動直後の 1 回。原因は Planner の巡航速度探索と判明し最終レビュー後の修正で 312 µs。下記） |
| `pio device monitor` の無リセット | **未実施** |

### 判断

- `GAIN`（シリアル）は当初 `setGain` を直接呼びウォッチドッグを更新しなかったが、codex の事後審査 [R6] を受けて 78ef551 で `setGain(…, nowMillis)` が保守要求（通信扱い）になった（`test_gain_and_save_follow_maintenance_rules` で固定）
- 起動 500 ms 中のシリアルコマンドは `ERR BOOT` を返す（停止要求は記憶する）

## Task 9 BLE GATT サーバ（2026-10-23、利用者不在、`xiao_bringup` ビルド）

| 確認 | 結果 |
|---|---|
| `pio run -e xiao` / `xiao_bringup`（NimBLE 込み） | SUCCESS。xiao: RAM 7.4%、Flash 59.7% |
| 書き込みと起動行 | SUCCESS。`CATNECK fw=0.1.0 proto=1 hw=E17 reset=USB brownout=0 pwm=off`。NimBLE の起動でクラッシュ・再起動なし |
| `INFO` | `addr=e0:72:a1:1d:5e:8e name=CatRobot-5E8E bonds=0 pair_open=1 dropped=0`。Bluetooth アドレスは設計書 §3.2 の見込み（ベース MAC +2）と一致、名前も一致（R3 解消） |
| `STATUS` | flags 0x0200 = PAIR_OPEN（ボンド 0 なので常時受付） |
| `PAIR OPEN` | `OK` |
| NVS の保存値 | Task 8 で保存した既定値が再書き込み後も `saved=1`（アプリ領域の書き換えで NVS は消えない） |
| Mac からアドバタイズが見えること | 実施（Task 12 の表）。Bluetooth 権限を許可すると `scan` で見える |
| ペアリング・暗号化特性の Read/Notify・窓外の切断（R2） | ペアリングと Read/Notify は実施（Task 12 の表）。窓外の切断は未実施 |

## 最終レビュー後の修正（2026-10-23、利用者不在、`xiao_bringup` ビルド = サーボ出力なし）

全ブランチの最終レビュー（Critical 1・Important 3）への修正と、その確認。動作要求は引き続き送っていない。

| 修正 | 確認 |
|---|---|
| C1 時刻の折り返し: `loop()` は入力を `millis()` で、tick を名目時刻（≤ `millis()`）で処理していたため、同じ周回で届いた指令・切断の時刻が tick より進み、uint32 の引き算が折り返して ACTIVE→RETURNING と RETURNING の 2 秒期限が即座に発火しえた | ホストテスト 2 件を先に書いて失敗を確認（`test_command_timestamp_ahead_of_tick_keeps_active`: Expected 3 Was 4、`test_link_down_timestamp_ahead_of_tick_keeps_returning`: Expected 4 Was 5）→ `Supervisor::tick` の経過判定 5 箇所を「負の差は未経過」に統一して合格。`main.cpp` は入力と tick に同じ `millis()` を渡す |
| I1 Planner の巡航速度探索のコスト（48 回の二分探索、double、FPU なし） | 旧コードのまま反復を 24 回にした隔離ビルドで起動直後の `tick_max_us` 17,087 → 11,100 µs（約 250 µs/反復・2 軸。起動直後の値は IDLE 入りの `reset` ×2 が距離 0 で探索していたもの）。最終版: 静止からの移動は閉形式 v = ∛(J·D²/4)、距離 0・静止は探索なし、一般の初期状態は 24 回 → 起動直後 **312 µs**。旧実装との軌道比較 150 シナリオ（静止 120・移動中 30）で tick 数が同一、位置差 0（float 精度）、速度差 ≤ 1.2e-14。動作中の値は Task 12 で読む |
| tick の溜まり | 停滞（NVS 書き込みなど）で溜まった tick はまとめて実行せず捨てて位相だけ合わせる（まとめて実行すると複数 tick 分の移動が 1 つの PWM 周期に押し込まれて段差になる）。`INFO` に `tick_dropped` を追加（最終ビルドで 0） |
| I2 loop タスクが task watchdog に未登録（NimBLE/NVS の待ちでハングすると最後の PWM が出続ける） | `enableLoopWDT()`（sdkconfig: 5 秒・panic → リセット）。隔離コピーに「起動 15 秒後に `for(;;) delay(1000)`」を仕込んで実機で確認: `PROBE hang` → 5.0 秒後 `task_wdt: … loopTask` → 再起動 → `CATNECK fw=0.1.0 proto=1 hw=E17 reset=TASK_WDT brownout=0 pwm=off`。通常の bring-up ビルドは 120 秒の連続捕捉で再起動なし |
| `INFO`（最終ビルド） | `… saved=1 tick_max_us=312 tick_avg_us=114 tick_dropped=0`。`STATUS`・`PING`・`HEX 09 09` は従来どおり |
| ホストテスト | 74 件合格（Supervisor 29、Planner 15 ほか） |

I3（`test_return_deadline_2s` が期限分岐を通らない）は Minor に再格付けして保留: RETURNING は常に 90/60°/s に引き上げるので ±60°/±30° からでも 1 秒以内に中立へ着き、2 秒期限は C1 修正後は到達不能な安全網。

## Task 12 受入（2026-10-23 朝、利用者在席）

### BLE 経路（`xiao_bringup` ビルド、首は動かさない）

| 確認 | 結果 |
|---|---|
| Mac のターミナルに Bluetooth 権限を許可 → `ble_client.py scan` | `CatRobot-5E8E address=41BD40E1-…（CoreBluetooth の UUID） rssi=-84 services=['c47b0000-…']` |
| `ble_client.py info`（暗号化不要） | `proto=1 fw=0.1.0 hw=1 caps=0x00` |
| `ble_client.py watch`（未ペアのまま購読） | STATUS が 200 ms ごとに届いた（flags LINK,PAIR_OPEN）。**発見**: Read は READ_ENC で拒否されるが Notify は NimBLE が暗号化の有無を見ずに送るため、未ペアの central に 12 B の状態が届く（最終レビューが「実機で確認」とした項目）。→ `publishStatus` を暗号化済みの接続にだけ送るよう修正 |
| `ble_client.py cal get`（READ_ENC、ペアリングを起こすはず） | 最初の試行（利用者）で失敗し、その後は毎回 ATT `0x0F Insufficient Encryption`。macOS は 0x0F ではペアリングを始めない。原因: NimBLE の ATT 権限検査は PEER_SEC（相手の LTK）の有無で 0x0F/0x05 を分け、`getNumBonds()`/`deleteAllBonds()` は OUR_SEC を数える。最初のペアリングが途中で止まり PEER_SEC だけが残っていた（`bonds=0` なのに 0x0F）。→ `BONDS CLEAR` を `ble_store_clear()`（our/peer sec・CCCD・IRK を全部消す）に変更。ツール側も、接続直後に Status を読んで（READ_ENC）ペアリングを確実に起こすようにした（Command は応答なし書き込みなので未ペアだと黙って捨てられ、macOS はペアリングを始めない） |
| 修正後: `BONDS CLEAR` → `cal get` | `Calibration: {'yaw_off': 0.0, 'pitch_off': 0.0, 'invert': 0, 'saved': 1}`、`INFO` の `bonds=1`。macOS のダイアログなし（Just Works） |
| ペア済みで `watch` | STATUS 受信（暗号化済み）。USB リセット後も `bonds=1`（NVS に保持） |
| 最初のペアリングが止まった原因 | 未特定（SM のログは取れていない）。再発時は `BONDS CLEAR` で復旧できる |

### 動作試験（通常 `xiao` ビルド、利用者が首を見ている状態）

| 項目 | 結果 |
|---|---|
| T-FW-1 起動 | 書き込み直後、起動 500 ms 後に中立へ 1 回動き、1.5 秒で IDLE。利用者「特に問題なさそう」。起動行 `reset=USB brownout=0 pwm=on`、起動直後の tick_max_us 1,169 |
| T-FW-0 脱力 | **保持し続ける機種だった**。IDLE（PWM 停止、ピンは入力＋プルダウン、STATUS は TORQUE なし）でも頭はロックされたまま。サーボの 19 V を抜き差しすると解けた（USB 給電の XIAO は動作継続、reset 理由は USB のまま）。DS3218 は一度指令を受けると信号停止後も最後の位置を保持する（設計書 §7 R9 の分岐）。利用者が「保持を受け入れる」を選択: 以後「脱力」= PWM 停止、待機中の首は中立で保持 |
| T-FW-5 ゲインと反転 | ピッチ +5° で下を向いた → `cal set 0 0 2`（ピッチ反転）→ 上を向く。+15° は目視でほぼ 15°。+30° は iPhone の水準器で 39°（+5° では 0〜1° で、置き方の影響が大きく信頼性が低い）。+30° も目視ではほぼ 30°（利用者判定）。ゲインは既定 11.11 µs/° のまま合格（水準器の数値は採用しない。精密測定が要るときは側面写真）。ヨー +30° はロボット自身の左（約束どおり）で大きさも目視で一致。`cal save` → `saved=1`、`INFO` の `inv=0,1`。±60°/±30° でリミットに当たらないことは demo（最大 ヨー 25°・ピッチ 20°）の範囲でのみ確認 |
| T-FW-2 定型動作 | `demo` 18 動作（6 種 × 3 段階）すべて完了、拒否 0、BROWNOUT なし。利用者「とりあえずいい感じ」。nod large の所要 1.32 秒（BLE 書き込み → GESTURE フラグ降下の通知、往復約 40 ms 込み。ホストでは 1.28 秒）。動作中の tick_max_us 2,718、tick_dropped 0 |
| T-FW-3 安全復帰 | シリアル WATCH の時系列で確認。PING なしで MOVE → 3 秒で RETURNING → 1 秒で中立 → 2 秒後に IDLE。切断では即 RETURNING → 中立 → 2 秒後 IDLE（切断から約 2.5 秒）。「復帰中の PING で解除されない」はホストテストで固定、実機では未実施 |
| T-FW-4 校正の保持 | `cal save`（invert 2）→ USB リセット → `cal get` が `invert 2, saved 1` |
| T-FW-6 遅延 | MOVE 書き込み → MOVING=1: 中央値 60 ms、最小 59、最大 62（10/10 件） |
| T-FW-7 再接続 | 切断後 1 秒で再接続、接続開始から暗号化 Read 完了まで 0.95 秒（1 回目 0.83 秒） |
| T-FW-8 シリアル同等性 | `serial_cli.py --encode gesture nod 15` → `HEX 02 01 96 01 00` → `OK`（BLE と同じ復号器・同じ Supervisor 経路） |
| ツールの修正 | `gesture` の位置引数 `name` が `--name`（機器名）を上書きして接続できなかった → dest を分離。`gesture` に所要時間、`reconnect` に接続時間、`--no-ping`（3 秒無通信の確認用）を追加 |

### 定型動作の方式比較と採用（利用者在席）

| 項目 | 結果 |
|---|---|
| 比較方法 | 比較用の一時ビルド（シリアル `GMODE WAVE|PATH` で切替、コミットしない）で nod 15°・shake 25°・look_up 20° を WAVE（GesturePlayer の波形を直接出力）→ PATH（極値経由の S 字、当時の実装）の順に再生 |
| 所要（BLE 往復込み） | WAVE: nod 1.56 / shake 2.13 / look_up 4.11 秒。PATH: nod 1.35 / shake 1.53 / look_up 2.91 秒 |
| 利用者判定 | 「前半（WAVE）の方が良かった」→ 波形出力を採用。nod large の受入「1.0〜1.3 秒」は「波形どおり（既定上限で約 1.5 秒）」に改定 |
| 実装（TDD） | Supervisor: 波形を tick ごとにサーボ角へ、Planner は標本に静止で追従、RETURNING 入りで直前 3 標本から速度・加速度を推定して `Planner::reset(pos, vel, acc)` に引き渡し（速度連続）、ピッチ 3 tick 遅延（FW-PWR-1）、再生中の SET_LIMITS/SET_CAL は Planner 目標を触らない。極値経由の実装は撤去。テスト: Supervisor 5 件（時間・振幅・上限、MOVING、ピッチ遅延、speed、受け渡しの連続性、SET_LIMITS）、Planner 1 件 |
| 採用後の実機 | `xiao` 再書き込み → gesture nod 15 = 1.59 秒、shake 25 = 2.16、look_up 20 = 4.11、tilt_l 15 = 2.55（BLE 往復込み）。`demo` 18 動作完了 |
| 発見: tick 25 ms | 採用後の `INFO` で `tick_max_us=25153`、`tick_avg_us=525`。GesturePlayer::start が窓つき正弦の導関数ピークを毎回 401 点走査していた（FPU なしで 1 軸 12 ms、2 軸で 24 ms）。定数化（200,001 点の走査値、test_gesture で照合） |
| 定数化後の実機 | `xiao` 再書き込み → `demo` 18 動作完了、`INFO` tick_max_us=2365、tick_avg_us=494（demo 中込み）、tick_dropped=0 |

## 受入基準（設計書 §5）の状態

| ID | 内容 | 状態 |
|---|---|---|
| T-FW-0 | 脱力の確認 | **条件変更**: 保持し続ける機種（上記）。PWM 停止は確認、保持は利用者が受け入れ |
| T-FW-1 | 起動（跳ねなし、起動行、1.5 秒で IDLE） | **合格**（利用者目視、起動行、IDLE） |
| T-FW-2 | 定型動作 `demo`（6 種 × 3 段階、nod large は波形どおり、BROWNOUT なし） | **合格**（波形出力で 18 動作完了、nod large 1.59 秒 BLE 往復込み = 波形 1.52 秒 + 往復、BROWNOUT なし） |
| T-FW-3 | 安全復帰（3 秒無通信、切断、PING で解除されない、5 秒以内に脱力） | **合格**（無通信 3 秒 → 復帰 → 2 秒で IDLE、切断 → 約 2.5 秒で IDLE。PING 非解除はホストテストのみ） |
| T-FW-4 | キャリブレーション（cal set → save → 再起動 → cal get） | **合格**（invert 2 が再起動後も保持） |
| T-FW-5 | 制限とゲイン（+5/+15/+30° の差分角、`GAIN`、±60°/±30° でリミットに当たらない） | **合格**（反転確定、+15°/+30° とも目視一致で既定ゲインのまま。端 ±60°/±30° は demo の範囲まで） |
| T-FW-6 | 遅延（MOVE → MOVING=1 の中央値 ≤ 300 ms） | **合格**（中央値 60 ms） |
| T-FW-7 | 再接続 ≤ 5 秒 | **合格**（0.95 秒） |
| T-FW-8 | シリアル同等性（HEX = BLE） | **合格**（PING と GESTURE を HEX で送って同じ経路で受理） |
| T-FW-9 | ペアリング・BONDS CLEAR・窓の挙動 | 一部実施: ペアリング（Just Works）・暗号化 Read/Notify・再起動後のボンド保持・`BONDS CLEAR` を確認。60 秒窓の外での未ペア拒否は未実施 |
| T-FW-10 | ホストテスト `pio test -e native` 全件合格 | **合格**: 74 件（2026-10-23、Protocol 10・Axis 5・Planner 15・Gesture 7・Supervisor 29・SerialParser 7・Smoke 1） |

## 未実施一覧（利用者在席時に行う）

- T-FW-9 の「60 秒窓の外で未ペアの central を拒否」（2 台目の central が要る）
- ±60°/±30° の端でリミットに当たらないことの確認（demo は最大 ヨー 25°・ピッチ 20° まで）
- T-FW-3 の「復帰中の PING で解除されない」の実機確認（ホストテストでは固定済み）
- `pio device monitor` の無リセット確認（Task 8）
- 動作中の tick 所要時間: `latency` と `demo` の直後に `INFO` の `tick_max_us` と `tick_dropped` を読む（目安: 最大 5 ms 以下、dropped 0）
