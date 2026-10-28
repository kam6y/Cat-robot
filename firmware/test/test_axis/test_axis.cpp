#include <unity.h>

#include <cmath>
#include <limits>

#include "catneck/Axis.h"

using catneck::Axis;
using catneck::kPitchAbs;
using catneck::kYawAbs;

void setUp() {}
void tearDown() {}

void test_clamp_joint_saturates_at_abs_and_configured() {
    Axis yaw(kYawAbs, 120.0f);
    bool saturated = false;
    TEST_ASSERT_EQUAL_FLOAT(60.0f, yaw.clampJoint(70.0f, &saturated));
    TEST_ASSERT_TRUE(saturated);
    saturated = true;
    TEST_ASSERT_EQUAL_FLOAT(-60.0f, yaw.clampJoint(-61.0f, &saturated));
    TEST_ASSERT_TRUE(saturated);
    saturated = true;
    TEST_ASSERT_EQUAL_FLOAT(12.5f, yaw.clampJoint(12.5f, &saturated));
    TEST_ASSERT_FALSE(saturated);
    TEST_ASSERT_TRUE(yaw.setLimits(45.0f, 0.0f, &saturated));
    saturated = false;
    TEST_ASSERT_EQUAL_FLOAT(45.0f, yaw.clampJoint(50.0f, &saturated));
    TEST_ASSERT_TRUE(saturated);
    TEST_ASSERT_EQUAL_FLOAT(45.0f, yaw.limits().maxAngle);
    TEST_ASSERT_EQUAL_FLOAT(120.0f, yaw.limits().maxVel);
}

void test_joint_to_servo_applies_offset_then_invert() {
    Axis pitch(kPitchAbs, 100.0f);
    bool saturated = true;
    TEST_ASSERT_TRUE(pitch.setCalibration(2.5f, true, &saturated));
    TEST_ASSERT_FALSE(saturated);
    TEST_ASSERT_EQUAL_FLOAT(-12.5f, pitch.jointToServo(10.0f));
    TEST_ASSERT_EQUAL_FLOAT(10.0f, pitch.servoToJoint(pitch.jointToServo(10.0f)));
    TEST_ASSERT_TRUE(pitch.setCalibration(-1.0f, false, &saturated));
    TEST_ASSERT_EQUAL_FLOAT(9.0f, pitch.jointToServo(10.0f));
    TEST_ASSERT_EQUAL_FLOAT(10.0f, pitch.servoToJoint(9.0f));
}

void test_pulse_mapping_and_saturation() {
    Axis yaw(kYawAbs, 120.0f);
    TEST_ASSERT_TRUE(yaw.setGain(11.11f));
    TEST_ASSERT_EQUAL_FLOAT(1500.0f, yaw.servoToPulseUs(0.0f));
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 2499.9f, yaw.servoToPulseUs(90.0f));
    TEST_ASSERT_EQUAL_FLOAT(2500.0f, yaw.servoToPulseUs(100.0f));
    TEST_ASSERT_EQUAL_FLOAT(500.0f, yaw.servoToPulseUs(-100.0f));
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 1611.1f, yaw.servoToPulseUs(10.0f));
}

void test_set_limits_rules() {
    Axis yaw(kYawAbs, 120.0f);
    bool saturated = true;
    TEST_ASSERT_TRUE(yaw.setLimits(0.0f, 0.0f, &saturated));
    TEST_ASSERT_FALSE(saturated);
    TEST_ASSERT_EQUAL_FLOAT(60.0f, yaw.limits().maxAngle);
    TEST_ASSERT_EQUAL_FLOAT(120.0f, yaw.limits().maxVel);

    TEST_ASSERT_TRUE(yaw.setLimits(200.0f, 999.0f, &saturated));
    TEST_ASSERT_TRUE(saturated);
    TEST_ASSERT_EQUAL_FLOAT(60.0f, yaw.limits().maxAngle);
    TEST_ASSERT_EQUAL_FLOAT(180.0f, yaw.limits().maxVel);

    saturated = false;
    TEST_ASSERT_TRUE(yaw.setLimits(3.0f, 2.0f, &saturated));
    TEST_ASSERT_TRUE(saturated);
    TEST_ASSERT_EQUAL_FLOAT(5.0f, yaw.limits().maxAngle);
    TEST_ASSERT_EQUAL_FLOAT(5.0f, yaw.limits().maxVel);

    saturated = false;
    TEST_ASSERT_TRUE(yaw.setLimits(40.0f, 60.0f, &saturated));
    TEST_ASSERT_FALSE(saturated);
    TEST_ASSERT_EQUAL_FLOAT(40.0f, yaw.limits().maxAngle);
    TEST_ASSERT_EQUAL_FLOAT(60.0f, yaw.limits().maxVel);

    TEST_ASSERT_FALSE(yaw.setLimits(-1.0f, 50.0f, &saturated));
    TEST_ASSERT_EQUAL_FLOAT(40.0f, yaw.limits().maxAngle);
    TEST_ASSERT_EQUAL_FLOAT(60.0f, yaw.limits().maxVel);
}

void test_set_calibration_and_gain_ranges() {
    Axis pitch(kPitchAbs, 100.0f);
    bool saturated = false;
    TEST_ASSERT_TRUE(pitch.setCalibration(25.0f, false, &saturated));
    TEST_ASSERT_TRUE(saturated);
    TEST_ASSERT_EQUAL_FLOAT(20.0f, pitch.calibration().offset);
    TEST_ASSERT_TRUE(pitch.setCalibration(-25.0f, true, &saturated));
    TEST_ASSERT_EQUAL_FLOAT(-20.0f, pitch.calibration().offset);
    TEST_ASSERT_TRUE(pitch.calibration().invert);

    TEST_ASSERT_EQUAL_FLOAT(11.11f, pitch.calibration().gain);
    TEST_ASSERT_FALSE(pitch.setGain(4.99f));
    TEST_ASSERT_FALSE(pitch.setGain(15.01f));
    TEST_ASSERT_FALSE(pitch.setGain(std::numeric_limits<float>::quiet_NaN()));
    TEST_ASSERT_FALSE(pitch.setGain(std::numeric_limits<float>::infinity()));
    TEST_ASSERT_EQUAL_FLOAT(11.11f, pitch.calibration().gain);
    TEST_ASSERT_TRUE(pitch.setGain(7.41f));
    TEST_ASSERT_EQUAL_FLOAT(7.41f, pitch.calibration().gain);
    TEST_ASSERT_EQUAL_FLOAT(30.0f, pitch.absolute().maxAngle);
    TEST_ASSERT_EQUAL_FLOAT(120.0f, pitch.absolute().maxVel);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_clamp_joint_saturates_at_abs_and_configured);
    RUN_TEST(test_joint_to_servo_applies_offset_then_invert);
    RUN_TEST(test_pulse_mapping_and_saturation);
    RUN_TEST(test_set_limits_rules);
    RUN_TEST(test_set_calibration_and_gain_ranges);
    return UNITY_END();
}
