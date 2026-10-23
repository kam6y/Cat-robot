// 安全状態機械（設計書 §4.5）。コマンド・リンク・tick を受けて PWM 許可と各軸のパルス幅を決める。Arduino 非依存。
// 定型動作は GesturePlayer の波形（設計書 §4.4）を tick ごとにそのままサーボ角にする。中断時は直前の標本から
// 速度・加速度を推定して Planner に引き渡す（利用者の実機比較で波形出力を採用、ledger Task 12）。
#pragma once

#include <cstdint>

#include "catneck/Axis.h"
#include "catneck/Config.h"
#include "catneck/Gesture.h"
#include "catneck/Planner.h"
#include "catneck/Protocol.h"

namespace catneck {

// NVS に 1 キーで保存するキャリブレーション一式（設計書 §4.8）
struct CalBlob {
    uint8_t version;
    int16_t yawOffDeci;
    int16_t pitchOffDeci;
    uint8_t invert;          // bit0 ヨー、bit1 ピッチ
    uint16_t yawGainCenti;   // 0.01 µs/°
    uint16_t pitchGainCenti;
    uint16_t crc16;          // version〜pitchGainCenti の CRC-16/CCITT-FALSE（calBlobCrc）
};
constexpr uint8_t kCalBlobVersion = 1;
// CRC と構造体のパディングを除き、保存対象の校正値が一致するか。
bool sameCalibration(const CalBlob& a, const CalBlob& b);
// version から pitchGainCenti までを 10 B（多バイトはリトルエンディアン）に並べて計算する。
uint16_t calBlobCrc(const CalBlob& blob);

class Storage {
public:
    virtual ~Storage() = default;
    virtual bool save(const CalBlob& blob) = 0;  // 書き込み後の読み戻しが一致したら true
    virtual bool load(CalBlob& out) = 0;         // 読めなければ false
};

enum class Source : uint8_t { Ble, Serial };

struct Outputs {
    bool pwmEnabled;
    float yawPulseUs;
    float pitchPulseUs;
};

enum class GainResult : uint8_t {
    Saved,       // 適用して保存した
    Rejected,    // 範囲外・非静止・再表現後に設定上限外。何も変えていない
    SaveFailed,  // RAM には適用したが NVS 保存に失敗（CAL_DIRTY）
};

struct CalibrationSnapshot {
    float yawOffset;
    float pitchOffset;
    bool yawInvert;
    bool pitchInvert;
    float yawGain;
    float pitchGain;
    bool saved;
};

class Supervisor {
public:
    Supervisor(Storage& storage, uint32_t bootMillis, bool brownout);

    void onCommand(const Command& command, Source source, uint32_t nowMillis);
    void onRejected();
    void onLink(bool connected, uint32_t nowMillis);
    void setPairOpen(bool open);
    // シリアルの GAIN。保守要求（通信扱い、状態は変えない）。BOOT 中は破棄して Rejected
    GainResult setGain(float yawUsPerDeg, float pitchUsPerDeg, uint32_t nowMillis);
    // SAVE_CAL と同じ処理（シリアル SAVE 用、結果を返す）。req 0 は拒否、BOOT 中は破棄
    bool saveCalibration(uint8_t req, uint32_t nowMillis);
    Outputs tick(uint32_t nowMillis);

    Status status() const;
    CalibrationData calibration() const;
    CalibrationSnapshot calibrationSnapshot() const;
    LimitsData limits() const;
    SupervisorState state() const { return state_; }
    bool lastSaveOk() const { return lastSaveOk_; }

private:
    enum class GesturePhase : uint8_t { None, Centering, Playing };

    struct AxisUnit {
        Axis axis;
        Planner planner;
        float jointTarget = 0.0f;  // 最後に指令したジョイント角（飽和後）
        AxisUnit(AxisAbsolute abs, float defaultVel) : axis(abs, defaultVel) {}
    };

    void enterState(SupervisorState next, uint32_t nowMillis);
    bool acceptMotionRequest(uint32_t nowMillis);
    void acceptMaintenanceRequest(uint32_t nowMillis);
    void handleStop(uint32_t nowMillis);
    void noteAccepted(bool saturated);
    bool pwmEnabled() const;

    void applyJointTargets(float yawJoint, float pitchJoint, bool* saturated);
    void setServoTargets(float yawServo, float pitchServo);
    void reapplyJointTargets();
    void applyPlannerVelocities();
    void freezePlanners();
    bool plannersAtRest() const;

    void startGesture(const GestureSpec& spec);
    void serviceGesture();
    void playWaveformTick();
    void applyGestureSample(float yawJoint, float pitchJoint);
    void handOverFromWaveform();
    void finishGesture();
    void discardMotion();

    CalBlob currentBlob() const;
    bool isDirty() const;
    bool persist();

    Storage& storage_;
    uint32_t bootMillis_;
    bool brownout_;
    SupervisorState state_ = SupervisorState::Boot;
    uint32_t lastCommMillis_ = 0;
    uint32_t returnStartMillis_ = 0;
    uint32_t relaxStartMillis_ = 0;
    bool stopDuringBoot_ = false;
    bool linkUp_ = false;
    bool pairOpen_ = false;

    AxisUnit yaw_;
    AxisUnit pitch_;
    uint8_t speedPercent_ = 100;

    // ピッチの 3 tick ずらし
    bool pitchHeld_ = false;
    float pitchHeldTarget_ = 0.0f;
    uint32_t pitchHoldTicks_ = 0;

    GesturePhase phase_ = GesturePhase::None;
    GesturePlayer wave_;
    GestureSpec activeGesture_{};
    float pitchDelay_[config::kStaggerTicks]{};  // ピッチを 3 tick 遅らせる環（FW-PWR-1）
    uint8_t pitchDelayIndex_ = 0;
    uint8_t drainTicks_ = 0;                     // 波形終了後に環を吐き出す残り tick
    float yawHist_[3]{};                         // 直前 3 標本のサーボ角（受け渡しの速度・加速度推定）
    float pitchHist_[3]{};
    bool hasPendingGesture_ = false;
    GestureSpec pendingGesture_{};
    bool hasPendingMove_ = false;
    float pendingMoveYaw_ = 0.0f;
    float pendingMovePitch_ = 0.0f;
    uint8_t pendingMoveSpeed_ = 0;

    // Status の欄
    uint8_t pingSeq_ = 0;
    bool rejected_ = false;
    bool saturated_ = false;
    bool saveError_ = false;
    uint8_t rejectedCount_ = 0;
    uint8_t saveSeq_ = 0;
    bool lastSaveOk_ = false;

    CalBlob savedBlob_{};
    bool haveSaved_ = false;
};

}  // namespace catneck
