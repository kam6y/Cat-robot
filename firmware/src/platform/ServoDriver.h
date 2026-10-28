// サーボ出力アダプタ（ESP32Servo）。停止中は duty=0 で信号を L にし、タイマーを保持する。
#pragma once

#include <ESP32Servo.h>

#include "catneck/Supervisor.h"

namespace catneck {

class ServoDriver {
public:
    // XIAO ESP32C3: ヨー D1 = GPIO3、ピッチ D3 = GPIO5（設計書 §3.1）
    ServoDriver(int yawPin = 3, int pitchPin = 5);
    void apply(const Outputs& outputs);
    // Whether PWM channels have been allocated; false output still stops all pulses.
    bool attached() const { return attached_; }

private:
    int yawPin_;
    int pitchPin_;
    Servo yaw_;
    Servo pitch_;
    bool attached_ = false;
};

}  // namespace catneck
