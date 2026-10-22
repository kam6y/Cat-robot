#include "Console.h"

#include <cstdio>

#include "catneck/Config.h"

namespace catneck {

Console::Console(Supervisor& supervisor, SerialTransport& serial, BleHooks& ble)
    : supervisor_(supervisor), serial_(serial), ble_(ble) {}

void Console::setBootInfo(const char* resetReason, bool brownout, bool pwmOff) {
    resetReason_ = resetReason;
    brownout_ = brownout;
    pwmOff_ = pwmOff;
}

void Console::poll(uint32_t nowMillis) {
    char line[SerialTransport::kLineCapacity];
    size_t len = 0;
    while (serial_.readLine(line, sizeof line, len)) {
        if (serial_.takeOverflow()) {
            serial_.println("ERR BAD_ARGS");
            continue;
        }
        handleLine(line, len, nowMillis);
    }
}

void Console::onTick(const Status& status, uint32_t nowMillis) {
    if (!watch_ || nowMillis - lastWatchMillis_ < config::kStatusPeriodMs) return;
    lastWatchMillis_ = nowMillis;
    char out[96];
    formatStatusLine(status, out, sizeof out);
    serial_.println(out);
}

void Console::handleLine(const char* line, size_t len, uint32_t nowMillis) {
    const ParsedLine parsed = parseLine(line, len);
    switch (parsed.kind) {
        case ParsedLine::Kind::Command:
            handleCommand(parsed.command, nowMillis);
            break;
        case ParsedLine::Kind::Action:
            handleAction(parsed);
            break;
        case ParsedLine::Kind::Error: {
            char out[48];
            std::snprintf(out, sizeof out, "ERR %s", parsed.error);
            serial_.println(out);
            break;
        }
    }
}

void Console::handleCommand(const Command& command, uint32_t nowMillis) {
    if (supervisor_.state() == SupervisorState::Boot) {
        serial_.println("ERR BOOT");  // 起動 500 ms は要求を受け付けない（停止要求は記憶される）
        if (command.type == CommandType::Stop || (command.type == CommandType::Torque && !command.torque.on)) {
            supervisor_.onCommand(command, Source::Serial, nowMillis);
        }
        return;
    }
    if (command.type == CommandType::SaveCal) {
        Command filled = command;
        if (filled.saveCal.req == 0) {
            filled.saveCal.req = static_cast<uint8_t>(supervisor_.status().saveSeq % 255 + 1);  // 前回 +1（0 を飛ばす）
        }
        supervisor_.onCommand(filled, Source::Serial, nowMillis);
        if (supervisor_.lastSaveOk()) {
            char out[24];
            std::snprintf(out, sizeof out, "OK seq=%u", static_cast<unsigned>(filled.saveCal.req));
            serial_.println(out);
        } else {
            serial_.println("ERR SAVE");
        }
        return;
    }
    supervisor_.onCommand(command, Source::Serial, nowMillis);
    serial_.println("OK");
}

void Console::handleAction(const ParsedLine& parsed) {
    switch (parsed.action) {
        case ConsoleAction::Status:
            printStatus();
            break;
        case ConsoleAction::WatchOn:
            watch_ = true;
            lastWatchMillis_ = 0;
            serial_.println("OK");
            break;
        case ConsoleAction::WatchOff:
            watch_ = false;
            serial_.println("OK");
            break;
        case ConsoleAction::Info:
            printInfo();
            break;
        case ConsoleAction::Help:
            printHelp();
            break;
        case ConsoleAction::BondsClear:
            ble_.clearBonds();
            serial_.println("OK");
            break;
        case ConsoleAction::PairOpen:
            ble_.openPairWindow();
            serial_.println("OK");
            break;
        case ConsoleAction::Gain:
            switch (supervisor_.setGain(parsed.gainYaw, parsed.gainPitch)) {
                case GainResult::Saved:
                    serial_.println("OK");
                    break;
                case GainResult::Rejected:
                    serial_.println("ERR RANGE");
                    break;
                case GainResult::SaveFailed:
                    serial_.println("ERR SAVE");
                    break;
            }
            break;
        case ConsoleAction::None:
            break;
    }
}

void Console::printStatus() {
    char out[96];
    formatStatusLine(supervisor_.status(), out, sizeof out);
    serial_.println(out);
}

void Console::printInfo() {
    char ble[96];
    ble_.fillInfo(ble, sizeof ble);
    const CalibrationSnapshot cal = supervisor_.calibrationSnapshot();
    char out[256];
    std::snprintf(out, sizeof out,
                  "INFO fw=%u.%u.%u proto=%u hw=E17 %s reset=%s brownout=%d pwm=%s "
                  "cal=%.1f,%.1f inv=%d,%d gain=%.2f,%.2f saved=%d tick_max_us=%lu tick_avg_us=%lu",
                  config::kFwMajor, config::kFwMinor, config::kFwPatch, config::kProtocolVersion, ble, resetReason_,
                  brownout_ ? 1 : 0, pwmOff_ ? "off" : "on", static_cast<double>(cal.yawOffset),
                  static_cast<double>(cal.pitchOffset), cal.yawInvert ? 1 : 0, cal.pitchInvert ? 1 : 0,
                  static_cast<double>(cal.yawGain), static_cast<double>(cal.pitchGain), cal.saved ? 1 : 0,
                  static_cast<unsigned long>(tick_ ? tick_->maxUs : 0),
                  static_cast<unsigned long>(tick_ ? tick_->avgUs() : 0));
    serial_.println(out);
}

void Console::printHelp() {
    static const char* const kLines[] = {
        "MOVE <yaw> <pitch> [speed]      目標角（度）へ S 字で移動。speed は速度上限の %",
        "GESTURE <id|name> <amp> [repeats] [speed]  nod/shake/tilt_l/tilt_r/look_up/look_down",
        "STOP | CENTER [speed] | TORQUE 0|1 | PING [seq]",
        "CAL <yaw_off> <pitch_off> <invert> | SAVE [req] | LIMITS <yaw_v> <pitch_v> <yaw_a> <pitch_a>",
        "GAIN <yaw_us_per_deg> <pitch_us_per_deg>  5.00〜15.00。静止・中立で",
        "HEX <bytes>  生のプロトコルバイト列（BLE と同じ復号器）",
        "STATUS | WATCH ON|OFF | INFO | BONDS CLEAR | PAIR OPEN | HELP",
    };
    for (const char* line : kLines) serial_.println(line);
}

}  // namespace catneck
