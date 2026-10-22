#include "catneck/Axis.h"

#include <algorithm>
#include <cmath>

namespace catneck {

namespace {

float clampAbs(float value, float limit, bool* saturated) {
    if (value > limit) {
        *saturated = true;
        return limit;
    }
    if (value < -limit) {
        *saturated = true;
        return -limit;
    }
    return value;
}

}  // namespace

Axis::Axis(AxisAbsolute abs, float defaultVel)
    : abs_(abs),
      limits_{abs.maxAngle, defaultVel},
      cal_{0.0f, false, config::kDefaultGain} {}

float Axis::clampJoint(float jointDeg, bool* saturated) const {
    *saturated = false;
    return clampAbs(jointDeg, limits_.maxAngle, saturated);
}

float Axis::jointToServo(float jointDeg) const {
    const float withOffset = jointDeg + cal_.offset;
    return cal_.invert ? -withOffset : withOffset;
}

float Axis::servoToJoint(float servoDeg) const {
    const float withOffset = cal_.invert ? -servoDeg : servoDeg;
    return withOffset - cal_.offset;
}

float Axis::servoToPulseUs(float servoDeg) const {
    const float pulse = config::kNeutralPulseUs + servoDeg * cal_.gain;
    return std::min(config::kMaxPulseUs, std::max(config::kMinPulseUs, pulse));
}

bool Axis::setLimits(float maxAngleOrZero, float maxVelOrZero, bool* saturated) {
    *saturated = false;
    if (maxAngleOrZero < 0.0f) {
        return false;
    }
    if (maxAngleOrZero != 0.0f) {
        float angle = maxAngleOrZero;
        if (angle > abs_.maxAngle) {
            angle = abs_.maxAngle;
            *saturated = true;
        } else if (angle < config::kMinAngleLimit) {
            angle = config::kMinAngleLimit;
            *saturated = true;
        }
        limits_.maxAngle = angle;
    }
    if (maxVelOrZero != 0.0f) {
        float vel = maxVelOrZero;
        if (vel > abs_.maxVel) {
            vel = abs_.maxVel;
            *saturated = true;
        } else if (vel < config::kMinVel) {
            vel = config::kMinVel;
            *saturated = true;
        }
        limits_.maxVel = vel;
    }
    return true;
}

bool Axis::setCalibration(float offsetDeg, bool invert, bool* saturated) {
    *saturated = false;
    cal_.offset = clampAbs(offsetDeg, config::kMaxOffset, saturated);
    cal_.invert = invert;
    return true;
}

bool Axis::setGain(float gainUsPerDeg) {
    if (!std::isfinite(gainUsPerDeg)) {
        return false;
    }
    if (gainUsPerDeg < config::kMinGain || gainUsPerDeg > config::kMaxGain) {
        return false;
    }
    cal_.gain = gainUsPerDeg;
    return true;
}

}  // namespace catneck
