#pragma once
#include <array>
namespace servoFake {
struct Pin { bool attached = false; int pulse = 0; int timerStarts = 0; };
inline std::array<Pin, 40> pins{};
inline void reset() { pins = {}; }
}
class ESP32PWM {
public:
    static void allocateTimer(int) {}
};
class Servo {
public:
    void setPeriodHertz(int) {}
    int attach(int pin, int, int) {
        pin_ = pin;
        servoFake::pins[pin].attached = true;
        ++servoFake::pins[pin].timerStarts;
        return 1;
    }
    void detach() {
        servoFake::pins[pin_].attached = false;
        servoFake::pins[pin_].pulse = 0;
    }
    void release() { servoFake::pins[pin_].pulse = 0; }
    void writeMicroseconds(int pulse) { servoFake::pins[pin_].pulse = pulse; }
private:
    int pin_ = -1;
};
