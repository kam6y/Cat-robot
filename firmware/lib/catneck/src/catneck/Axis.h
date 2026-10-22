// 1 軸ぶんの角度制限・キャリブレーション・パルス変換（設計書 §4.3）。
#pragma once

#include "catneck/Config.h"

namespace catneck {

// ファームウェアが固定する絶対上限（SET_LIMITS で広げられない）
struct AxisAbsolute {
    float maxAngle;  // ジョイント角の絶対値上限 [°]
    float maxVel;    // 速度の絶対値上限 [°/s]
};

constexpr AxisAbsolute kYawAbs{config::kYawMaxAngle, config::kYawAbsVel};
constexpr AxisAbsolute kPitchAbs{config::kPitchMaxAngle, config::kPitchAbsVel};

// アプリが SET_LIMITS で変えられる設定上限
struct AxisLimits {
    float maxAngle;
    float maxVel;
};

struct AxisCalibration {
    float offset;  // 中立オフセット [°]（±kMaxOffset）
    bool invert;   // 回転方向の反転
    float gain;    // µs/°
};

class Axis {
public:
    Axis(AxisAbsolute abs, float defaultVel);

    // ジョイント角を設定上限で飽和させる。saturated は必ず書く。
    float clampJoint(float jointDeg, bool* saturated) const;
    // ジョイント角 → サーボ角（オフセット加算のあと反転）
    float jointToServo(float jointDeg) const;
    // サーボ角 → ジョイント角（逆変換）
    float servoToJoint(float servoDeg) const;
    // サーボ角 → パルス幅 [µs]（500〜2500 で飽和）
    float servoToPulseUs(float servoDeg) const;

    // 0 は「変更しない」。絶対上限と下限で飽和。負の角度上限は拒否（false、不変）。
    bool setLimits(float maxAngleOrZero, float maxVelOrZero, bool* saturated);
    // オフセットは ±kMaxOffset で飽和。
    bool setCalibration(float offsetDeg, bool invert, bool* saturated);
    // 5.00〜15.00 かつ有限のときだけ受理。
    bool setGain(float gainUsPerDeg);

    const AxisLimits& limits() const { return limits_; }
    const AxisCalibration& calibration() const { return cal_; }
    const AxisAbsolute& absolute() const { return abs_; }

private:
    AxisAbsolute abs_;
    AxisLimits limits_;
    AxisCalibration cal_;
};

}  // namespace catneck
