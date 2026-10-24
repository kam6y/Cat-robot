// 定型動作の波形生成（設計書 §4.4）。位相 0〜1 で定義した波形を tick ごとのジョイント目標に展開する。
#pragma once

#include <cstdint>

#include "catneck/Axis.h"
#include "catneck/Protocol.h"

namespace catneck {

struct GestureSpec {
    GestureId id;
    float ampDeg;          // 0.1° 単位の amp を度に直した値
    uint8_t repeats;       // 0 → 1、4 以上 → 3
    uint8_t speedPercent;  // 0 → 100、101 以上 → 100。時間を 100/speed 倍に伸ばす
    bool anchored = false;
    float yawCenter = 0.0f;
    float pitchCenter = 0.0f;
};

struct JointTargets {
    float yaw;
    float pitch;
};

// 軸ごとの符号つき振幅。保持型は到達角、正弦型は波形に掛ける係数。
JointTargets gestureAmplitudes(GestureId id, float ampDeg);

// 窓つき正弦（正規化後）の位相 x に関する 1〜3 階導関数の絶対値の最大
struct WaveformPeaks {
    float d1;
    float d2;
    float d3;
};

class GesturePlayer {
public:
    // 再生を始める。速度・加速度・加加速度の上限（Planner と同じ式）を超える波形は時間を伸ばす。
    void start(const GestureSpec& spec, const AxisLimits& yaw, const AxisLimits& pitch,
               float dtSeconds = config::kTickSeconds);
    bool active() const { return index_ < count_; }
    // 現在 tick のジョイント目標を返して 1 tick 進める。最後の標本（t = 総時間）を返した後 active() は false。
    JointTargets step();
    float totalSeconds() const { return cycleSeconds_ * repeats_; }
    float stretch() const { return stretch_; }
    static float baseCycleSeconds(GestureId id);
    static WaveformPeaks windowedSinePeaks();

private:
    JointTargets evaluate(float phase) const;

    GestureId id_ = GestureId::Nod;
    float amp_ = 0.0f;
    uint32_t repeats_ = 1;
    float cycleSeconds_ = 1.0f;
    float stretch_ = 1.0f;
    float dt_ = config::kTickSeconds;
    uint32_t index_ = 0;
    uint32_t count_ = 0;
};

}  // namespace catneck
