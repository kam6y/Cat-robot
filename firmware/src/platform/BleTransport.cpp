#include "platform/BleTransport.h"

#include <Arduino.h>

#include <cstdio>
#include <cstring>

#include "catneck/Config.h"
#include "catneck/Protocol.h"

namespace catneck {
namespace {

constexpr const char* kServiceUuid = "C47B0000-6D1F-4B9E-9C9A-2A3B4C5D6E7F";
constexpr const char* kCommandUuid = "C47B0001-6D1F-4B9E-9C9A-2A3B4C5D6E7F";
constexpr const char* kStatusUuid = "C47B0002-6D1F-4B9E-9C9A-2A3B4C5D6E7F";
constexpr const char* kCalibrationUuid = "C47B0003-6D1F-4B9E-9C9A-2A3B4C5D6E7F";
constexpr const char* kLimitsUuid = "C47B0004-6D1F-4B9E-9C9A-2A3B4C5D6E7F";
constexpr const char* kInfoUuid = "C47B0005-6D1F-4B9E-9C9A-2A3B4C5D6E7F";

BleTransport* g_transport = nullptr;

class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer*, NimBLEConnInfo& connInfo) override {
        if (g_transport) g_transport->onPeerConnected(connInfo);
    }
    void onDisconnect(NimBLEServer*, NimBLEConnInfo& connInfo, int) override {
        if (g_transport) g_transport->onPeerDisconnected(connInfo);
    }
    void onAuthenticationComplete(NimBLEConnInfo& connInfo) override {
        if (g_transport) g_transport->onPeerAuthenticated(connInfo);
    }
};

class WriteCallbacks : public NimBLECharacteristicCallbacks {
public:
    explicit WriteCallbacks(BleTransport::BleEvent::Kind kind) : kind_(kind) {}
    void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo&) override {
        const NimBLEAttValue& value = characteristic->getValue();
        if (g_transport) g_transport->pushEvent(kind_, value.data(), value.size());
    }

private:
    BleTransport::BleEvent::Kind kind_;
};

ServerCallbacks g_serverCallbacks;
WriteCallbacks g_commandCallbacks(BleTransport::BleEvent::Kind::CommandWrite);
WriteCallbacks g_calibrationCallbacks(BleTransport::BleEvent::Kind::CalibrationWrite);
WriteCallbacks g_limitsCallbacks(BleTransport::BleEvent::Kind::LimitsWrite);

}  // namespace

void BleTransport::begin(Supervisor& supervisor, uint32_t nowMillis) {
    supervisor_ = &supervisor;
    g_transport = this;
    windowOpen_ = true;  // 電源投入後 60 秒は新規ペアリングを受け付ける
    windowStartMillis_ = nowMillis;

    NimBLEDevice::init("CatRobot");
    const NimBLEAddress address = NimBLEDevice::getAddress();
    const uint8_t* val = address.getVal();  // LSB が先頭
    std::snprintf(name_, sizeof name_, "CatRobot-%02X%02X", val[1], val[0]);
    std::snprintf(address_, sizeof address_, "%s", address.toString().c_str());
    NimBLEDevice::setDeviceName(name_);
    NimBLEDevice::setSecurityAuth(true, false, true);  // bond あり、MITM なし、Secure Connections あり
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);

    server_ = NimBLEDevice::createServer();
    server_->setCallbacks(&g_serverCallbacks);
    server_->advertiseOnDisconnect(true);

    NimBLEService* service = server_->createService(kServiceUuid);
    commandChar_ = service->createCharacteristic(kCommandUuid, NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC);
    commandChar_->setCallbacks(&g_commandCallbacks);
    statusChar_ = service->createCharacteristic(kStatusUuid,
                                                NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC | NIMBLE_PROPERTY::NOTIFY);
    calibrationChar_ = service->createCharacteristic(
        kCalibrationUuid,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::READ_ENC | NIMBLE_PROPERTY::WRITE_ENC);
    calibrationChar_->setCallbacks(&g_calibrationCallbacks);
    limitsChar_ = service->createCharacteristic(
        kLimitsUuid, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::READ_ENC | NIMBLE_PROPERTY::WRITE_ENC);
    limitsChar_->setCallbacks(&g_limitsCallbacks);
    infoChar_ = service->createCharacteristic(kInfoUuid, NIMBLE_PROPERTY::READ);

    InfoData info{};
    info.protocol = config::kProtocolVersion;
    info.major = config::kFwMajor;
    info.minor = config::kFwMinor;
    info.patch = config::kFwPatch;
    info.hwId = config::kHwId;
    info.caps = 0;
    uint8_t infoBytes[kInfoSize];
    encodeInfo(info, infoBytes);
    infoChar_->setValue(infoBytes, sizeof infoBytes);
    uint8_t zeros[kStatusSize] = {};
    statusChar_->setValue(zeros, kStatusSize);
    calibrationChar_->setValue(zeros, kCalibrationSize);
    limitsChar_->setValue(zeros, kLimitsSize);
    service->start();

    NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
    advertising->setName(name_);
    advertising->addServiceUUID(service->getUUID());
    advertising->enableScanResponse(true);
    advertising->start();
}

bool BleTransport::pairOpen(uint32_t nowMillis) const {
    if (NimBLEDevice::getNumBonds() == 0) return true;
    return windowOpen_ && (nowMillis - windowStartMillis_) < kPairWindowMs;
}

void BleTransport::pushEvent(BleEvent::Kind kind, const uint8_t* data, size_t len) {
    BleEvent event{};
    event.kind = kind;
    event.len = static_cast<uint8_t>(len > sizeof event.data ? sizeof event.data + 1 : len);  // 21 = 長すぎ（復号で拒否）
    if (data != nullptr && len > 0) std::memcpy(event.data, data, len > sizeof event.data ? sizeof event.data : len);
    portENTER_CRITICAL(&mux_);
    const size_t next = (head_ + 1) % kQueueSize;
    if (next == tail_) {
        tail_ = (tail_ + 1) % kQueueSize;  // あふれは最古を捨てて数える
        ++dropped_;
    }
    queue_[head_] = event;
    head_ = next;
    portEXIT_CRITICAL(&mux_);
}

bool BleTransport::popEvent(BleEvent& out) {
    portENTER_CRITICAL(&mux_);
    if (tail_ == head_) {
        portEXIT_CRITICAL(&mux_);
        return false;
    }
    out = queue_[tail_];
    tail_ = (tail_ + 1) % kQueueSize;
    portEXIT_CRITICAL(&mux_);
    return true;
}

void BleTransport::onPeerConnected(NimBLEConnInfo& connInfo) {
    const uint16_t handle = connInfo.getConnHandle();
    if (acceptedHandle_ != 0xFFFF) {
        server_->disconnect(handle);  // central は 1 台だけ
        return;
    }
    // 窓が閉じているときは、ボンド済みでない central を接続直後に切る（設計書 §4.6、R2）
    const bool known = NimBLEDevice::isBonded(connInfo.getIdAddress()) || NimBLEDevice::isBonded(connInfo.getAddress());
    if (!known && !pairOpen(millis())) {
        server_->disconnect(handle);
        return;
    }
    knownAtConnect_ = known;
    acceptedHandle_ = handle;
    server_->updateConnParams(handle, 12, 24, 0, 400);  // 15〜30 ms、監視 4 s
    pushEvent(BleEvent::Kind::LinkUp, nullptr, 0);
}

void BleTransport::onPeerDisconnected(NimBLEConnInfo& connInfo) {
    if (connInfo.getConnHandle() == acceptedHandle_) {
        acceptedHandle_ = 0xFFFF;
        pushEvent(BleEvent::Kind::LinkDown, nullptr, 0);
        NimBLEDevice::startAdvertising();
    } else if (acceptedHandle_ == 0xFFFF) {
        NimBLEDevice::startAdvertising();  // 拒否した相手の切断。受け入れ中の相手がいなければ再開
    }
}

void BleTransport::onPeerAuthenticated(NimBLEConnInfo& connInfo) {
    if (connInfo.getConnHandle() != acceptedHandle_) return;
    if (!connInfo.isEncrypted()) {
        server_->disconnect(connInfo.getConnHandle());  // ペアリング失敗
        return;
    }
    if (!knownAtConnect_ && !pairOpen(millis())) {
        // 接続中に窓が閉じた場合: 新しいボンドは残さず切る
        NimBLEDevice::deleteBond(connInfo.getIdAddress());
        server_->disconnect(connInfo.getConnHandle());
    }
}

void BleTransport::handleEvent(const BleEvent& event, uint32_t nowMillis) {
    switch (event.kind) {
        case BleEvent::Kind::CommandWrite: {
            const DecodeResult result = decodeCommand(event.data, event.len);
            if (result.ok) {
                supervisor_->onCommand(result.command, Source::Ble, nowMillis);
            } else {
                supervisor_->onRejected();
            }
            break;
        }
        case BleEvent::Kind::CalibrationWrite: {
            Command command{};
            command.type = CommandType::SetCal;
            if (decodeCalibrationWrite(event.data, event.len, command.setCal)) {
                supervisor_->onCommand(command, Source::Ble, nowMillis);
            } else {
                supervisor_->onRejected();
            }
            break;
        }
        case BleEvent::Kind::LimitsWrite: {
            Command command{};
            command.type = CommandType::SetLimits;
            if (decodeLimitsWrite(event.data, event.len, command.setLimits)) {
                supervisor_->onCommand(command, Source::Ble, nowMillis);
            } else {
                supervisor_->onRejected();
            }
            break;
        }
        case BleEvent::Kind::LinkUp:
            supervisor_->onLink(true, nowMillis);
            break;
        case BleEvent::Kind::LinkDown:
            supervisor_->onLink(false, nowMillis);
            break;
    }
}

void BleTransport::poll(uint32_t nowMillis) {
    BleEvent event;
    while (popEvent(event)) handleEvent(event, nowMillis);
    if (windowOpen_ && (nowMillis - windowStartMillis_) >= kPairWindowMs) windowOpen_ = false;  // 期限で閉じる
    supervisor_->setPairOpen(pairOpen(nowMillis));
}

void BleTransport::setCharacteristicValues(const Status& status, const CalibrationData& cal, const LimitsData& limits) {
    uint8_t statusBytes[kStatusSize];
    encodeStatus(status, statusBytes);
    statusChar_->setValue(statusBytes, sizeof statusBytes);
    uint8_t calBytes[kCalibrationSize];
    encodeCalibration(cal, calBytes);
    calibrationChar_->setValue(calBytes, sizeof calBytes);
    uint8_t limitBytes[kLimitsSize];
    encodeLimits(limits, limitBytes);
    limitsChar_->setValue(limitBytes, sizeof limitBytes);
}

void BleTransport::publishStatus(const Status& status, bool changed, uint32_t nowMillis) {
    if (acceptedHandle_ == 0xFFFF) return;
    if (!changed && nowMillis - lastNotifyMillis_ < config::kStatusPeriodMs) return;
    lastNotifyMillis_ = nowMillis;
    encodeStatus(status, lastStatus_);
    // Read は READ_ENC で守られるが Notify は NimBLE が暗号化の有無を見ずに送る（実機で確認: 未ペアの
    // central に届いた）。暗号化済みの接続にだけ送り、Read と同じ条件にそろえる
    if (!server_->getPeerInfoByHandle(acceptedHandle_).isEncrypted()) return;
    statusChar_->notify(lastStatus_, sizeof lastStatus_);
}

void BleTransport::clearBonds() {
    // deleteAllBonds() は OUR_SEC の数だけ消す。途中で止まったペアリングは PEER_SEC（相手の LTK）だけを
    // 残し、ATT が「Insufficient Encryption」を返して macOS が二度とペアリングしない状態になる（実機で
    // 確認）。store 全体（our/peer sec・CCCD・IRK）を消す
    NimBLEDevice::deleteAllBonds();
    ble_store_clear();
}

void BleTransport::openPairWindow() {
    windowOpen_ = true;
    windowStartMillis_ = millis();
}

void BleTransport::fillInfo(char* out, size_t cap) {
    std::snprintf(out, cap, "addr=%s name=%s bonds=%d pair_open=%d dropped=%lu", address_, name_,
                  NimBLEDevice::getNumBonds(), pairOpen(millis()) ? 1 : 0, static_cast<unsigned long>(dropped_));
}

}  // namespace catneck
