#include <unity.h>

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "catneck/Planner.h"

using catneck::Planner;
using catneck::PlannerState;

namespace {
constexpr float kDt = 0.02f;

// State derivatives and output-position differences both expose discontinuities.
struct Trace {
    PlannerState previous;
    float previousVelocity = 0.0f;
    float previousAcceleration = 0.0f;
    int samples = 0;

    explicit Trace(const Planner& planner) : previous(planner.state()) {}

    void check(const PlannerState& next, float velocity, float acceleration,
               float jerk) {
        TEST_ASSERT_TRUE(std::isfinite(next.pos));
        TEST_ASSERT_TRUE(std::fabs(next.vel) <= velocity + 0.5f);
        TEST_ASSERT_TRUE(std::fabs(next.acc) <= acceleration + 5.0f);
        TEST_ASSERT_TRUE(std::fabs(next.vel - previous.vel) / kDt <= acceleration + 5.0f);
        TEST_ASSERT_TRUE(std::fabs(next.acc - previous.acc) / kDt <= jerk * 1.05f);
        const float measuredVelocity = (next.pos - previous.pos) / kDt;
        const float measuredAcceleration = (measuredVelocity - previousVelocity) / kDt;
        TEST_ASSERT_TRUE(std::fabs(measuredVelocity) <= velocity + 0.5f);
        if (samples >= 1) {
            TEST_ASSERT_TRUE(std::fabs(measuredAcceleration) <= acceleration + 5.0f);
        }
        if (samples >= 2) {
            TEST_ASSERT_TRUE(std::fabs(measuredAcceleration - previousAcceleration) / kDt
                             <= jerk * 1.05f + 1.0f);
        }
        previous = next;
        previousVelocity = measuredVelocity;
        previousAcceleration = measuredAcceleration;
        ++samples;
    }
};

void assertInvariant(const PlannerState& state, float velocity, float jerk) {
    const float positive = std::max(0.0f, state.acc);
    const float negative = std::max(0.0f, -state.acc);
    TEST_ASSERT_TRUE(state.vel + positive * positive / (2.0f * jerk) <= velocity + 0.01f);
    TEST_ASSERT_TRUE(state.vel - negative * negative / (2.0f * jerk) >= -velocity - 0.01f);
}

float nextTarget(uint32_t& random) {
    random = random * 1664525u + 1013904223u;
    return static_cast<float>((random >> 8) % 60001u) / 1000.0f - 30.0f;
}

void checkLowering(bool negative, bool peakAcceleration) {
    Planner planner;
    planner.setMaxVel(100.0f);
    planner.setTarget(negative ? -1000.0f : 1000.0f);
    Trace trace(planner);
    bool reached = false;
    for (int i = 0; i < 30; ++i) {
        const auto& state = planner.step();
        trace.check(state, 100.0f, 1000.0f, 10000.0f);
        if (peakAcceleration ? std::fabs(state.acc) >= 990.0f
                             : std::fabs(state.vel) >= 99.99f && std::fabs(state.acc) < 0.01f) {
            reached = true;
            break;
        }
    }
    TEST_ASSERT_TRUE(reached);
    planner.setMaxVel(5.0f);
    // 0.395 seconds rounds up to tick 20 (400 ms).
    for (int i = 1; i <= 60; ++i) {
        const auto& state = planner.step();
        trace.check(state, 100.0f, 1000.0f, 10000.0f);
        assertInvariant(state, 100.0f, 10000.0f);
        if (i >= 20) {
            TEST_ASSERT_TRUE(std::fabs(state.vel) <= 5.5f);
            TEST_ASSERT_TRUE(std::fabs(state.acc) <= 55.0f);
            assertInvariant(state, 5.0f, 500.0f);
        }
    }
    TEST_ASSERT_EQUAL_FLOAT(5.0f, planner.maxVel());
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 50.0f, planner.maxAcc());
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 500.0f, planner.maxJerk());
}
}  // namespace

void setUp() {}
void tearDown() {}

void test_rest_to_max_vel_takes_0_2_to_0_3_s() {
    Planner planner;
    planner.setMaxVel(100.0f);
    planner.setTarget(1000.0f);
    int ticks = 0;
    while (ticks < 20 && planner.state().vel < 99.0f) {
        planner.step();
        ++ticks;
    }
    TEST_ASSERT_TRUE(ticks >= 10 && ticks <= 15);
}

void test_bounds_hold_every_tick() {
    Planner planner;
    planner.setMaxVel(100.0f);
    planner.setTarget(25.0f);
    Trace trace(planner);
    for (int i = 0; i < 100; ++i) {
        trace.check(planner.step(), 100.0f, 1000.0f, 10000.0f);
    }
    TEST_ASSERT_TRUE(planner.atTarget());
}

void test_no_overshoot_and_arrival() {
    Planner planner;
    planner.reset(30.0f);
    planner.setMaxVel(100.0f);
    planner.setTarget(0.0f);
    for (int i = 0; i < 50; ++i) {
        TEST_ASSERT_TRUE(planner.step().pos >= 0.0f);
    }
    TEST_ASSERT_TRUE(planner.atTarget());
}

void test_landing_is_exact_rest() {
    for (float target : {0.001f, -0.07f, 0.1f, 1.23f, -29.97f}) {
        Planner planner;
        planner.setMaxVel(100.0f);
        planner.setTarget(target);
        Trace trace(planner);
        for (int i = 0; i < 100 && !planner.atTarget(); ++i) {
            trace.check(planner.step(), 100.0f, 1000.0f, 10000.0f);
        }
        TEST_ASSERT_TRUE(planner.atTarget());
        TEST_ASSERT_EQUAL_FLOAT(target, planner.state().pos);
        TEST_ASSERT_EQUAL_FLOAT(0.0f, planner.state().vel);
        TEST_ASSERT_EQUAL_FLOAT(0.0f, planner.state().acc);
        for (int i = 0; i < 50; ++i) {
            const auto& state = planner.step();
            TEST_ASSERT_EQUAL_FLOAT(target, state.pos);
            TEST_ASSERT_EQUAL_FLOAT(0.0f, state.vel);
            TEST_ASSERT_EQUAL_FLOAT(0.0f, state.acc);
        }
    }
}

void test_60deg_within_1s_at_default_yaw_vel() {
    Planner planner;
    planner.setMaxVel(120.0f);
    planner.setTarget(60.0f);
    for (int i = 0; i < 50; ++i) planner.step();
    TEST_ASSERT_TRUE(planner.atTarget());
    TEST_ASSERT_EQUAL_FLOAT(60.0f, planner.state().pos);
}

void test_retarget_keeps_continuity() {
    Planner planner;
    planner.setMaxVel(100.0f);
    planner.setTarget(25.0f);
    Trace trace(planner);
    for (int i = 0; i < 8; ++i) trace.check(planner.step(), 100.0f, 1000.0f, 10000.0f);
    const PlannerState before = planner.state();
    planner.setTarget(-30.0f);
    TEST_ASSERT_EQUAL_FLOAT(before.pos, planner.state().pos);
    TEST_ASSERT_EQUAL_FLOAT(before.vel, planner.state().vel);
    TEST_ASSERT_EQUAL_FLOAT(before.acc, planner.state().acc);
    for (int i = 0; i < 100; ++i) trace.check(planner.step(), 100.0f, 1000.0f, 10000.0f);
    TEST_ASSERT_TRUE(planner.atTarget());
}

void test_random_retargets_stay_within_limits() {
    Planner planner;
    planner.setMaxVel(100.0f);
    Trace trace(planner);
    uint32_t random = 0x12345678u;
    for (int i = 0; i < 1000; ++i) {
        planner.setTarget(nextTarget(random));
        trace.check(planner.step(), 100.0f, 1000.0f, 10000.0f);
        TEST_ASSERT_TRUE(std::fabs(planner.state().pos) <= 30.05f);
        TEST_ASSERT_TRUE(std::fabs(planner.brakingPoint()) <= 30.05f);
    }
    planner.setTarget(17.0f);
    for (int i = 0; i < 100; ++i) trace.check(planner.step(), 100.0f, 1000.0f, 10000.0f);
    TEST_ASSERT_TRUE(planner.atTarget());
}

void test_braking_point_never_grows_on_retarget() {
    for (float sign : {-1.0f, 1.0f}) {
        Planner planner;
        planner.setMaxVel(100.0f);
        planner.setTarget(sign * 30.0f);
        for (int i = 0; i < 8; ++i) planner.step();
        const float braking = sign * planner.brakingPoint();
        planner.setTarget(-sign * 30.0f);
        TEST_ASSERT_FLOAT_WITHIN(0.001f, braking, sign * planner.brakingPoint());
        // While still moving away, maximum braking cannot extend the stop point.
        for (int i = 0; i < 30 && sign * planner.state().vel > 0.0f; ++i) {
            planner.step();
            if (sign * planner.state().vel > 0.0f) {
                TEST_ASSERT_TRUE(sign * planner.brakingPoint() <= braking + 0.01f);
            }
        }
    }
}

void test_lowering_max_vel_decelerates_within_transition() { checkLowering(false, false); }
void test_lowering_max_vel_at_peak_accel_keeps_old_bound() { checkLowering(false, true); }
void test_lowering_max_vel_at_peak_accel_negative_direction() { checkLowering(true, true); }

void test_velocity_invariant_both_signs_every_tick() {
    Planner planner;
    planner.setMaxVel(100.0f);
    uint32_t random = 0xabcdef01u;
    for (int i = 0; i < 2000; ++i) {
        if (i % 7 == 0) planner.setTarget(nextTarget(random));
        assertInvariant(planner.step(), 100.0f, 10000.0f);
    }
}

void test_random_retargets_respect_absolute_limit_not_configured() {
    Planner planner;
    planner.setMaxVel(100.0f);
    planner.reset(30.0f);
    uint32_t random = 0x1u;
    for (int i = 0; i < 1000; ++i) {
        planner.setTarget(nextTarget(random));
        TEST_ASSERT_TRUE(std::fabs(planner.step().pos) <= 30.05f);
    }
    // Soft-limit shrink changes the target, not the current position.
    planner.reset(30.0f);
    planner.setTarget(5.0f);
    TEST_ASSERT_EQUAL_FLOAT(30.0f, planner.state().pos);
    for (int i = 0; i < 100; ++i) {
        TEST_ASSERT_TRUE(std::fabs(planner.step().pos) <= 30.05f);
    }
    TEST_ASSERT_TRUE(planner.atTarget());
}

void test_rescale_keeps_output_pulse() {
    Planner planner;
    planner.reset(30.0f);
    planner.rescale(7.41f / 11.11f);
    TEST_ASSERT_FLOAT_WITHIN(0.0001f, 30.0f, planner.state().pos * (11.11f / 7.41f));
    TEST_ASSERT_EQUAL_FLOAT(planner.state().pos, planner.target());
    TEST_ASSERT_TRUE(planner.atTarget());
    TEST_ASSERT_EQUAL_FLOAT(0.0f, planner.state().vel);
    TEST_ASSERT_EQUAL_FLOAT(0.0f, planner.state().acc);
}

// 静止からの短い移動は閉形式の三角形加速（A^2/J = V なので上限未満では加速度が A に届かない）:
// V=100, D=4° → v = cbrt(J D^2/4) ≈ 34.2°/s、所要 4 sqrt(v/J) ≈ 0.234 s
void test_short_move_from_rest_follows_triangular_profile() {
    Planner planner(kDt);
    planner.setMaxVel(100.0f);
    planner.reset(0.0f);
    planner.setTarget(4.0f);
    const double jerk = planner.maxJerk();
    const double cruise = std::cbrt(jerk * 4.0 * 4.0 / 4.0);
    const double seconds = 4.0 * std::sqrt(cruise / jerk);
    float peak = 0.0f;
    int ticks = 0;
    while (!planner.atTarget() && ticks < 100) {
        peak = std::max(peak, planner.step().vel);
        ++ticks;
    }
    TEST_ASSERT_TRUE(planner.atTarget());
    TEST_ASSERT_FLOAT_WITHIN(1.0f, static_cast<float>(cruise), peak);
    TEST_ASSERT_TRUE(ticks * kDt >= seconds - kDt);
    TEST_ASSERT_TRUE(ticks * kDt <= seconds + 2 * kDt);
    TEST_ASSERT_FLOAT_WITHIN(1e-6f, 4.0f, planner.state().pos);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_rest_to_max_vel_takes_0_2_to_0_3_s);
    RUN_TEST(test_bounds_hold_every_tick);
    RUN_TEST(test_no_overshoot_and_arrival);
    RUN_TEST(test_landing_is_exact_rest);
    RUN_TEST(test_60deg_within_1s_at_default_yaw_vel);
    RUN_TEST(test_retarget_keeps_continuity);
    RUN_TEST(test_random_retargets_stay_within_limits);
    RUN_TEST(test_braking_point_never_grows_on_retarget);
    RUN_TEST(test_lowering_max_vel_decelerates_within_transition);
    RUN_TEST(test_lowering_max_vel_at_peak_accel_keeps_old_bound);
    RUN_TEST(test_lowering_max_vel_at_peak_accel_negative_direction);
    RUN_TEST(test_velocity_invariant_both_signs_every_tick);
    RUN_TEST(test_random_retargets_respect_absolute_limit_not_configured);
    RUN_TEST(test_rescale_keeps_output_pulse);
    RUN_TEST(test_short_move_from_rest_follows_triangular_profile);
    return UNITY_END();
}
