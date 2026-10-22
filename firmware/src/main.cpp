// 入口。アダプタを組み立てて Supervisor に接続する（設計書 §4.2）。単一の loop() で 20 ms の tick を回す。
// 20 ms に 1 tick（停滞時は捨てる）。時刻は入力も tick も同じ millis()。loop タスクは task watchdog に登録する。
#include <Arduino.h>
#include <esp_system.h>

#include "BleHooks.h"
#include "Console.h"
#include "catneck/Config.h"
#include "catneck/Supervisor.h"
#include "platform/BleTransport.h"
#include "platform/NvsStorage.h"
#include "platform/SerialTransport.h"
#include "platform/ServoDriver.h"

using namespace catneck;

namespace {

const char* resetReasonName(esp_reset_reason_t reason) {
    switch (reason) {
        case ESP_RST_POWERON: return "POWERON";
        case ESP_RST_EXT: return "EXT";
        case ESP_RST_SW: return "SW";
        case ESP_RST_PANIC: return "PANIC";
        case ESP_RST_INT_WDT: return "INT_WDT";
        case ESP_RST_TASK_WDT: return "TASK_WDT";
        case ESP_RST_WDT: return "WDT";
        case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
        case ESP_RST_BROWNOUT: return "BROWNOUT";
        case ESP_RST_SDIO: return "SDIO";
        case ESP_RST_USB: return "USB";
        case ESP_RST_JTAG: return "JTAG";
        default: return "UNKNOWN";
    }
}

NvsStorage storage;
SerialTransport serialTransport;
BleTransport ble;
TickStats tickStats;
Supervisor* supervisor = nullptr;
ServoDriver* servoDriver = nullptr;
Console* console = nullptr;
uint32_t lastTickMillis = 0;
Status lastStatus{};

#ifdef CATNECK_NO_PWM
constexpr bool kPwmOff = true;
#else
constexpr bool kPwmOff = false;
#endif

}  // namespace

void setup() {
    const uint32_t bootMillis = millis();
    Serial.begin(115200);
    const esp_reset_reason_t reason = esp_reset_reason();
    const bool brownout = reason == ESP_RST_BROWNOUT;
    storage.begin();
    supervisor = new Supervisor(storage, bootMillis, brownout);
    servoDriver = new ServoDriver();
    ble.begin(*supervisor, bootMillis);
    console = new Console(*supervisor, serialTransport, ble);
    console->setBootInfo(resetReasonName(reason), brownout, kPwmOff);
    console->setTickStats(&tickStats);
    // loop タスクを task watchdog に登録する（sdkconfig: 5 s、満了で panic → リセット）。NimBLE や NVS の
    // 待ちで loop が止まると最後の PWM が出続けるので、リセットして BOOT（500 ms 無出力）からやり直す。
    // Arduino core が loop() の呼び出しごとに esp_task_wdt_reset() を呼ぶ
    enableLoopWDT();
    lastTickMillis = millis();  // setup の所要時間（BLE 初期化など）を tick の溜まりとして数えない
    Serial.printf("CATNECK fw=%u.%u.%u proto=%u hw=E17 reset=%s brownout=%d%s\n", config::kFwMajor, config::kFwMinor,
                  config::kFwPatch, config::kProtocolVersion, resetReasonName(reason), brownout ? 1 : 0,
                  kPwmOff ? " pwm=off" : "");
}

void loop() {
    const uint32_t now = millis();
    console->poll(now);
    ble.poll(now);
    if (now - lastTickMillis >= config::kTickMs) {
        lastTickMillis += config::kTickMs;
        if (now - lastTickMillis >= config::kTickMs) {
            // 停滞（NVS 書き込みなど）で溜まった tick は捨てて位相だけ合わせる。まとめて実行すると複数
            // tick 分の移動が 1 つの PWM 周期（20 ms）に押し込まれて段差になる。軌道は停滞ぶん遅れるだけ
            tickStats.dropped += (now - lastTickMillis) / config::kTickMs;
            lastTickMillis = now - (now - lastTickMillis) % config::kTickMs;
        }
        const uint32_t started = micros();
        // Supervisor には入力（poll）と同じ millis() を渡す。tick の名目時刻（≤ now）を渡すと、同じ
        // iteration で受けた入力の時刻より遅れて経過時間が負になる
        const Outputs outputs = supervisor->tick(now);
        servoDriver->apply(outputs);
        const Status status = supervisor->status();
        console->onTick(status, now);
        ble.setCharacteristicValues(status, supervisor->calibration(), supervisor->limits());
        // seq・フラグ・状態・save_seq が変わったら次の tick で即時通知、それ以外は 200 ms ごと
        const bool changed = status.pingSeq != lastStatus.pingSeq || status.flags != lastStatus.flags ||
                             status.state != lastStatus.state || status.saveSeq != lastStatus.saveSeq;
        lastStatus = status;
        ble.publishStatus(status, changed, now);
        tickStats.add(micros() - started);
    }
    delay(1);
}
