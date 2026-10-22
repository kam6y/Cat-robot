#include <unity.h>

#include <cmath>
#include <vector>

#include "catneck/Axis.h"
#include "catneck/Gesture.h"

using namespace catneck;

void setUp() {}
void tearDown() {}

namespace {

constexpr float kDt = 0.02f;
const AxisLimits kHuge{60.0f, 100000.0f};

struct Trace {
    std::vector<float> yaw;
    std::vector<float> pitch;
};

Trace play(GesturePlayer& player) {
    Trace trace;
    while (player.active()) {
        JointTargets t = player.step();
        trace.yaw.push_back(t.yaw);
        trace.pitch.push_back(t.pitch);
    }
    return trace;
}

GestureSpec spec(GestureId id, float amp, uint8_t repeats = 1, uint8_t speed = 100) {
    return GestureSpec{id, amp, repeats, speed};
}

// 数値微分の最大絶対値（v, a, j）
void peaks(const std::vector<float>& x, float& v, float& a, float& j) {
    v = a = j = 0.0f;
    std::vector<float> vel, acc;
    for (size_t i = 1; i < x.size(); ++i) vel.push_back((x[i] - x[i - 1]) / kDt);
    for (size_t i = 1; i < vel.size(); ++i) acc.push_back((vel[i] - vel[i - 1]) / kDt);
    for (float s : vel) v = std::max(v, std::fabs(s));
    for (float s : acc) a = std::max(a, std::fabs(s));
    for (size_t i = 1; i < acc.size(); ++i) j = std::max(j, std::fabs((acc[i] - acc[i - 1]) / kDt));
}

}  // namespace

void test_base_cycles() {
    TEST_ASSERT_EQUAL_FLOAT(1.0f, GesturePlayer::baseCycleSeconds(GestureId::Nod));
    TEST_ASSERT_EQUAL_FLOAT(1.0f, GesturePlayer::baseCycleSeconds(GestureId::Shake));
    TEST_ASSERT_EQUAL_FLOAT(2.3f, GesturePlayer::baseCycleSeconds(GestureId::TiltL));
    TEST_ASSERT_EQUAL_FLOAT(2.3f, GesturePlayer::baseCycleSeconds(GestureId::TiltR));
    TEST_ASSERT_EQUAL_FLOAT(4.0f, GesturePlayer::baseCycleSeconds(GestureId::LookUp));
    TEST_ASSERT_EQUAL_FLOAT(4.0f, GesturePlayer::baseCycleSeconds(GestureId::LookDown));
}

void test_nod_waveform_shape() {
    GesturePlayer player;
    player.start(spec(GestureId::Nod, 15.0f), kHuge, kHuge, kDt);
    TEST_ASSERT_EQUAL_FLOAT(1.0f, player.stretch());
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 1.0f, player.totalSeconds());
    Trace trace = play(player);
    TEST_ASSERT_EQUAL(51, trace.pitch.size());  // 0〜1.0 s を 20 ms 刻み（両端含む）
    size_t argMin = 0, argMax = 0;
    for (size_t i = 0; i < trace.pitch.size(); ++i) {
        if (trace.pitch[i] < trace.pitch[argMin]) argMin = i;
        if (trace.pitch[i] > trace.pitch[argMax]) argMax = i;
        TEST_ASSERT_EQUAL_FLOAT(0.0f, trace.yaw[i]);
    }
    TEST_ASSERT_TRUE(argMin < argMax);
    TEST_ASSERT_FLOAT_WITHIN(0.15f, -15.0f, trace.pitch[argMin]);
    TEST_ASSERT_FLOAT_WITHIN(0.15f, 15.0f, trace.pitch[argMax]);
    TEST_ASSERT_FLOAT_WITHIN(0.1f, 0.0f, trace.pitch.back());
    TEST_ASSERT_EQUAL_FLOAT(0.0f, trace.pitch.front());
}

void test_shake_waveform_positive_first() {
    GesturePlayer player;
    player.start(spec(GestureId::Shake, 25.0f), kHuge, kHuge, kDt);
    Trace trace = play(player);
    size_t argMin = 0, argMax = 0;
    for (size_t i = 0; i < trace.yaw.size(); ++i) {
        if (trace.yaw[i] < trace.yaw[argMin]) argMin = i;
        if (trace.yaw[i] > trace.yaw[argMax]) argMax = i;
        TEST_ASSERT_EQUAL_FLOAT(0.0f, trace.pitch[i]);
    }
    TEST_ASSERT_TRUE(argMax < argMin);
    TEST_ASSERT_FLOAT_WITHIN(0.25f, 25.0f, trace.yaw[argMax]);
    TEST_ASSERT_FLOAT_WITHIN(0.25f, -25.0f, trace.yaw[argMin]);
}

void test_waveform_starts_and_ends_at_rest() {
    const GestureId ids[] = {GestureId::Nod, GestureId::Shake, GestureId::TiltL,
                             GestureId::TiltR, GestureId::LookUp, GestureId::LookDown};
    for (GestureId id : ids) {
        GesturePlayer player;
        player.start(spec(id, 15.0f), kHuge, kHuge, kDt);
        Trace trace = play(player);
        const size_t n = trace.pitch.size();
        TEST_ASSERT_TRUE(n > 10);
        for (const std::vector<float>* axis : {&trace.yaw, &trace.pitch}) {
            const std::vector<float>& x = *axis;
            TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.0f, x[0]);
            TEST_ASSERT_FLOAT_WITHIN(0.05f, 0.0f, x[1]);
            TEST_ASSERT_FLOAT_WITHIN(0.25f, 0.0f, x[2]);
            TEST_ASSERT_FLOAT_WITHIN(0.25f, 0.0f, x[n - 3]);
            TEST_ASSERT_FLOAT_WITHIN(0.05f, 0.0f, x[n - 2]);
            TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.0f, x[n - 1]);
        }
    }
}

void test_stretch_when_limits_exceeded() {
    GesturePlayer player;
    const AxisLimits pitchSlow{30.0f, 50.0f};
    player.start(spec(GestureId::Nod, 15.0f), kHuge, pitchSlow, kDt);
    TEST_ASSERT_TRUE(player.stretch() > 1.0f);
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 1.0f * player.stretch(), player.totalSeconds());
    Trace trace = play(player);
    float v, a, j;
    peaks(trace.pitch, v, a, j);
    TEST_ASSERT_TRUE_MESSAGE(v <= 50.0f * 1.02f, "velocity over limit");
    TEST_ASSERT_TRUE_MESSAGE(a <= 500.0f * 1.05f, "acceleration over limit");
    TEST_ASSERT_TRUE_MESSAGE(j <= 5000.0f * 1.1f, "jerk over limit");
    float minP = 0.0f;
    for (float p : trace.pitch) minP = std::min(minP, p);
    TEST_ASSERT_FLOAT_WITHIN(0.2f, -15.0f, minP);  // 振幅は保つ
}

void test_repeats_and_speed() {
    GesturePlayer player;
    player.start(spec(GestureId::Nod, 15.0f, 2, 50), kHuge, kHuge, kDt);
    TEST_ASSERT_EQUAL_FLOAT(1.0f, player.stretch());
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 4.0f, player.totalSeconds());
    Trace trace = play(player);
    TEST_ASSERT_EQUAL(201, trace.pitch.size());
    int minima = 0;
    for (size_t i = 1; i + 1 < trace.pitch.size(); ++i) {
        if (trace.pitch[i] < -14.0f && trace.pitch[i] <= trace.pitch[i - 1] && trace.pitch[i] < trace.pitch[i + 1]) ++minima;
    }
    TEST_ASSERT_EQUAL(2, minima);

    GesturePlayer normalized;
    normalized.start(spec(GestureId::Shake, 10.0f, 0, 0), kHuge, kHuge, kDt);  // repeats 0 → 1, speed 0 → 100
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 1.0f, normalized.totalSeconds());
    GesturePlayer clamped;
    clamped.start(spec(GestureId::Shake, 10.0f, 9, 250), kHuge, kHuge, kDt);  // repeats 9 → 3, speed 250 → 100
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 3.0f, clamped.totalSeconds());
}

void test_tilt_uses_both_axes() {
    GesturePlayer player;
    player.start(spec(GestureId::TiltR, 12.0f), kHuge, kHuge, kDt);
    Trace trace = play(player);
    const size_t hold = static_cast<size_t>(std::lround(1.15f / kDt));  // 保持区間の真ん中
    TEST_ASSERT_FLOAT_WITHIN(0.01f, -12.0f, trace.yaw[hold]);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, -6.0f, trace.pitch[hold]);

    GesturePlayer left;
    left.start(spec(GestureId::TiltL, 12.0f), kHuge, kHuge, kDt);
    Trace lt = play(left);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 12.0f, lt.yaw[hold]);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, -6.0f, lt.pitch[hold]);

    GesturePlayer up;
    up.start(spec(GestureId::LookUp, 20.0f), kHuge, kHuge, kDt);
    Trace ut = play(up);
    const size_t lookHold = static_cast<size_t>(std::lround(2.0f / kDt));
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 20.0f, ut.pitch[lookHold]);
    TEST_ASSERT_EQUAL_FLOAT(0.0f, ut.yaw[lookHold]);
    GesturePlayer down;
    down.start(spec(GestureId::LookDown, 20.0f), kHuge, kHuge, kDt);
    Trace dt = play(down);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, -20.0f, dt.pitch[lookHold]);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_base_cycles);
    RUN_TEST(test_nod_waveform_shape);
    RUN_TEST(test_shake_waveform_positive_first);
    RUN_TEST(test_waveform_starts_and_ends_at_rest);
    RUN_TEST(test_stretch_when_limits_exceeded);
    RUN_TEST(test_repeats_and_speed);
    RUN_TEST(test_tilt_uses_both_axes);
    return UNITY_END();
}
