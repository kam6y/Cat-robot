#include "platform/ServoDriver.h"

#include <Arduino.h>

#include <cmath>

#include "catneck/Config.h"

namespace catneck {

ServoDriver::ServoDriver(int yawPin, int pitchPin) : yawPin_(yawPin), pitchPin_(pitchPin) {
    pinMode(yawPin_, INPUT);
    pinMode(pitchPin_, INPUT);
#ifndef CATNECK_NO_PWM
    ESP32PWM::allocateTimer(0);
    ESP32PWM::allocateTimer(1);
    yaw_.setPeriodHertz(50);
    pitch_.setPeriodHertz(50);
#endif
}

void ServoDriver::apply(const Outputs& outputs) {
#ifdef CATNECK_NO_PWM
    (void)outputs;  // bring-up ビルド: サーボ出力なし（attach もしない）
#else
    if (!outputs.pwmEnabled) {
        if (attached_) {
            // Zero duty stops pulses without reallocating LEDC channels/timers on resume.
            yaw_.release();
            pitch_.release();
        }
        return;
    }
    if (!attached_) {
        yaw_.attach(yawPin_, static_cast<int>(config::kMinPulseUs), static_cast<int>(config::kMaxPulseUs));
        pitch_.attach(pitchPin_, static_cast<int>(config::kMinPulseUs), static_cast<int>(config::kMaxPulseUs));
        attached_ = true;
    }
    yaw_.writeMicroseconds(static_cast<int>(std::lround(outputs.yawPulseUs)));
    pitch_.writeMicroseconds(static_cast<int>(std::lround(outputs.pitchPulseUs)));
#endif
}

}  // namespace catneck
