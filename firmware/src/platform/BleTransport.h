// BLE GATT サーバ（NimBLE）。設計書 §4.6。コールバックはイベントをキューに積むだけで、コアには loop から触る。
#pragma once

#include <NimBLEDevice.h>

#include <cstddef>
#include <cstdint>

#include "BleHooks.h"
#include "catneck/Supervisor.h"

namespace catneck {

class BleTransport : public BleHooks {
public:
    struct BleEvent {
        enum class Kind : uint8_t { CommandWrite, CalibrationWrite, LimitsWrite, LinkUp, LinkDown };
        Kind kind;
        uint8_t len;
        uint8_t data[20];
    };

    void begin(Supervisor& supervisor, uint32_t nowMillis);
    // キューを取り出してコアへ流し、ペアリング窓の状態を Supervisor に反映する
    void poll(uint32_t nowMillis);
    // Read 用のスナップショットを特性へコピーする（コールバックからコアを読まないため）
    void setCharacteristicValues(const Status& status, const CalibrationData& cal, const LimitsData& limits);
    // 200 ms ごと、または changed なら即時に Status を Notify する
    void publishStatus(const Status& status, bool changed, uint32_t nowMillis);
    const char* name() const { return name_; }
    bool pairOpen(uint32_t nowMillis) const;
    uint32_t droppedEvents() const { return dropped_; }

    // BleHooks
    void clearBonds() override;
    void openPairWindow() override;
    void fillInfo(char* out, size_t cap) override;

    // NimBLE のタスクから呼ばれる（コールバック用。外からは使わない）
    void pushEvent(BleEvent::Kind kind, const uint8_t* data, size_t len);
    void onPeerConnected(NimBLEConnInfo& connInfo);
    void onPeerDisconnected();
    void onPeerAuthenticated(NimBLEConnInfo& connInfo);

private:
    static constexpr size_t kQueueSize = 16;
    static constexpr uint32_t kPairWindowMs = 60000;

    bool popEvent(BleEvent& out);
    void handleEvent(const BleEvent& event, uint32_t nowMillis);

    Supervisor* supervisor_ = nullptr;
    NimBLEServer* server_ = nullptr;
    NimBLECharacteristic* commandChar_ = nullptr;
    NimBLECharacteristic* statusChar_ = nullptr;
    NimBLECharacteristic* calibrationChar_ = nullptr;
    NimBLECharacteristic* limitsChar_ = nullptr;
    NimBLECharacteristic* infoChar_ = nullptr;
    char name_[16] = "CatRobot-????";
    char address_[18] = "";

    BleEvent queue_[kQueueSize];
    volatile size_t head_ = 0;
    volatile size_t tail_ = 0;
    volatile uint32_t dropped_ = 0;
    portMUX_TYPE mux_ = portMUX_INITIALIZER_UNLOCKED;

    uint32_t windowUntilMillis_ = 0;
    volatile bool connected_ = false;
    uint32_t lastNotifyMillis_ = 0;
    uint8_t lastStatus_[kStatusSize] = {};
};

}  // namespace catneck
