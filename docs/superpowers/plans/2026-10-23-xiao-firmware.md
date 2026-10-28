# XIAO ESP32C3 ファームウェアと BLE プロトコル版 1 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> 本計画は利用者の指示により、claude と codex のペア（driver / navigator 交代、agmsg チーム `coding`）で実行する。奇数タスクは claude が driver、偶数タスクは codex が driver（codex が設計審査中に claude が Task 1 を始められるように）。navigator は brief を送り、driver の staged 差分を隔離コピーで独立検証（ホストテスト全件・契約）してから approve する。Task 12 は利用者在席時に人間主導で行う。

**Goal:** XIAO ESP32C3 に首（ヨー・ピッチ）の BLE／シリアル制御ファームウェアを入れ、Mac の試験ツールから定型動作・安全復帰・キャリブレーション保存が実機で確認できる状態にする。

**Architecture:** Arduino 非依存の C++17 コア `lib/catneck`（Protocol / Axis / Planner / Gesture / Supervisor / SerialParser）を Unity でホスト上に単体テストし、`src/platform` の薄いアダプタ（NimBLE、USB CDC、ESP32Servo、Preferences）でハードに接続する。50 Hz の単一ループが tick を回し、BLE コールバックはキューに積むだけ。Mac 側は bleak／pyserial の Python ツールで検証する。

**Tech Stack:** PlatformIO Core 6.2.0（Homebrew）、platform `espressif32@8.0.0`（Arduino-ESP32 3.3.12）、board `seeed_xiao_esp32c3`、NimBLE-Arduino 2.5.1、ESP32Servo 3.2.1、Preferences、Unity（`pio test -e native`）、Python ≥ 3.10 + bleak 3.0.2 + pyserial 3.5（`uv run`、PEP 723）

**Spec:** `docs/superpowers/specs/2026-10-23-xiao-firmware-ble-design.md`（以下「設計書」。節番号は設計書のもの）

## Global Constraints

- 置き場所は Cat_robot リポジトリ直下の `firmware/`。Xcode プロジェクト・`CatRobot/`・`scripts/generate_project.rb` には触れない（設計書 §3.4、§4.1）
- `lib/catneck` は Arduino／ESP-IDF のヘッダを一切 include しない。`pio test -e native` が実機・ネットワークなしで通る（§4.1、§4.10）
- ピン: ヨー = GPIO3（D1）、ピッチ = GPIO5（D3）（§3.1）
- 絶対上限: 角度 ヨー ±60.0°、ピッチ ±30.0°。速度 ヨー 180°/s、ピッチ 120°/s。中立オフセット ±20.0°。パルス 500〜2500 µs、中立 1500 µs。出荷既定速度 ヨー 120°/s、ピッチ 100°/s。SET_LIMITS の下限 5.0°/s・5.0°、0 は「変更しない」。既定ゲイン 11.11 µs/°、受理範囲 5.00〜15.00（§4.3）
- 加速: 静止→V を 0.2〜0.3 秒、a_max = 2V/0.2 s、j_max = 4V/(0.2 s)²、tick 20 ms、2 軸ずらし 3 tick（§4.3）
- 時間定数: BOOT 500 ms、電源投入から 1.5 秒で IDLE、無通信 3.0 秒、安全復帰速度 ヨー 90°/s・ピッチ 60°/s、復帰期限 2.0 秒、RELAX_WAIT 2.0 秒、Status 通知 200 ms（§4.5、§4.6）
- プロトコル版 1、ファームウェア版 0.1.0、ハード ID 1、サービス UUID `C47B0000-6D1F-4B9E-9C9A-2A3B4C5D6E7F`、Status 12 B / Calibration 6 B / Limits 8 B / Info 8 B、コマンド長 MOVE 6 / GESTURE 5 / STOP 1 / CENTER 2 / TORQUE 2 / SET_CAL 6 / SAVE_CAL 2 / SET_LIMITS 9 / PING 2、リトルエンディアン（§4.6）
- 文書・README・検証記録・コミット本文は日本語、識別子は英語。コミット件名は既存どおり `feat:` / `test:` / `docs:` 形式。鍵・`CatRobot/LocalAssets` には触れない。実測していないことを「確認済み」と書かない（§3.4）
- 首を動かす可能性のある実機作業はすべて利用者在席時のみ（通常ファームの書き込み・起動を含む。起動 500 ms 後の BOOT_CENTER で首が動きうる）。利用者不在で行えるのは、サーボ出力を無効にした `xiao_bringup` ビルド（`-DCATNECK_NO_PWM`）による書き込み・シリアル・BLE の通信確認だけ。動作要求（MOVE/GESTURE/CENTER/TORQUE 1/SET_CAL）は無人では送らない（HEX 経路も同じ）

## Review Focus

1. MOVE を 50 Hz で目標を振って送り続けても位置が絶対上限を超えない（制動点の契約。§4.3）→ Task 4 のテスト `test_random_retargets_stay_within_limits`
2. Command 特性に 0 バイト／21 バイト以上／種別だけ正しく長さ違いのデータが来ても落ちず、REJECTED と累計だけが増える（§4.6）→ Task 2 の `test_decode_rejects_bad_lengths`、Task 6 の `test_rejected_input_does_not_feed_watchdog`
3. GESTURE 再生中に BLE が切れたら待たずに復帰し、再接続後の PING だけでは動かない（§4.5）→ Task 6 の `test_disconnect_during_gesture_returns_immediately`、`test_ping_after_reconnect_does_not_resume`
4. NVS の blob が壊れている・版が違う・読めないときに既定値で起動し CAL_DIRTY が立つ。保存失敗で SAVE_ERROR が立ち、`save_seq` が req になる（§4.8）→ Task 6 の `test_corrupt_blob_falls_back_to_defaults`、`test_save_failure_sets_save_error_and_sets_save_seq`
5. 速度上限を動作中に 100 → 5°/s へ下げても（加速度が最大の瞬間でも）、移行中は旧上限を超えず、T_tr の後は新上限内（§4.3）→ Task 4 の `test_lowering_max_vel_decelerates_within_transition`

---

## ファイル構成

```
firmware/
  platformio.ini                       # env: xiao / native
  README.md                            # 日本語手順（Task 11）
  library.json は不要（lib/catneck 側に置く）
  src/main.cpp                         # 入口: 組み立て、50 Hz ループ、Status 通知（Task 8, 9）
  src/Console.h / Console.cpp          # シリアル行 → 動作（Task 8）
  src/platform/ServoDriver.h / .cpp    # ESP32Servo アダプタ（Task 8）
  src/platform/NvsStorage.h / .cpp     # Preferences アダプタ（Task 8）
  src/platform/SerialTransport.h / .cpp# USB CDC 行読み（Task 8）
  src/platform/BleTransport.h / .cpp   # NimBLE サーバ（Task 9）
  lib/catneck/library.json             # {"name":"catneck","version":"0.1.0","frameworks":"*","platforms":"*"}
  lib/catneck/src/catneck/Config.h     # 全数値定数（Task 1）
  lib/catneck/src/catneck/Protocol.h / .cpp   # Task 2
  lib/catneck/src/catneck/Axis.h / .cpp       # Task 3
  lib/catneck/src/catneck/Planner.h / .cpp    # Task 4
  lib/catneck/src/catneck/Gesture.h / .cpp    # Task 5
  lib/catneck/src/catneck/Supervisor.h / .cpp # Task 6
  lib/catneck/src/catneck/SerialParser.h / .cpp # Task 7
  test/test_smoke/test_smoke.cpp       # Task 1
  test/test_protocol/test_protocol.cpp # Task 2
  test/test_axis/test_axis.cpp         # Task 3
  test/test_planner/test_planner.cpp   # Task 4
  test/test_gesture/test_gesture.cpp   # Task 5
  test/test_supervisor/test_supervisor.cpp # Task 6
  test/test_serial_parser/test_serial_parser.cpp # Task 7
  tools/ble_client.py                  # Task 10
  tools/serial_cli.py                  # Task 10
docs/validation/2026-10-23-xiao-firmware.md    # Task 11, 12
docs/superpowers/specs/2026-10-11-cat-robot-claude-neck-requirements.md  # Task 11（§8 の修正）
```

テストは PlatformIO の流儀で `test/<suite>/` ごとに 1 本の `main`。各ファイルは次の骨組みで、`setUp`/`tearDown` は空関数。

```cpp
#include <unity.h>
void setUp() {}
void tearDown() {}
// void test_xxx() { ... }
int main(int, char**) { UNITY_BEGIN(); /* RUN_TEST(test_xxx); */ return UNITY_END(); }
```

実行コマンド（作業ツリー `/Users/goodapple/workspace/Cat_robot/.worktrees/feature-xiao-firmware/firmware` で）:

- ホストテスト全件: `pio test -e native`
- 1 suite: `pio test -e native -f test_planner`
- 実機ビルド: `pio run -e xiao`
- 書き込み: `pio run -e xiao -t upload --upload-port /dev/cu.usbmodem101`
- モニタ: `pio device monitor -p /dev/cu.usbmodem101 -b 115200`

---

### Task 1: プロジェクト骨組みとビルド経路の確認（driver: claude）

**Files:**
- Create: `firmware/platformio.ini`, `firmware/lib/catneck/library.json`, `firmware/lib/catneck/src/catneck/Config.h`, `firmware/src/main.cpp`, `firmware/test/test_smoke/test_smoke.cpp`, `firmware/.gitignore`（`.pio/`）

**Interfaces:**
- Produces: `catneck/Config.h` の `namespace catneck::config` に Global Constraints の数値を `constexpr float` / `constexpr uint32_t` で定義。名前: `kTickMs=20`, `kYawMaxAngle=60.0f`, `kPitchMaxAngle=30.0f`, `kYawAbsVel=180.0f`, `kPitchAbsVel=120.0f`, `kYawDefaultVel=120.0f`, `kPitchDefaultVel=100.0f`, `kMinVel=5.0f`, `kMinAngleLimit=5.0f`, `kMaxOffset=20.0f`, `kDefaultGain=11.11f`, `kMinGain=5.0f`, `kMaxGain=15.0f`, `kMinPulseUs=500.0f`, `kMaxPulseUs=2500.0f`, `kNeutralPulseUs=1500.0f`, `kAccelTime=0.2f`, `kStaggerTicks=3`, `kBootMuteMs=500`, `kBootIdleMs=1500`, `kSilenceMs=3000`, `kReturnYawVel=90.0f`, `kReturnPitchVel=60.0f`, `kReturnDeadlineMs=2000`, `kRelaxMs=2000`, `kStatusPeriodMs=200`, `kProtocolVersion=1`, `kFwMajor=0`, `kFwMinor=1`, `kFwPatch=0`, `kHwId=1`

- [ ] **Step 1: `platformio.ini` を書く**

```ini
[platformio]
default_envs = xiao

[env:xiao]
platform = espressif32@8.0.0
board = seeed_xiao_esp32c3
framework = arduino
monitor_speed = 115200
upload_speed = 460800
lib_deps =
  h2zero/NimBLE-Arduino@2.5.1
  madhephaestus/ESP32Servo@3.2.1
build_flags = -Wall -Wextra
test_ignore = *

[env:native]
platform = native
test_framework = unity
build_flags = -std=c++17 -Wall -Wextra -Werror -DCATNECK_NATIVE
```

- [ ] **Step 2: `test_smoke.cpp` に `test_config_values` を書く**（`kYawMaxAngle == 60.0f`、`kDefaultGain == 11.11f`、`kBootIdleMs == 1500` を `TEST_ASSERT_EQUAL_FLOAT` / `TEST_ASSERT_EQUAL_UINT32` で）

- [ ] **Step 3: `pio test -e native` を実行して失敗を確認**（`Config.h` が無いコンパイルエラー）

- [ ] **Step 4: `Config.h` と `library.json`、空の `src/main.cpp`（`setup(){}`／`loop(){}`）を作る**

- [ ] **Step 5: `pio test -e native` が PASS（1 test）**

- [ ] **Step 6: `pio run -e xiao` が SUCCESS**（初回は platform・toolchain・framework を取得する。失敗したら設計書 §7 R8 の分岐: pioarduino `55.03.312-1` に切り替え、理由を README 用に記録）

- [ ] **Step 7: コミット** `feat(firmware): scaffold PlatformIO project for XIAO ESP32C3`

### Task 2: プロトコルの符号化・復号（driver: codex）

**Files:**
- Create: `firmware/lib/catneck/src/catneck/Protocol.h`, `Protocol.cpp`, `firmware/test/test_protocol/test_protocol.cpp`

**Interfaces:**
- Produces（`namespace catneck`）:
  - `enum class CommandType : uint8_t { Move=0x01, Gesture=0x02, Stop=0x03, Center=0x04, Torque=0x05, SetCal=0x06, SaveCal=0x07, SetLimits=0x08, Ping=0x09 }`
  - `enum class GestureId : uint8_t { Nod=1, Shake=2, TiltL=3, TiltR=4, LookUp=5, LookDown=6 }`
  - `struct MoveCmd { int16_t yawDeci; int16_t pitchDeci; uint8_t speed; }`, `struct GestureCmd { GestureId id; uint8_t ampDeci; uint8_t repeats; uint8_t speed; }`, `struct CenterCmd { uint8_t speed; }`, `struct TorqueCmd { bool on; }`, `struct SetCalCmd { int16_t yawOffDeci; int16_t pitchOffDeci; uint8_t invert; }`, `struct SetLimitsCmd { uint16_t yawVelDeci; uint16_t pitchVelDeci; int16_t yawAngDeci; int16_t pitchAngDeci; }`, `struct PingCmd { uint8_t seq; }`, `struct SaveCalCmd { uint8_t req; }`
  - `struct Command { CommandType type; union { MoveCmd move; GestureCmd gesture; CenterCmd center; TorqueCmd torque; SetCalCmd setCal; SaveCalCmd saveCal; SetLimitsCmd setLimits; PingCmd ping; }; }`
  - `enum class DecodeError : uint8_t { None, Empty, UnknownType, BadLength, BadGestureId, BadTorqueValue, NegativeAngleLimit, BadSaveReq }`
  - `struct DecodeResult { bool ok; DecodeError error; Command command; }`
  - `DecodeResult decodeCommand(const uint8_t* data, size_t len)`
  - `namespace StatusFlags { constexpr uint16_t Link=1u<<0, Torque=1u<<1, Moving=1u<<2, Brownout=1u<<3, Saturated=1u<<4, CalDirty=1u<<5, Gesture=1u<<6, Rejected=1u<<7, Returning=1u<<8, PairOpen=1u<<9, SaveError=1u<<10; }`
  - `enum class SupervisorState : uint8_t { Boot=0, BootCenter=1, Idle=2, Active=3, Returning=4, RelaxWait=5 }`
  - `struct Status { int16_t yawDeci; int16_t pitchDeci; uint16_t flags; uint8_t pingSeq; SupervisorState state; uint16_t voltageCenti; uint8_t rejectedCount; uint8_t saveSeq; }`、`constexpr size_t kStatusSize = 12`、`void encodeStatus(const Status&, uint8_t* out12)`
  - `struct CalibrationData { int16_t yawOffDeci; int16_t pitchOffDeci; uint8_t invert; bool saved; }`、`kCalibrationSize = 6`、`void encodeCalibration(const CalibrationData&, uint8_t* out6)`、`bool decodeCalibrationWrite(const uint8_t*, size_t, SetCalCmd&)`（6 B 以外は false、`saved` 欄は無視）
  - `struct LimitsData { uint16_t yawVelDeci; uint16_t pitchVelDeci; int16_t yawAngDeci; int16_t pitchAngDeci; }`、`kLimitsSize = 8`、`void encodeLimits(const LimitsData&, uint8_t* out8)`、`bool decodeLimitsWrite(const uint8_t*, size_t, SetLimitsCmd&)`
  - `struct InfoData { uint8_t protocol, major, minor, patch, hwId, caps; }`、`kInfoSize = 8`、`void encodeInfo(const InfoData&, uint8_t* out8)`（末尾 2 B は 0）

- [ ] **Step 1: テストを書く**（名前と要点）
  - `test_decode_move`: `{0x01, 0xC8,0x00, 0xCE,0xFF, 0x64}` → ok、yawDeci 200、pitchDeci −50、speed 100
  - `test_decode_gesture_and_bad_id`: `{0x02,1,150,2,100}` → Nod/150/2/100。id 0 と 7 → `BadGestureId`
  - `test_decode_rejects_bad_lengths`: 0 B → `Empty`。各種別で長さ ±1 → `BadLength`。21 B の MOVE → `BadLength`
  - `test_decode_unknown_type`: `{0x0A}` → `UnknownType`
  - `test_decode_torque_and_set_limits`: TORQUE 2 → `BadTorqueValue`。SET_LIMITS の yawAngDeci −1 → `NegativeAngleLimit`。0 欄はそのまま 0 で ok
  - `test_decode_save_cal_req`: `{0x07, 9}` → req 9。`{0x07, 0}` → `BadSaveReq`。`{0x07}` → `BadLength`
  - `test_encode_status_layout`: Status{yaw −123, pitch 45, flags Link|Torque|SaveError, seq 7, state Active, voltage 0, rejected 3, saveSeq 250} → 12 B が `85 FF 2D 00 03 04 07 03 00 00 03 FA`（−123 = 0xFF85）
  - `test_encode_calibration_limits_info`: 各固定長と LE 配置。Info は `01 00 01 00 01 00 00 00`
  - `test_decode_calibration_and_limits_write`: 6 B / 8 B のみ受理

- [ ] **Step 2: `pio test -e native -f test_protocol` で失敗を確認**

- [ ] **Step 3: `Protocol.h` / `Protocol.cpp` を実装**（`std::memcpy` による LE 読み書き。拒否順序は 空 → 種別 → 長さ → 値）

- [ ] **Step 4: `pio test -e native -f test_protocol` が PASS**

- [ ] **Step 5: コミット** `feat(firmware): add protocol v1 codec`

### Task 3: 軸の制限・キャリブレーション・パルス変換（driver: claude）

**Files:**
- Create: `firmware/lib/catneck/src/catneck/Axis.h`, `Axis.cpp`, `firmware/test/test_axis/test_axis.cpp`

**Interfaces:**
- Consumes: `Config.h`
- Produces:
  - `struct AxisAbsolute { float maxAngle; float maxVel; }`、`constexpr AxisAbsolute kYawAbs{60.0f,180.0f}`、`kPitchAbs{30.0f,120.0f}`
  - `struct AxisLimits { float maxAngle; float maxVel; }`
  - `struct AxisCalibration { float offset; bool invert; float gain; }`
  - `class Axis { public: Axis(AxisAbsolute abs, float defaultVel); float clampJoint(float jointDeg, bool* saturated) const; float jointToServo(float jointDeg) const; float servoToJoint(float servoDeg) const; float servoToPulseUs(float servoDeg) const; bool setLimits(float maxAngleOrZero, float maxVelOrZero, bool* saturated); bool setCalibration(float offsetDeg, bool invert, bool* saturated); bool setGain(float gainUsPerDeg); const AxisLimits& limits() const; const AxisCalibration& calibration() const; const AxisAbsolute& absolute() const; }`
  - 意味: `jointToServo` = `(joint + offset) * (invert ? -1 : 1)`、`servoToPulseUs` = `1500 + servo * gain` を 500〜2500 で飽和。`setLimits` は 0 を「変更しない」、絶対上限と下限（5.0）で飽和し saturated を立てる、負の角度は false。`setCalibration` は ±20 で飽和。`setGain` は 5.00〜15.00 かつ有限でないと false

- [ ] **Step 1: テストを書く**
  - `test_clamp_joint_saturates_at_abs_and_configured`: 70 → 60（saturated）、limits を 45 に下げて 50 → 45
  - `test_joint_to_servo_applies_offset_then_invert`: offset 2.5、invert → joint 10 → servo −12.5。逆変換で往復一致
  - `test_pulse_mapping_and_saturation`: gain 11.11、servo 0 → 1500、servo 90 → 2499.9、servo 100 → 2500、servo −100 → 500
  - `test_set_limits_rules`: (0,0) 変更なし、(200,999) → 60/180 saturated、(3,2) → 5/5 saturated、(−1,x) → false
  - `test_set_calibration_and_gain_ranges`: offset 25 → 20 saturated、gain 4.99 / 15.01 / NaN → false、11.11 → true

- [ ] **Step 2: 失敗を確認** `pio test -e native -f test_axis`

- [ ] **Step 3: 実装**

- [ ] **Step 4: PASS を確認**

- [ ] **Step 5: コミット** `feat(firmware): add axis limits, calibration and pulse mapping`

### Task 4: S 字追従 Planner（driver: codex）

**Files:**
- Create: `firmware/lib/catneck/src/catneck/Planner.h`, `Planner.cpp`, `firmware/test/test_planner/test_planner.cpp`

**Interfaces:**
- Consumes: `Config.h`（`kAccelTime`, `kTickMs`）
- Produces:
  - `struct PlannerState { float pos; float vel; float acc; }`
  - `class Planner { public: explicit Planner(float dtSeconds = 0.02f); void reset(float pos); void setTarget(float pos); void setMaxVel(float v); float maxVel() const; float maxAcc() const; float maxJerk() const; void rescale(float factor); const PlannerState& step(); const PlannerState& state() const; float target() const; bool atTarget() const; float brakingPoint() const; }`
  - 意味: `maxAcc = 2*maxVel/kAccelTime`、`maxJerk = 4*maxVel/kAccelTime²`。`step()` は 1 tick 進める。`atTarget` は着地後にのみ true。着地 = |pos−target| ≤ 0.1 かつ |vel| ≤ 0.5°/s になった tick で pos = target、vel = 0、acc = 0 にそろえる（補正量はこの範囲内）。着地後は目標が変わるまで状態不変。`brakingPoint` は今から加速度・加加速度の上限内で減速して止まれる位置。`rescale(f)` は pos と target を f 倍（GAIN 変更時。静止時のみ呼ばれる）。`setMaxVel` の引き下げは旧 maxAcc/maxJerk を保ったまま減速し、|vel| ≤ 新上限 かつ acc = 0 で新値へ切り替える（設計書 §4.3 の移行規則。T_tr = (V_old − V_new)/a_old + 3·a_old/j_old）。引き上げは即時。Planner は速度 + acc²/(2·maxJerk) ≤ maxVel を常に保つ

- [ ] **Step 1: テストを書く**（各テストは 20 ms 刻みのシミュレーションで、毎 tick の差分から速度・加速度・加加速度を数値微分して検査する。許容誤差は速度 0.5°/s、加速度 5°/s²、加加速度 5%）
  - `test_rest_to_max_vel_takes_0_2_to_0_3_s`: maxVel 100、目標 +1000 → |vel| が 99 に達する時刻が 0.20〜0.30 s
  - `test_bounds_hold_every_tick`: 目標 +25（pitch 相当）で全 tick |vel| ≤ 100、|acc| ≤ 1000、|jerk| ≤ 10000×1.05
  - `test_no_overshoot_and_arrival`: 目標 30 から 0 へ。pos が 0 を下回らず、`atTarget` が 1.0 s 以内に true（maxVel 100）
  - `test_landing_is_exact_rest`: `atTarget` になった tick で pos == target、vel == 0、acc == 0。その後 50 tick で状態が不変
  - `test_60deg_within_1s_at_default_yaw_vel`: maxVel 120、0 → 60 が 1.0 s 以内に `atTarget`
  - `test_retarget_keeps_continuity`: 移動中に目標を反転させても連続 2 tick の vel 差 ≤ maxAcc·dt·1.05、acc 差 ≤ maxJerk·dt·1.05
  - `test_random_retargets_stay_within_limits`: 乱数（固定シード）で毎 tick 目標を [−30, 30] から選び 20 秒間。全 tick |pos| ≤ 30.0 + 0.05、かつ最後に目標を固定して 2 秒以内に `atTarget`
  - `test_braking_point_never_grows_on_retarget`: 移動中に手前へ差し替えたとき `brakingPoint()` が差し替え前以下（進行方向で）
  - `test_lowering_max_vel_decelerates_within_transition`: vel 100 で巡航中に `setMaxVel(5)`。移行中は |vel| ≤ 100、T_tr = (100−5)/1000 + 3·1000/10000 = 0.395 s 経過後は |vel| ≤ 5.5
  - `test_lowering_max_vel_at_peak_accel_keeps_old_bound`: 静止から目標 +1000 で加速中、acc が最大（≈1000）の tick で `setMaxVel(5)` → 以後の全 tick |vel| ≤ 100.5、T_tr 後 ≤ 5.5（旧 j_max で減速する契約）
  - `test_lowering_max_vel_at_peak_accel_negative_direction`: 上の鏡映。目標 −1000 で acc ≈ −1000 の tick に `setMaxVel(5)` → 全 tick vel ≥ −100.5、T_tr 後 |vel| ≤ 5.5
  - `test_velocity_invariant_both_signs_every_tick`: 乱数差し替え中の全 tick で v + max(a,0)²/(2j) ≤ V かつ v − max(−a,0)²/(2j) ≥ −V
  - `test_random_retargets_respect_absolute_limit_not_configured`: 目標を ±30 で振っている最中に `setMaxAngle` 相当（Task 6 で Axis が担う）は Planner の責務外。ここでは |pos| ≤ 30.0 + 0.05 を絶対上限として検査する
  - `test_rescale_keeps_output_pulse`: pos 30、gain 相当 f = 7.41/11.11 で `rescale(f)` 後 pos·(11.11/7.41) が 30（出力 µs 不変を Axis と組み合わせて確認するのは Task 6）

- [ ] **Step 2: 失敗を確認** `pio test -e native -f test_planner`

- [ ] **Step 3: 実装**（方式は作り手に委ねるが、契約は「毎 tick、加加速度を ±maxJerk／0 から選び、制動点が目標を越えない限り加速・巡航、越えるなら減速」。制動点は現在の acc を maxJerk で 0 に戻しつつ maxAcc で減速したときの到達位置。目標到達時は pos をスナップせず、|vel| が閾値未満かつ |pos−target| ≤ 0.1 で停止扱い）

- [ ] **Step 4: PASS を確認**

- [ ] **Step 5: コミット** `feat(firmware): add jerk-limited planner`

### Task 5: 定型動作の波形（driver: claude）

**Files:**
- Create: `firmware/lib/catneck/src/catneck/Gesture.h`, `Gesture.cpp`, `firmware/test/test_gesture/test_gesture.cpp`

**Interfaces:**
- Consumes: `GestureId`（Protocol.h）、`AxisLimits`（Axis.h）、`Config.h`
- Produces:
  - `struct GestureSpec { GestureId id; float ampDeg; uint8_t repeats; uint8_t speedPercent; }`（repeats は 1〜3 に、speed 0 は 100 に正規化して使う）
  - `struct JointTargets { float yaw; float pitch; }`
  - `class GesturePlayer { public: void start(const GestureSpec&, const AxisLimits& yaw, const AxisLimits& pitch, float dtSeconds = 0.02f); bool active() const; JointTargets step(); float totalSeconds() const; float stretch() const; static float baseCycleSeconds(GestureId); }`
  - 波形: 設計書 §4.4 の契約（始端・終端で位置 0・速度 0・加速度 0、極値 ±amp、C²。関数形は作り手が選ぶ。例: nod/shake は窓つき正弦 `A·sin(2πt/T)·sin²(πt/T)` を極値が ±amp になるよう正規化、tilt/look の移動区間は 5 次多項式 `6u⁵−15u⁴+10u³`）。nod は pitch で −amp が先（T = 1.0 s）、shake は yaw で +amp が先（T = 1.0 s）、tilt は yaw ±amp・pitch −amp/2 を 0.4 s で寄せ 1.5 s 保持 0.4 s で戻す、look は pitch ±amp を 1.0 s で移動 2.0 s 保持 1.0 s で戻す。基準時間は speed% で 100/speed 倍。`stretch` = max(1, vpeak/maxVel, √(apeak/maxAcc), ∛(jpeak/maxJerk))（maxAcc = 2·maxVel/0.2、maxJerk = 4·maxVel/0.04）を各軸の波形の数値微分から求めた最大値

- [ ] **Step 1: テストを書く**
  - `test_base_cycles`: Nod/Shake 1.0、TiltL 2.3、LookUp 4.0
  - `test_nod_waveform_shape`: amp 15、limits 十分大 → 最小値 −15±0.15 が先に、最大値 +15±0.15 が後に現れ、t=1.0 で 0±0.1、yaw 常に 0
  - `test_waveform_starts_and_ends_at_rest`: 6 種すべてで最初の 2 tick と最後の 2 tick の数値微分速度 ≤ 1°/s、加速度 ≤ 50°/s²（始端・終端で静止）
  - `test_stretch_when_limits_exceeded`: amp 15、pitch maxVel 50 → `stretch()` > 1、`totalSeconds()` = 1.0·stretch、全 tick の数値微分の速度 ≤ 50·1.02、加速度 ≤ 500·1.05、加加速度 ≤ 5000·1.1
  - `test_repeats_and_speed`: repeats 2、speed 50 → total 4.0 s（stretch 1 のとき）
  - `test_tilt_uses_both_axes`: TiltR amp 12 → 保持中 yaw −12、pitch −6

- [ ] **Step 2: 失敗を確認** `pio test -e native -f test_gesture`

- [ ] **Step 3: 実装**

- [ ] **Step 4: PASS を確認**

- [ ] **Step 5: コミット** `feat(firmware): add gesture waveforms`

### Task 6: 安全状態機械 Supervisor（driver: codex）

**Files:**
- Create: `firmware/lib/catneck/src/catneck/Supervisor.h`, `Supervisor.cpp`, `firmware/test/test_supervisor/test_supervisor.cpp`

**Interfaces:**
- Consumes: Task 2〜5 の全型
- Produces:
  - `struct CalBlob { uint8_t version; int16_t yawOffDeci; int16_t pitchOffDeci; uint8_t invert; uint16_t yawGainCenti; uint16_t pitchGainCenti; uint16_t crc16; }`（`crc16` は先頭から `pitchGainCenti` までの CRC-16/CCITT-FALSE）、`constexpr uint8_t kCalBlobVersion = 1`、`uint16_t calBlobCrc(const CalBlob&)`
  - `class Storage { public: virtual ~Storage() = default; virtual bool save(const CalBlob&) = 0; virtual bool load(CalBlob&) = 0; }`
  - `enum class Source : uint8_t { Ble, Serial }`
  - `struct Outputs { bool pwmEnabled; float yawPulseUs; float pitchPulseUs; }`
  - `class Supervisor { public: Supervisor(Storage&, uint32_t bootMillis, bool brownout); void onCommand(const Command&, Source, uint32_t nowMillis); void onRejected(); void onLink(bool connected, uint32_t nowMillis); void setPairOpen(bool); GainResult setGain(float yawUsPerDeg, float pitchUsPerDeg); bool saveCalibration(uint8_t req); Outputs tick(uint32_t nowMillis); Status status() const; CalibrationData calibration() const; CalibrationSnapshot calibrationSnapshot() const; LimitsData limits() const; SupervisorState state() const; bool lastSaveOk() const; }`
  - `enum class GainResult : uint8_t { Saved, Rejected, SaveFailed }`（Rejected = 範囲外・非静止・再表現後に設定上限外。不変。SaveFailed = RAM には適用済みだが NVS 保存に失敗。CAL_DIRTY 1。SAVE_ERROR/`save_seq` は変えない）
  - `struct CalibrationSnapshot { float yawOffset; float pitchOffset; bool yawInvert; bool pitchInvert; float yawGain; float pitchGain; bool saved; }`（テストとシリアル `INFO` 用。BLE の 6 B 契約は `calibration()` のまま）
  - 規則は設計書 §4.5 の表と §4.4 の競合規則、§4.6 の各コマンドの動作、§4.3 の 3 tick ずらし（両軸が同時に静止から動き出す tick ではピッチの目標更新を 3 tick 遅らせる）。`setGain` は両軸が静止し、再表現後のジョイント角が設定上限内のときだけ受理（Rejected なら不変）。受理時は Planner を `rescale(oldGain/newGain)` してから新ゲインを使い、保存まで行う（失敗は SaveFailed、RAM 側は適用済み）。`saveCalibration(req)` は SAVE_CAL と同じ処理（シリアル `SAVE` 用、結果を返す）。`saveSeq` は SAVE_CAL/`saveCalibration` の処理ごとに req へ更新

- [ ] **Step 1: テストを書く**（`FakeStorage : Storage` に `failSave`／`corrupt` フラグ。仮想時計は `uint32_t now` を手で進め、`tick(now)` を 20 ms ごとに呼ぶヘルパ `advance(ms)`）
  - `test_boot_mute_then_center_then_idle`: 0〜480 ms は `pwmEnabled == false`、500 ms で true かつ両軸 1500 µs、1500 ms で IDLE（false）
  - `test_boot_discards_requests_but_remembers_stop`: 100 ms に MOVE → 破棄、`rejectedCount` 0。別ケースで 100 ms に STOP → 500 ms で BOOT_CENTER を経ず IDLE
  - `test_move_from_idle_activates_and_moves`: MOVE(20°, −5°, 100) → ACTIVE、数 tick 後に yaw パルスが 1500 から増加、ピッチは 3 tick 遅れて動き出す
  - `test_silence_3s_returns_then_relaxes`: ACTIVE で 3.0 s 無通信 → RETURNING（Returning フラグ）、中立到達後 2.0 s で IDLE。PING を 1 Hz で送り続ければ ACTIVE のまま
  - `test_disconnect_during_gesture_returns_immediately`: GESTURE 再生中に `onLink(false)` → 即 RETURNING、Gesture フラグ 0
  - `test_ping_after_reconnect_does_not_resume`: RETURNING 中に `onLink(true)` と PING → RETURNING 継続、IDLE まで到達
  - `test_return_deadline_2s`: maxVel 最小でも 2.0 s で RELAX_WAIT へ
  - `test_stop_is_highest_priority`: RETURNING 中の STOP → 即 IDLE、pwmEnabled false
  - `test_rejected_input_does_not_feed_watchdog`: ACTIVE で `onRejected()` だけを 3 s 続けても RETURNING へ
  - `test_gesture_queue_rules`: GESTURE 中の MOVE は完了後に適用、GESTURE 中の GESTURE は保留 1 件（新しい方が残る）
  - `test_maintenance_requests_do_not_cancel_return`: RETURNING 中と RELAX_WAIT 中のそれぞれで SAVE_CAL(req)・SET_LIMITS・PING を送っても状態が変わらず IDLE まで到達
  - `test_torque_off_discards_playing_and_pending`: GESTURE 再生中に GESTURE と MOVE を保留させてから TORQUE 0 → IDLE、Gesture フラグ 0、その後 PING だけでは動かない
  - `test_set_limits_during_gesture_follows_transition_rule`: shake large 再生中に SET_LIMITS で yaw 速度上限を 120 → 20 に下げる → 以後の全 tick |yaw 速度| ≤ 120.5、T_tr 後 ≤ 20.5、上限内で再生が終わる
  - `test_nod_large_through_planner_meets_timing`: 既定上限で GESTURE nod amp 15 repeats 1 speed 100 → ピッチ出力（ジョイント角換算）の最小値 ≤ −13.5、最大値 ≥ +13.5、開始から静止まで 1.0〜1.3 s、全 tick で速度・加速度・加加速度が上限内、終端で静止
  - `test_set_cal_from_idle_starts_output_smoothly`: IDLE で SET_CAL(50, 0, 0) → ACTIVE、出力 µs が tick ごとに連続（1 tick の差 ≤ maxVel·dt·gain·1.05）、CalDirty 1
  - `test_save_success_clears_dirty`: SAVE_CAL(req 5) → `lastSaveOk`、CalDirty 0、`saveSeq` 5、FakeStorage の blob の CRC が `calBlobCrc` と一致。同じ req 5 の再送で結果が同じ（保存値が同一なら FakeStorage の save 回数が増えない）。req 0 は `onRejected` 経路（`rejectedCount` +1）
  - `test_save_failure_sets_save_error_and_sets_save_seq`: failSave で SAVE_CAL(req 6) → SaveError 1、CalDirty 1、`saveSeq` 6。続けて SET_CAL を送っても SaveError 1・`saveSeq` 6 のまま。failSave を解いて SAVE_CAL(req 7) → SaveError 0、`saveSeq` 7
  - `test_corrupt_blob_falls_back_to_defaults`: corrupt → 起動後 offset 0、gain 11.11、CalDirty 1
  - `test_set_limits_rules_and_mid_motion`: 0 欄は変更なし、下限飽和で Saturated、yaw 50° 静止中に角度上限を 10° に下げると目標が 10° に再飽和され出力は連続（S 字）で 10° 相当へ収束、その間も |位置| ≤ 60°
  - `test_gain_change_keeps_pulse`: ACTIVE で中立（0°）静止中に `setGain(7.41, 7.41)` → Saved、直後の tick の出力 µs が変更前と等しく（1500）、その後 yaw 30° を指令すると新ゲインで 1722 µs へ
  - `test_gain_rejected_while_moving_or_out_of_range`: 移動中の `setGain` → Rejected で出力 µs と `calibrationSnapshot().yawGain` 不変。yaw 30° 静止中に `setGain(5.0, 5.0)`（再表現後 66.7° > 60°）→ Rejected。`setGain(4.9, 11.11)` → Rejected
  - `test_gain_save_failure_keeps_ram_value_and_marks_dirty`: failSave で中立静止中に `setGain(7.41, 7.41)` → SaveFailed、`calibrationSnapshot().yawGain` 7.41、CalDirty 1、SaveError と `saveSeq` 不変
  - `test_status_fields`: brownout 起動で Brownout 1、PING seq 反映、`rejectedCount` が 255 で止まる、`voltageCenti` 0、state 値、起動直後の `saveSeq` 0
  - `test_return_speed_switch_uses_transition_rule`: yaw 120°/s で移動中に切断 → RETURNING で速度が 90°/s へ旧 j_max で減速し、移行中も 120 を超えない

- [ ] **Step 2: 失敗を確認** `pio test -e native -f test_supervisor`

- [ ] **Step 3: 実装**（内部に `Axis yaw, pitch`、`Planner yawPlanner, pitchPlanner`（サーボ角空間）、`GesturePlayer`、保留 MOVE/GESTURE、最終通信時刻、状態と状態に入った時刻。安全復帰は Planner の maxVel を一時的に `kReturnYawVel`/`kReturnPitchVel` にし、ACTIVE に戻るとき Limits の値へ戻す）

- [ ] **Step 4: PASS を確認**、`pio test -e native` 全件 PASS

- [ ] **Step 5: コミット** `feat(firmware): add safety supervisor state machine`

### Task 7: シリアル行の解釈（driver: claude）

**Files:**
- Create: `firmware/lib/catneck/src/catneck/SerialParser.h`, `SerialParser.cpp`, `firmware/test/test_serial_parser/test_serial_parser.cpp`

**Interfaces:**
- Consumes: `decodeCommand`、`Command`
- Produces:
  - `enum class ConsoleAction : uint8_t { None, Status, WatchOn, WatchOff, Info, Help, BondsClear, PairOpen, Gain }`
  - `struct ParsedLine { enum class Kind : uint8_t { Command, Action, Error } kind; Command command; ConsoleAction action; float gainYaw; float gainPitch; const char* error; }`（`error` は `"BAD_ARGS"` / `"UNKNOWN"` / `"RANGE"` の静的文字列）
  - `ParsedLine parseLine(const char* line, size_t len)`（大文字小数区別なし、CR 無視、角度・速度は度の小数を 0.1 単位に丸め、`GESTURE` は id 数値または `nod/shake/tilt_l/tilt_r/look_up/look_down`、`HEX` は 16 進バイト列を `decodeCommand` に通す）
  - `size_t formatStatusLine(const Status&, char* out, size_t cap)` → `STATUS yaw=<deg> pitch=<deg> flags=0x<hex4> seq=<n> state=<n> err=<n> save=<n>`

- [ ] **Step 1: テストを書く**
  - `test_move_line`: `"move 20 -5 100"` → Move 200/−50/100。`"MOVE 20"` → Error BAD_ARGS
  - `test_gesture_names_and_ids`: `"GESTURE nod 15"` → Nod/150/1/0。`"gesture 2 25 3 50"`。`"gesture jump 1"` → BAD_ARGS
  - `test_simple_commands`: STOP / CENTER 50 / TORQUE 1 / PING 9 / SAVE 3（SaveCal req 3）/ SAVE（req 0 = 「前回 +1」を Console が埋める印）/ CAL 2.5 -1 3 / LIMITS 120 100 60 30
  - `test_actions`: STATUS、WATCH ON/OFF、INFO、HELP、BONDS CLEAR、PAIR OPEN。`GAIN 11.11 11.11` → Action Gain。`GAIN 4 11` → Error RANGE
  - `test_hex_matches_binary_decoder`: `"HEX 01 C8 00 CE FF 64"` → `decodeCommand` と同じ Command。`"HEX 02 00"` → Error（復号エラー名）
  - `test_unknown_and_crlf`: `"FOO\r"` → UNKNOWN。末尾 CR が無視される
  - `test_format_status_line`

- [ ] **Step 2: 失敗を確認** `pio test -e native -f test_serial_parser`

- [ ] **Step 3: 実装**

- [ ] **Step 4: PASS を確認**

- [ ] **Step 5: コミット** `feat(firmware): add serial command parser`

### Task 8: 実機アダプタとシリアル経路の結線（driver: codex）

**Files:**
- Create: `firmware/src/platform/ServoDriver.h/.cpp`, `firmware/src/platform/NvsStorage.h/.cpp`, `firmware/src/platform/SerialTransport.h/.cpp`, `firmware/src/Console.h/.cpp`
- Modify: `firmware/src/main.cpp`

**Interfaces:**
- Consumes: `Supervisor`、`parseLine`、`formatStatusLine`、`Outputs`
- Produces:
  - `class ServoDriver { public: ServoDriver(int yawPin = 3, int pitchPin = 5); void apply(const Outputs&); bool attached() const; }`（`pwmEnabled` が false → `detach()`、true → 未接続なら `attach(pin, 500, 2500)` と `setPeriodHertz(50)` のうえ `writeMicroseconds`）
  - `class NvsStorage : public Storage`（Preferences 名前空間 `"catneck"`、キー `"cal"`、`putBytes`/`getBytes`、`save` は書き込み後に読み戻して一致で true）
  - `class SerialTransport { public: bool readLine(char* buf, size_t cap, size_t& len); void println(const char*); }`（LF 区切り、cap 超過は捨てて `ERR BAD_ARGS`）
  - `class Console { public: Console(Supervisor&, SerialTransport&, BleHooks&); void poll(uint32_t now); void onTick(const Status&, uint32_t now); }`（`BleHooks` は Task 9 が実装する `struct BleHooks { virtual void clearBonds() = 0; virtual void openPairWindow() = 0; virtual void fillInfo(char* out, size_t cap) = 0; }`。Task 8 では空実装を main に置く。`SAVE [req]` は req 省略時に前回 +1（0 を飛ばす）を補って `supervisor.saveCalibration(req)` を呼び、結果で `OK seq=<req>` / `ERR SAVE`。`GAIN` は `setGain` の Rejected を `ERR RANGE`、SaveFailed を `ERR SAVE` にする）
  - `main.cpp`: `setup()` で `Serial.begin(115200)`、リセット理由（`esp_reset_reason() == ESP_RST_BROWNOUT`）、`NvsStorage`、`Supervisor`、起動行 `CATNECK fw=0.1.0 proto=1 hw=E17 reset=<理由> brownout=<0|1>`。`loop()` で `Console::poll`、`millis()` が 20 ms 進むごとに `supervisor.tick` → `ServoDriver::apply`、`WATCH ON` 中は 200 ms ごとに STATUS 行

- [ ] **Step 0: `platformio.ini` に `[env:xiao_bringup]` を追加**（`extends = env:xiao`、`build_flags = ${env:xiao.build_flags} -DCATNECK_NO_PWM`）。`ServoDriver::apply` は `CATNECK_NO_PWM` 定義時に何もしない（attach もしない）。起動行に `pwm=off` を付ける

- [ ] **Step 1: `pio run -e xiao` と `pio run -e xiao_bringup` の両方で SUCCESS を確認し、無人のときは bring-up だけを書き込む**（`pio run -e xiao_bringup -t upload --upload-port /dev/cu.usbmodem101`。通常 `xiao` の初回書き込みは利用者在席の Task 12）

- [ ] **Step 2: 無人で可能な実機確認（bring-up ビルド、サーボ出力なし）**: `pio device monitor` で起動行が出る、`INFO`／`STATUS`／`HELP` が応答する、`PING 5` の後の `STATUS` に `seq=5`、`HEX 09 07`（PING seq 7）に `OK` と `STATUS` の `seq=7`。**動作要求はここでは送らない**（HEX でも同じ）

- [ ] **Step 3: 結果を検証記録に書く**（`docs/validation/2026-10-23-xiao-firmware.md` に日時・ボード・platform 版・起動行の実物）

- [ ] **Step 4: コミット** `feat(firmware): wire supervisor to servo, NVS and serial console`

### Task 9: BLE GATT サーバ（driver: claude）

**Files:**
- Create: `firmware/src/platform/BleTransport.h/.cpp`
- Modify: `firmware/src/main.cpp`

**Interfaces:**
- Consumes: `Supervisor`、`encodeStatus`/`encodeCalibration`/`encodeLimits`/`encodeInfo`、`decodeCalibrationWrite`/`decodeLimitsWrite`、`BleHooks`
- Produces:
  - `class BleTransport : public BleHooks { public: void begin(Supervisor&); void poll(uint32_t now); void publishStatus(const Status&, bool changed, uint32_t now); const char* name() const; }`（NimBLE のコールバックは `struct BleEvent { enum class Kind : uint8_t { CommandWrite, CalibrationWrite, LimitsWrite, LinkUp, LinkDown } kind; uint8_t len; uint8_t data[20]; }` を固定長リングキュー（16 件、あふれは最古を捨てて数える）に積むだけ。`poll` は loop 側でキューを取り出し、CommandWrite → `decodeCommand`、CalibrationWrite → `decodeCalibrationWrite`、LimitsWrite → `decodeLimitsWrite` で復号して `supervisor.onCommand(…, Source::Ble, now)` / `onRejected()` に流し、LinkUp/LinkDown → `supervisor.onLink(…)`。GATT の Read 値は loop 側で `setCharacteristicValues(const Status&, const CalibrationData&, const LimitsData&)` が特性にコピーしたスナップショットで、コールバックからコアを読まない。`publishStatus` は 200 ms ごと、または `changed` なら即時に Notify）
  - GATT: サービス `C47B0000-6D1F-4B9E-9C9A-2A3B4C5D6E7F`、Command `…0001` WRITE_NR|WRITE_ENC、Status `…0002` NOTIFY|READ|READ_ENC、Calibration `…0003` READ|WRITE|READ_ENC|WRITE_ENC、Limits `…0004` 同、Info `…0005` READ。`NimBLEDevice::setSecurityAuth(true, false, true)`、IO cap NoInputNoOutput。接続間隔 12〜24 単位を接続後に要求。アドバタイズ名 `CatRobot-XXXX`（`NimBLEDevice::getAddress()` の末尾 2 B、大文字）、スキャン応答にサービス UUID。接続で `onLink(true)`、切断で `onLink(false)` とアドバタイズ再開
  - ペアリング窓: ボンド数 0 なら常時可。それ以外は起動後 60 s と `openPairWindow()` 後 60 s のみ。窓外で未ボンドの central が接続したら切断。`setPairOpen` を Supervisor に反映。`clearBonds()` は `NimBLEDevice::deleteAllBonds()`
  - `fillInfo` → `INFO fw=0.1.0 proto=1 hw=E17 addr=<aa:bb:…> name=CatRobot-XXXX bonds=<n> pair_open=<0|1> reset=<理由>`

- [ ] **Step 1: 実装し `pio run -e xiao` と `pio run -e xiao_bringup` が SUCCESS。無人のときは bring-up を書き込む**

- [ ] **Step 2: 無人で可能な確認（bring-up ビルド）**: シリアル `INFO` にアドレスと名前が出る（設計書 §3.2 の見込み `…5E:8E` / `CatRobot-5E8E` と照合し、違えば設計書 §3.2 を更新）。Mac の `system_profiler SPBluetoothDataType` または Task 10 の `scan` でアドバタイズが見える

- [ ] **Step 3: 検証記録に追記、コミット** `feat(firmware): add NimBLE GATT server with bonding window`

### Task 10: Mac 用試験ツール（driver: codex）

**Files:**
- Create: `firmware/tools/ble_client.py`, `firmware/tools/serial_cli.py`

**Interfaces:**
- `ble_client.py`（PEP 723: `requires-python = ">=3.10"`, `dependencies = ["bleak==3.0.2"]`）: サブコマンド `scan`、`info`、`watch [--seconds N]`、`move YAW PITCH [--speed S]`、`gesture {nod,shake,tilt_l,tilt_r,look_up,look_down} AMP [--repeats R] [--speed S]`、`stop`、`center [--speed S]`、`torque {0,1}`、`cal get|set YOFF POFF INVERT|save`、`limits get|set YV PV YA PA`、`keepalive [--seconds N]`、`demo`（6 種 × small/medium/large を順に。各 1 秒の PING を挟み、設計書 付録 B の振幅: nod 5/10/15、shake 8/15/25、tilt 8/12/15、look 8/14/20）、`latency [--count 10]`（MOVE 書き込み → MOVING=1 の Status までの中央値）、`reconnect`。接続先は `--name CatRobot-XXXX` または `--address <UUID>`。接続の寿命: 各サブコマンドは接続を保ったまま 1 Hz で PING を送りつつ完了を待つ。`move`/`center` は MOVING=0 を 0.5 s 観測するまで、`gesture` と `demo` は GESTURE=0 を観測するまで（look の 4 秒周期も PING で維持）、`torque`/`cal set`/`limits set` は次の Status を 1 件受けるまで。完了後 `--hold N` 秒（既定 0）だけ保ってから切断する（切断で安全復帰が始まるのは仕様どおり）。`cal save` は設計書 §4.6 の手順を実装する: 送信前に Calibration を Read してスナップショット（意図値）を取り、直前 Status の `save_seq` と異なる req で SAVE_CAL、`save_seq` = req の Status を待ち、1 秒で同じ req を再送（最大 3 回）、成功後に Calibration を再 Read して `saved` = 1 かつスナップショットと一致を照合して結果を表示
- `serial_cli.py`（`dependencies = ["pyserial==3.5"]`）: `--port /dev/cu.usbmodem101`、引数の行を送って応答を表示、`--watch` で `WATCH ON` の流し読み

- [ ] **Step 1: 実装**（Python 単体テストは書かない。Status 復号関数 `decode_status(bytes) -> dict`（キー: yaw, pitch, flags, seq, state, voltage, rejected, save_seq） を両ツールで共有できる形にし、`uv run tools/ble_client.py --help` が動くことを確認）

- [ ] **Step 2: 無人で可能な確認**: `uv run tools/ble_client.py scan` で本機が見える。`info`（Info は暗号化不要）が `proto=1 fw=0.1.0 hw=1` を返す。`watch --seconds 3` で Status が 5 Hz で届く（初回はペアリングダイアログの可能性。Mac 側のペアリングが成立したら検証記録に記す）。`uv run tools/serial_cli.py --port /dev/cu.usbmodem101 STATUS` が応答する。**動作要求は送らない**

- [ ] **Step 3: 検証記録に追記、コミット** `feat(firmware): add Mac BLE and serial test tools`

### Task 11: 手順書・要件定義書の修正・検証記録の整備（driver: claude）

**Files:**
- Create: `firmware/README.md`
- Modify: `docs/superpowers/specs/2026-10-11-cat-robot-claude-neck-requirements.md`（設計書 §8 の表どおり 14 箇所）、`docs/validation/2026-10-23-xiao-firmware.md`（T-FW-0〜10 の表を未実施の状態で用意し、Task 8〜10 の結果を転記）、`README.md`（リポジトリ直下: `firmware/` の 1 段落と手順書への参照）

- [ ] **Step 1: `firmware/README.md`**（日本語。導入 `brew install platformio`、4 コマンド、`/dev/cu.usbmodem*` の見つけ方、試験ツールの使い方、ゲイン校正手順（設計書 §4.3）、19 V と USB の注意（設計書 §3.1）、platform を pioarduino に切り替えた場合はその理由）

- [ ] **Step 2: 要件定義書を §8 の表どおりに修正**（差分は navigator が表と 1 対 1 で照合）

- [ ] **Step 3: 検証記録の表を整え、未実施項目を「未実施」と明記**

- [ ] **Step 4: コミット** `docs: add firmware guide and align requirements with protocol v1`

### Task 12: 実機受入（人間主導、利用者在席時）

**Files:**
- Modify: `docs/validation/2026-10-23-xiao-firmware.md`、必要なら設計書 §3.2／§7

- [ ] **Step 1: T-FW-0 脱力の確認**（19 V 投入、`torque 1` → `torque 0` で手で回せる・唸らない）
- [ ] **Step 2: T-FW-5 ゲインと回転方向**（設計書 §4.3 の手順。0° 基準 → +5° で方向 → +15°/+30° でゲイン → `GAIN` 保存 → +30° 再確認 → ヨー独立確認 → ±60°/±30° でリミット非接触）
- [ ] **Step 3: T-FW-1 起動**、**T-FW-2 定型動作**（`demo`。USB 同時接続で切れないこと＝設計書 R1）、**T-FW-3 安全復帰**、**T-FW-4 キャリブレーション保存**（19 V と USB の両方を切る）、**T-FW-6 遅延**、**T-FW-7 再接続**、**T-FW-8 シリアル同等性**、**T-FW-9 ペアリング**（二台目が無ければ未実施と記録）
- [ ] **Step 4: 結果と実測値を検証記録に書き、不合格は設計書 §7 の分岐へ**
- [ ] **Step 5: コミット** `docs: record firmware device acceptance`、`feature/claude-neck` への統合は利用者の go で

---

## 自己点検（計画作成時）

- 設計書 §4.1〜§4.11、§5、§8 の各項目に対応するタスクがある（§4.9 → Task 10、§4.11 → 各タスクの運用、§8 → Task 11）
- 型名・関数名は Task 2〜7 の Interfaces で統一（`Command`、`Status`、`Outputs`、`Storage`、`CalBlob`、`parseLine`、`formatStatusLine`）
- Review Focus の 5 件はそれぞれ Task 2/4/6 のテスト名で固定
- 無人で首を動かさない制約は Task 8〜10 の Step に明記
