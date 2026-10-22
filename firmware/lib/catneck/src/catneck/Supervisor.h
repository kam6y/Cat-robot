// 安全状態機械（設計書 §4.5）。コマンド・リンク・tick を受けて PWM 許可と各軸のパルス幅を決める。Arduino 非依存。
// 定型動作は「極値を経由する静止→静止の S 字移動の列」として Planner に流す（ledger Task 6 の ruling。
// 波形を tick ごとに追従させる方式は、目標で停止できることを保証する Planner では制動距離ぶん遅れて振幅と時間が崩れる）。
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

    // 定型動作の 1 区切り: 両軸のジョイント目標と、到達後に保持する tick 数
    struct GestureStep {
        float yaw;
        float pitch;
        uint32_t holdTicks;
    };
    static constexpr uint8_t kMaxGestureSteps = 8;

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

    void applyJointTargets(float yawJoint, float pitchJoint, bool* saturated);
    void setServoTargets(float yawServo, float pitchServo);
    void reapplyJointTargets();
    void applyPlannerVelocities();
    void freezePlanners();
    bool plannersAtRest() const;

    void startGesture(const GestureSpec& spec);
    void buildGestureSteps(const GestureSpec& spec);
    void applyGestureStep();
    void serviceGesture();
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
    GestureStep steps_[kMaxGestureSteps]{};
    uint8_t stepCount_ = 0;
    uint8_t stepIndex_ = 0;
    uint32_t holdRemaining_ = 0;
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
