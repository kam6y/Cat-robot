#include "catneck/Gesture.h"

#include <algorithm>
#include <cmath>

namespace catneck {

namespace {

constexpr float kPi = 3.14159265358979f;

// 窓つき正弦 g(x) = sin(2πx)·sin²(πx) / N。N は |g| の最大値（x = 1/3 で +1、2/3 で −1）。
constexpr float kWindowedSineNorm = 0.649519052838329f;

float windowedSine(float x) {
    const float s = std::sin(kPi * x);
    return std::sin(2.0f * kPi * x) * s * s / kWindowedSineNorm;
}

// 位相 x に関する 1〜3 階導関数の絶対値の最大（正規化後）。解析式 2 s³ c の導関数を 200,001 点で走査した値
// （test_gesture が走査と照合する）。実行時に走査すると ESP32-C3（FPU なし）で 1 軸 12 ms かかる
constexpr WaveformPeaks kWindowedSinePeaks{9.673596609f, 83.142789030f, 954.745716690f};

// 5 次の滑らかな移動 q(u) = 6u⁵ − 15u⁴ + 10u³（両端で速度・加速度 0）
float smoothStep(float u) {
    if (u <= 0.0f) return 0.0f;
    if (u >= 1.0f) return 1.0f;
    return u * u * u * (u * (6.0f * u - 15.0f) + 10.0f);
}
constexpr float kSmoothStepPeakV = 1.875f;   // max |q'|
constexpr float kSmoothStepPeakA = 5.7735f;  // max |q''|
constexpr float kSmoothStepPeakJ = 60.0f;    // max |q'''|

// 移動 → 保持 → 戻り の 3 区間（秒）。基準周期に対する割合で持つ。
struct HoldShape {
    float move;
    float hold;
};

HoldShape holdShape(GestureId id) {
    switch (id) {
        case GestureId::TiltL:
        case GestureId::TiltR:
            return HoldShape{0.4f, 1.5f};
        case GestureId::LookUp:
        case GestureId::LookDown:
            return HoldShape{1.0f, 2.0f};
        default:
            return HoldShape{0.0f, 0.0f};
    }
}

// 保持型の波形: 位相 x（0〜1）→ 0〜1 の到達度
float holdProfile(GestureId id, float x) {
    const HoldShape shape = holdShape(id);
    const float total = GesturePlayer::baseCycleSeconds(id);
    const float t = x * total;
    if (t < shape.move) return smoothStep(t / shape.move);
    if (t < shape.move + shape.hold) return 1.0f;
    return 1.0f - smoothStep((t - shape.move - shape.hold) / shape.move);
}

// 軸ごとの振幅（度）。保持型は到達度に掛ける係数。
void axisAmplitudes(GestureId id, float amp, float& yaw, float& pitch) {
    switch (id) {
        case GestureId::Nod: yaw = 0.0f; pitch = -amp; break;
        case GestureId::Shake: yaw = amp; pitch = 0.0f; break;
        case GestureId::TiltL: yaw = amp; pitch = -0.5f * amp; break;
        case GestureId::TiltR: yaw = -amp; pitch = -0.5f * amp; break;
        case GestureId::LookUp: yaw = 0.0f; pitch = amp; break;
        case GestureId::LookDown: yaw = 0.0f; pitch = -amp; break;
    }
}

bool isWindowedSine(GestureId id) {
    return id == GestureId::Nod || id == GestureId::Shake;
}

// 1 軸の波形ピーク（速度・加速度・加加速度）を、周期 cycle 秒・振幅 ampAxis のときの値で返す
void axisPeaks(GestureId id, float ampAxis, float cycle, float& v, float& a, float& j) {
    const float d = std::fabs(ampAxis);
    if (d == 0.0f) {
        v = a = j = 0.0f;
        return;
    }
    if (isWindowedSine(id)) {
        v = d * kWindowedSinePeaks.d1 / cycle;
        a = d * kWindowedSinePeaks.d2 / (cycle * cycle);
        j = d * kWindowedSinePeaks.d3 / (cycle * cycle * cycle);
        return;
    }
    const HoldShape shape = holdShape(id);
    const float tau = shape.move * cycle / GesturePlayer::baseCycleSeconds(id);
    v = d * kSmoothStepPeakV / tau;
    a = d * kSmoothStepPeakA / (tau * tau);
    j = d * kSmoothStepPeakJ / (tau * tau * tau);
}

float stretchFor(const AxisLimits& limits, float v, float a, float j) {
    const float maxVel = limits.maxVel;
    const float maxAcc = 2.0f * maxVel / config::kAccelTime;
    const float maxJerk = 4.0f * maxVel / (config::kAccelTime * config::kAccelTime);
    float s = 1.0f;
    s = std::max(s, v / maxVel);
    s = std::max(s, std::sqrt(a / maxAcc));
    s = std::max(s, std::cbrt(j / maxJerk));
    return s;
}

}  // namespace

WaveformPeaks GesturePlayer::windowedSinePeaks() { return kWindowedSinePeaks; }

float GesturePlayer::baseCycleSeconds(GestureId id) {
    switch (id) {
        case GestureId::Nod:
        case GestureId::Shake:
            return 1.0f;
        case GestureId::TiltL:
        case GestureId::TiltR:
            return 2.3f;
        case GestureId::LookUp:
        case GestureId::LookDown:
            return 4.0f;
    }
    return 1.0f;
}

void GesturePlayer::start(const GestureSpec& spec, const AxisLimits& yaw, const AxisLimits& pitch,
                          float dtSeconds) {
    id_ = spec.id;
    amp_ = spec.ampDeg;
    repeats_ = spec.repeats == 0 ? 1u : std::min<uint32_t>(spec.repeats, 3u);
    const float speed = spec.speedPercent == 0 ? 100.0f : std::min<float>(spec.speedPercent, 100.0f);
    dt_ = dtSeconds;

    const float scaledCycle = baseCycleSeconds(id_) * 100.0f / speed;
    float yawAmp, pitchAmp;
    axisAmplitudes(id_, amp_, yawAmp, pitchAmp);
    float v, a, j;
    axisPeaks(id_, yawAmp, scaledCycle, v, a, j);
    float s = stretchFor(yaw, v, a, j);
    axisPeaks(id_, pitchAmp, scaledCycle, v, a, j);
    s = std::max(s, stretchFor(pitch, v, a, j));
    stretch_ = s;
    cycleSeconds_ = scaledCycle * s;

    count_ = static_cast<uint32_t>(std::lround(totalSeconds() / dt_)) + 1u;
    index_ = 0;
    active_ = true;
}

JointTargets GesturePlayer::evaluate(float phase) const {
    float yawAmp, pitchAmp;
    axisAmplitudes(id_, amp_, yawAmp, pitchAmp);
    const float profile = isWindowedSine(id_) ? windowedSine(phase) : holdProfile(id_, phase);
    return JointTargets{yawAmp * profile, pitchAmp * profile};
}

JointTargets GesturePlayer::step() {
    if (!active_) {
        return JointTargets{0.0f, 0.0f};
    }
    float phase;
    if (index_ + 1 >= count_) {
        phase = 1.0f;  // 最後の標本は必ず終端（静止）
    } else {
        const float t = static_cast<float>(index_) * dt_;
        phase = std::fmod(t, cycleSeconds_) / cycleSeconds_;
    }
    const JointTargets out = evaluate(phase);
    ++index_;
    if (index_ >= count_) {
        active_ = false;
    }
    return out;
}

}  // namespace catneck
