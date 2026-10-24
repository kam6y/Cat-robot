#!/usr/bin/env python3
"""Exercise the real ServoDriver against a recording PWM boundary on the host."""
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    firmware = Path(__file__).resolve().parents[1]
    tests = firmware / "tests_host/servo_driver"
    with tempfile.TemporaryDirectory(prefix="cat-servo-driver-") as directory:
        for no_pwm in (False, True):
            binary = Path(directory) / ("bringup" if no_pwm else "normal")
            command = [os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror",
                       "-I" + str(tests / "fakes"), "-I" + str(firmware / "src"),
                       "-I" + str(firmware / "lib/catneck/src"),
                       str(firmware / "src/platform/ServoDriver.cpp"),
                       str(tests / "test_servo_driver.cpp"), "-o", str(binary)]
            if no_pwm:
                command.append("-DCATNECK_NO_PWM")
            subprocess.run(command, check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
