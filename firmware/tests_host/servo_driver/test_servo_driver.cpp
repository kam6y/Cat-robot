#include <iostream>
#include <stdexcept>
#include "platform/ServoDriver.h"

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

int main() {
    try {
        servoFake::reset();
        catneck::ServoDriver driver;
        driver.apply({false, 1572.0f, 1500.0f});
        require(servoFake::pins[3].timerStarts == 0 && servoFake::pins[5].timerStarts == 0,
                "Boot with PWM disabled must not allocate or emit servo pulses");
        driver.apply({true, 1572.0f, 1500.0f});
#ifdef CATNECK_NO_PWM
        require(servoFake::pins[3].timerStarts == 0 && servoFake::pins[5].timerStarts == 0,
                "Bring-up firmware must never attach servo outputs");
#else
        require(servoFake::pins[3].pulse == 1572 && servoFake::pins[5].pulse == 1500,
                "First output must use calibrated pulse widths");
        for (int cycle = 0; cycle < 3; ++cycle) {
            driver.apply({false, 1572.0f, 1500.0f});
            driver.apply({false, 1572.0f, 1500.0f});
            require(servoFake::pins[3].pulse == 0 && servoFake::pins[5].pulse == 0,
                    "Disabled output must have zero duty on both axes");
            driver.apply({true, 1572.0f, 1500.0f});
            require(servoFake::pins[3].timerStarts == 1 && servoFake::pins[5].timerStarts == 1,
                    "Resuming PWM must preserve channel/timer continuity");
            require(servoFake::pins[3].pulse == 1572 && servoFake::pins[5].pulse == 1500,
                    "Resume must use the current calibrated pulses");
        }
        driver.apply({true, 1600.0f, 1450.0f});
        require(servoFake::pins[3].pulse == 1600 && servoFake::pins[5].pulse == 1450,
                "Enabled output must follow each planner sample");
#endif
        std::cout << "ServoDriver output checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
