// シリアル経路のコンソール（設計書 §4.7）。行を SerialParser で解釈し Supervisor / BLE 層へ流す。
#pragma once

#include <cstddef>
#include <cstdint>

#include "BleHooks.h"
#include "catneck/SerialParser.h"
#include "catneck/Supervisor.h"
#include "platform/SerialTransport.h"

namespace catneck {

// loop の tick 所要時間の統計（Planner の処理時間を実機で見るため。INFO に出す）
struct TickStats {
    uint32_t maxUs = 0;
    uint64_t sumUs = 0;
    uint32_t count = 0;
    uint32_t dropped = 0;  // 停滞で捨てた tick の数（main.cpp）
    void add(uint32_t us) {
        if (us > maxUs) maxUs = us;
        sumUs += us;
        ++count;
    }
    uint32_t avgUs() const { return count == 0 ? 0 : static_cast<uint32_t>(sumUs / count); }
};

class Console {
public:
    Console(Supervisor& supervisor, SerialTransport& serial, BleHooks& ble);
    void setBootInfo(const char* resetReason, bool brownout, bool pwmOff);
    void setTickStats(const TickStats* stats) { tick_ = stats; }
    void poll(uint32_t nowMillis);
    void onTick(const Status& status, uint32_t nowMillis);

private:
    void handleLine(const char* line, size_t len, uint32_t nowMillis);
    void handleCommand(const Command& command, uint32_t nowMillis);
    void handleAction(const ParsedLine& parsed, uint32_t nowMillis);
    void printStatus();
    void printInfo();
    void printHelp();

    Supervisor& supervisor_;
    SerialTransport& serial_;
    BleHooks& ble_;
    const TickStats* tick_ = nullptr;
    const char* resetReason_ = "?";
    bool brownout_ = false;
    bool pwmOff_ = false;
    bool watch_ = false;
    uint32_t lastWatchMillis_ = 0;
};

}  // namespace catneck
