// Console から BLE 層へ渡す保守操作（設計書 §4.7 の BONDS CLEAR / PAIR OPEN / INFO）。実装は BleTransport（Task 9）。
#pragma once

#include <cstddef>

namespace catneck {

struct BleHooks {
    virtual ~BleHooks() = default;
    virtual void clearBonds() = 0;
    virtual void openPairWindow() = 0;
    // "addr=<aa:bb:…> name=CatRobot-XXXX bonds=<n> pair_open=<0|1>" を out に書く
    virtual void fillInfo(char* out, size_t cap) = 0;
};

}  // namespace catneck
