#include <unity.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "catneck/Config.h"
#include "catneck/Supervisor.h"

using namespace catneck;

void setUp() {}
void tearDown() {}

namespace {

constexpr float kGain = config::kDefaultGain;
constexpr float kDt = config::kTickSeconds;

struct FakeStorage : Storage {
    bool failSave = false;
    bool corrupt = false;
    bool hasBlob = false;
    CalBlob blob{};
    int saveCount = 0;

    bool save(const CalBlob& b) override {
        ++saveCount;
        if (failSave) return false;
        blob = b;
        hasBlob = true;
        return true;
    }
    bool load(CalBlob& out) override {
        if (corrupt) {
            out = CalBlob{};
            out.version = kCalBlobVersion;
            out.yawOffDeci = 77;
            out.yawGainCenti = 1111;
            out.pitchGainCenti = 1111;
            out.crc16 = 0xBEEF;
            return true;
        }
        if (!hasBlob) return false;
        out = blob;
        return true;
    }
};

struct Sim {
    FakeStorage storage;
    uint32_t now;
    Supervisor sup;
    Outputs out{};

    explicit Sim(bool brownout = false, uint32_t boot = 0) : now(boot), sup(storage, boot, brownout) {}
    Sim(FakeStorage& shared, uint32_t boot) : now(boot), sup(shared, boot, false) {}

    // 20 ms ごとに tick を呼んで ms だけ進める
    void advance(uint32_t ms) {
        for (uint32_t t = 0; t < ms; t += config::kTickMs) {
            now += config::kTickMs;
            out = sup.tick(now);
        }
    }
    void send(const Command& c) { sup.onCommand(c, Source::Ble, now); }
    Status st() const { return sup.status(); }
    bool flag(uint16_t bit) const { return (sup.status().flags & bit) != 0; }
    float yawJoint() const { return (out.yawPulseUs - config::kNeutralPulseUs) / kGain; }
    float pitchJoint() const { return (out.pitchPulseUs - config::kNeutralPulseUs) / kGain; }
    // 起動 → IDLE まで進める
    void bootToIdle() {
        advance(config::kBootIdleMs);
        TEST_ASSERT_EQUAL(static_cast<int>(SupervisorState::Idle), static_cast<int>(sup.state()));
    }
    // 静止（MOVING=0）まで最大 maxMs 進める
    bool settle(uint32_t maxMs = 5000) {
        for (uint32_t t = 0; t < maxMs; t += config::kTickMs) {
            advance(config::kTickMs);
            if (!flag(StatusFlags::Moving) && !flag(StatusFlags::Gesture)) return true;
        }
        return false;
    }
};

Command moveCmd(float yaw, float pitch, uint8_t speed = 100) {
    Command c{};
    c.type = CommandType::Move;
    c.move.yawDeci = static_cast<int16_t>(std::lround(yaw * 10.0f));
    c.move.pitchDeci = static_cast<int16_t>(std::lround(pitch * 10.0f));
    c.move.speed = speed;
    return c;
}
Command gestureCmd(GestureId id, float amp, uint8_t repeats = 1, uint8_t speed = 100) {
    Command c{};
    c.type = CommandType::Gesture;
    c.gesture.id = id;
    c.gesture.ampDeci = static_cast<uint8_t>(std::lround(amp * 10.0f));
    c.gesture.repeats = repeats;
    c.gesture.speed = speed;
    return c;
}
Command stopCmd() {
    Command c{};
    c.type = CommandType::Stop;
    return c;
}
Command centerCmd(uint8_t speed = 0) {
    Command c{};
    c.type = CommandType::Center;
    c.center.speed = speed;
    return c;
}
Command torqueCmd(bool on) {
    Command c{};
    c.type = CommandType::Torque;
    c.torque.on = on;
    return c;
}
Command setCalCmd(int16_t yawDeci, int16_t pitchDeci, uint8_t invert) {
    Command c{};
    c.type = CommandType::SetCal;
    c.setCal.yawOffDeci = yawDeci;
    c.setCal.pitchOffDeci = pitchDeci;
    c.setCal.invert = invert;
    return c;
}
Command saveCalCmd(uint8_t req) {
    Command c{};
    c.type = CommandType::SaveCal;
    c.saveCal.req = req;
    return c;
}
Command setLimitsCmd(uint16_t yv, uint16_t pv, int16_t ya, int16_t pa) {
    Command c{};
    c.type = CommandType::SetLimits;
    c.setLimits.yawVelDeci = yv;
    c.setLimits.pitchVelDeci = pv;
    c.setLimits.yawAngDeci = ya;
    c.setLimits.pitchAngDeci = pa;
    return c;
}
Command pingCmd(uint8_t seq) {
    Command c{};
    c.type = CommandType::Ping;
    c.ping.seq = seq;
    return c;
}

void assertState(const Sim& sim, SupervisorState s) {
    TEST_ASSERT_EQUAL(static_cast<int>(s), static_cast<int>(sim.sup.state()));
}

// 位置列から速度・加速度・加加速度の上限を検査する（Planner テストと同じ許容）
struct Kinematics {
    float velMax = 0, accMax = 0, jerkMax = 0, posMin = 1e9f, posMax = -1e9f;
    std::vector<float> pos;
    void push(float p) {
        pos.push_back(p);
        posMin = std::fmin(posMin, p);
        posMax = std::fmax(posMax, p);
        size_t n = pos.size();
        if (n >= 2) velMax = std::fmax(velMax, std::fabs(pos[n - 1] - pos[n - 2]) / kDt);
        if (n >= 3) accMax = std::fmax(accMax, std::fabs(pos[n - 1] - 2 * pos[n - 2] + pos[n - 3]) / (kDt * kDt));
        if (n >= 4)
            jerkMax = std::fmax(jerkMax, std::fabs(pos[n - 1] - 3 * pos[n - 2] + 3 * pos[n - 3] - pos[n - 4]) / (kDt * kDt * kDt));
    }
};

}  // namespace

void test_boot_mute_then_center_then_idle() {
    Sim sim;
    sim.advance(480);
    TEST_ASSERT_FALSE(sim.out.pwmEnabled);
    assertState(sim, SupervisorState::Boot);
    sim.advance(20);  // 500 ms
    TEST_ASSERT_TRUE(sim.out.pwmEnabled);
    assertState(sim, SupervisorState::BootCenter);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 1500.0f, sim.out.yawPulseUs);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 1500.0f, sim.out.pitchPulseUs);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::Torque));
    sim.advance(980);  // 1480 ms
    assertState(sim, SupervisorState::BootCenter);
    sim.advance(20);  // 1500 ms
    assertState(sim, SupervisorState::Idle);
    TEST_ASSERT_FALSE(sim.out.pwmEnabled);
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::Torque));
}

void test_boot_discards_requests_but_remembers_stop() {
    {
        Sim sim;
        sim.advance(100);
        sim.send(moveCmd(20, -5));
        sim.send(pingCmd(3));
        TEST_ASSERT_EQUAL_UINT8(0, sim.st().rejectedCount);
        TEST_ASSERT_FALSE(sim.flag(StatusFlags::Rejected));
        sim.advance(400);  // 500 ms
        assertState(sim, SupervisorState::BootCenter);
        sim.advance(1000);  // 1500 ms
        assertState(sim, SupervisorState::Idle);
        TEST_ASSERT_EQUAL_UINT8(0, sim.st().pingSeq);
    }
    {
        Sim sim;
        sim.advance(100);
        sim.send(stopCmd());
        sim.advance(400);  // 500 ms
        assertState(sim, SupervisorState::Idle);
        TEST_ASSERT_FALSE(sim.out.pwmEnabled);
        sim.advance(1000);
        assertState(sim, SupervisorState::Idle);
    }
}

void test_move_from_idle_activates_and_moves() {
    Sim sim;
    sim.bootToIdle();
    sim.send(moveCmd(20, -5, 100));
    assertState(sim, SupervisorState::Active);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::Moving));
    for (int i = 1; i <= 3; ++i) {
        sim.advance(20);
        TEST_ASSERT_TRUE(sim.out.pwmEnabled);
        TEST_ASSERT_TRUE(sim.out.yawPulseUs > 1500.0f);
        TEST_ASSERT_FLOAT_WITHIN(0.001f, 1500.0f, sim.out.pitchPulseUs);  // ピッチは 3 tick 待つ
    }
    sim.advance(20);  // 4 tick 目
    TEST_ASSERT_TRUE(sim.out.pitchPulseUs < 1500.0f);
    TEST_ASSERT_TRUE(sim.settle());
    TEST_ASSERT_EQUAL_INT16(200, sim.st().yawDeci);
    TEST_ASSERT_EQUAL_INT16(-50, sim.st().pitchDeci);
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::Saturated));
    assertState(sim, SupervisorState::Active);
    sim.send(centerCmd(50));
    TEST_ASSERT_TRUE(sim.settle());
    TEST_ASSERT_EQUAL_INT16(0, sim.st().yawDeci);
    TEST_ASSERT_EQUAL_INT16(0, sim.st().pitchDeci);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 1500.0f, sim.out.yawPulseUs);
}

void test_silence_3s_returns_then_relaxes() {
    {
        Sim sim;
        sim.bootToIdle();
        sim.send(moveCmd(20, -5));
        sim.settle();
        sim.advance(2980 - (sim.now - 1500));
        assertState(sim, SupervisorState::Active);
        sim.advance(20);  // 3000 ms 無通信
        assertState(sim, SupervisorState::Returning);
        TEST_ASSERT_TRUE(sim.flag(StatusFlags::Returning));
        uint32_t returnStart = sim.now;
        bool relaxed = false;
        for (int i = 0; i < 100; ++i) {
            sim.advance(20);
            if (sim.sup.state() == SupervisorState::RelaxWait) {
                relaxed = true;
                break;
            }
        }
        TEST_ASSERT_TRUE(relaxed);
        TEST_ASSERT_TRUE(sim.now - returnStart <= config::kReturnDeadlineMs);
        TEST_ASSERT_EQUAL_INT16(0, sim.st().yawDeci);
        TEST_ASSERT_EQUAL_INT16(0, sim.st().pitchDeci);
        TEST_ASSERT_TRUE(sim.flag(StatusFlags::Returning));
        uint32_t relaxStart = sim.now;
        sim.advance(1980);
        assertState(sim, SupervisorState::RelaxWait);
        TEST_ASSERT_TRUE(sim.out.pwmEnabled);
        sim.advance(20);
        TEST_ASSERT_EQUAL_UINT32(2000, sim.now - relaxStart);
        assertState(sim, SupervisorState::Idle);
        TEST_ASSERT_FALSE(sim.out.pwmEnabled);
        TEST_ASSERT_FALSE(sim.flag(StatusFlags::Returning));
    }
    {
        Sim sim;
        sim.bootToIdle();
        sim.send(moveCmd(20, -5));
        for (int s = 0; s < 10; ++s) {
            sim.advance(1000);
            sim.send(pingCmd(static_cast<uint8_t>(s + 1)));
            assertState(sim, SupervisorState::Active);
        }
    }
}

void test_disconnect_during_gesture_returns_immediately() {
    Sim sim;
    sim.bootToIdle();
    sim.sup.onLink(true, sim.now);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::Link));
    sim.send(gestureCmd(GestureId::Nod, 15));
    sim.advance(200);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::Gesture));
    sim.sup.onLink(false, sim.now);
    assertState(sim, SupervisorState::Returning);
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::Gesture));
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::Link));
}

void test_ping_after_reconnect_does_not_resume() {
    Sim sim;
    sim.bootToIdle();
    sim.sup.onLink(true, sim.now);
    sim.send(moveCmd(30, 10));
    sim.advance(100);
    sim.sup.onLink(false, sim.now);
    assertState(sim, SupervisorState::Returning);
    sim.advance(100);
    sim.sup.onLink(true, sim.now);
    sim.send(pingCmd(9));
    assertState(sim, SupervisorState::Returning);
    bool idle = false;
    for (int i = 0; i < 300; ++i) {
        sim.advance(20);
        TEST_ASSERT_TRUE(sim.sup.state() != SupervisorState::Active);
        if (sim.sup.state() == SupervisorState::Idle) {
            idle = true;
            break;
        }
    }
    TEST_ASSERT_TRUE(idle);
    TEST_ASSERT_EQUAL_UINT8(9, sim.st().pingSeq);
}

void test_return_deadline_2s() {
    Sim sim;
    sim.bootToIdle();
    sim.send(setLimitsCmd(50, 50, 0, 0));  // 5°/s
    sim.send(moveCmd(60, -30));
    sim.advance(3000);
    assertState(sim, SupervisorState::Returning);  // 無通信 3 s（まだ移動中）
    sim.advance(config::kReturnDeadlineMs);
    assertState(sim, SupervisorState::RelaxWait);
}

void test_stop_is_highest_priority() {
    Sim sim;
    sim.bootToIdle();
    sim.send(moveCmd(40, 20));
    sim.advance(100);
    sim.sup.onLink(false, sim.now);
    assertState(sim, SupervisorState::Returning);
    sim.send(stopCmd());
    assertState(sim, SupervisorState::Idle);
    sim.advance(20);
    TEST_ASSERT_FALSE(sim.out.pwmEnabled);
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::Moving));
}

void test_rejected_input_does_not_feed_watchdog() {
    Sim sim;
    sim.bootToIdle();
    sim.send(moveCmd(10, 0));
    for (int i = 0; i < 31; ++i) {
        sim.advance(100);
        sim.sup.onRejected();
    }
    assertState(sim, SupervisorState::Returning);
    TEST_ASSERT_EQUAL_UINT8(31, sim.st().rejectedCount);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::Rejected));
}

void test_gesture_queue_rules() {
    {
        Sim sim;
        sim.bootToIdle();
        sim.send(gestureCmd(GestureId::Nod, 10));
        sim.advance(100);
        sim.send(moveCmd(20, 0));
        TEST_ASSERT_TRUE(sim.flag(StatusFlags::Gesture));
        bool yawMovedDuringGesture = false;
        while (sim.flag(StatusFlags::Gesture)) {
            sim.advance(20);
            // 完了した tick で保留 MOVE が適用されるので、GESTURE=1 のあいだだけ見る
            if (sim.flag(StatusFlags::Gesture) && std::fabs(sim.out.yawPulseUs - 1500.0f) > 0.01f) {
                yawMovedDuringGesture = true;
            }
            sim.send(pingCmd(1));
        }
        TEST_ASSERT_FALSE(yawMovedDuringGesture);
        TEST_ASSERT_TRUE(sim.settle());
        TEST_ASSERT_EQUAL_INT16(200, sim.st().yawDeci);
    }
    {
        Sim sim;
        sim.bootToIdle();
        sim.send(gestureCmd(GestureId::Nod, 10));
        sim.advance(100);
        sim.send(gestureCmd(GestureId::Shake, 10));
        sim.send(gestureCmd(GestureId::LookUp, 10));  // 保留は新しい方だけ残る
        int16_t pitchMax = 0;
        bool yawMoved = false;
        for (int i = 0; i < 400 && sim.flag(StatusFlags::Gesture); ++i) {
            sim.advance(20);
            if (sim.now % 1000 == 0) sim.send(pingCmd(2));
            if (sim.now - 1500 > 1500 && sim.st().pitchDeci > pitchMax) pitchMax = sim.st().pitchDeci;
            if (std::fabs(sim.out.yawPulseUs - 1500.0f) > 0.01f) yawMoved = true;
        }
        TEST_ASSERT_FALSE(sim.flag(StatusFlags::Gesture));
        TEST_ASSERT_FALSE(yawMoved);
        TEST_ASSERT_TRUE(pitchMax >= 90);  // look_up が再生された
    }
}

void test_maintenance_requests_do_not_cancel_return() {
    Sim sim;
    sim.bootToIdle();
    sim.send(moveCmd(40, 20));
    sim.advance(100);
    sim.sup.onLink(false, sim.now);
    assertState(sim, SupervisorState::Returning);
    sim.send(saveCalCmd(1));
    sim.send(setLimitsCmd(0, 0, 0, 0));
    sim.send(pingCmd(1));
    assertState(sim, SupervisorState::Returning);
    bool relaxed = false;
    for (int i = 0; i < 150 && !relaxed; ++i) {
        sim.advance(20);
        relaxed = sim.sup.state() == SupervisorState::RelaxWait;
    }
    TEST_ASSERT_TRUE(relaxed);
    sim.send(saveCalCmd(2));
    sim.send(setLimitsCmd(0, 0, 0, 0));
    sim.send(pingCmd(2));
    assertState(sim, SupervisorState::RelaxWait);
    sim.advance(2000);
    assertState(sim, SupervisorState::Idle);
    TEST_ASSERT_EQUAL_UINT8(2, sim.st().saveSeq);
}

void test_torque_off_discards_playing_and_pending() {
    Sim sim;
    sim.bootToIdle();
    sim.send(gestureCmd(GestureId::Nod, 10));
    sim.advance(100);
    sim.send(gestureCmd(GestureId::Shake, 10));
    sim.send(moveCmd(20, 0));
    sim.send(torqueCmd(false));
    assertState(sim, SupervisorState::Idle);
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::Gesture));
    sim.advance(20);
    TEST_ASSERT_FALSE(sim.out.pwmEnabled);
    for (int i = 0; i < 10; ++i) {
        sim.send(pingCmd(1));
        sim.advance(200);
        assertState(sim, SupervisorState::Idle);
        TEST_ASSERT_FALSE(sim.flag(StatusFlags::Moving));
        TEST_ASSERT_FALSE(sim.flag(StatusFlags::Gesture));
    }
}

void test_set_limits_during_gesture_follows_transition_rule() {
    Sim sim;
    sim.bootToIdle();
    sim.send(gestureCmd(GestureId::Shake, 25));
    float prev = 0.0f;
    float peakVel = 0.0f;
    for (int i = 0; i < 15; ++i) {  // 300 ms: 加速中
        sim.advance(20);
        float joint = sim.yawJoint();
        peakVel = std::fmax(peakVel, std::fabs(joint - prev) / kDt);
        prev = joint;
    }
    TEST_ASSERT_TRUE(peakVel > 30.0f);
    sim.send(setLimitsCmd(200, 0, 0, 0));  // yaw 120 → 20°/s
    // T_tr = (120 − 20)/1200 + 3·1200/12000 = 0.383 s → 20 tick 目以降は新上限内
    for (int i = 1; i <= 500; ++i) {  // 20°/s では残り約 100° に 5 s 余り
        sim.advance(20);
        float joint = sim.yawJoint();
        float vel = std::fabs(joint - prev) / kDt;
        prev = joint;
        TEST_ASSERT_TRUE(vel <= 120.5f);
        TEST_ASSERT_TRUE(std::fabs(joint) <= 60.05f);
        if (i >= 20) TEST_ASSERT_TRUE(vel <= 20.5f);
        if (sim.now % 1000 == 0) sim.send(pingCmd(1));
        if (!sim.flag(StatusFlags::Gesture) && !sim.flag(StatusFlags::Moving)) break;
    }
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::Gesture));
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::Moving));
}

void test_nod_large_through_planner_meets_timing() {
    Sim sim;
    sim.bootToIdle();
    sim.send(torqueCmd(true));
    sim.advance(100);
    sim.send(gestureCmd(GestureId::Nod, 15, 1, 100));
    Kinematics k;
    k.push(sim.pitchJoint());
    uint32_t startMs = 0, endMs = 0;
    for (int i = 0; i < 200; ++i) {
        sim.advance(20);
        float p = sim.pitchJoint();
        if (startMs == 0 && std::fabs(p - k.pos.back()) > 1e-4f) startMs = sim.now - 20;
        k.push(p);
        if (startMs != 0 && !sim.flag(StatusFlags::Moving) && !sim.flag(StatusFlags::Gesture)) {
            endMs = sim.now;
            break;
        }
    }
    TEST_ASSERT_TRUE(startMs != 0 && endMs != 0);
    float seconds = (endMs - startMs) / 1000.0f;
    std::printf("nod: %.2f s min=%.2f max=%.2f vel=%.1f acc=%.0f jerk=%.0f\n", seconds, k.posMin, k.posMax, k.velMax,
                k.accMax, k.jerkMax);
    TEST_ASSERT_TRUE(seconds >= 1.0f && seconds <= 1.3f);
    TEST_ASSERT_TRUE(k.posMin <= -13.5f);
    TEST_ASSERT_TRUE(k.posMax >= 13.5f);
    TEST_ASSERT_TRUE(k.velMax <= config::kPitchDefaultVel + 0.5f);
    TEST_ASSERT_TRUE(k.accMax <= 2 * config::kPitchDefaultVel / config::kAccelTime + 5.0f);
    TEST_ASSERT_TRUE(k.jerkMax <= 4 * config::kPitchDefaultVel / (config::kAccelTime * config::kAccelTime) * 1.05f + 1.0f);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 1500.0f, sim.out.pitchPulseUs);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 1500.0f, sim.out.yawPulseUs);
}

void test_set_cal_from_idle_starts_output_smoothly() {
    Sim sim;
    sim.bootToIdle();
    sim.send(setCalCmd(50, 0, 0));
    assertState(sim, SupervisorState::Active);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::CalDirty));
    float prevYaw = 1500.0f;
    for (int i = 0; i < 50; ++i) {
        sim.advance(20);
        TEST_ASSERT_TRUE(sim.out.pwmEnabled);
        TEST_ASSERT_TRUE(std::fabs(sim.out.yawPulseUs - prevYaw) <= config::kYawDefaultVel * kDt * kGain * 1.05f);
        prevYaw = sim.out.yawPulseUs;
    }
    TEST_ASSERT_FLOAT_WITHIN(0.1f, 1500.0f + 5.0f * kGain, sim.out.yawPulseUs);
    TEST_ASSERT_EQUAL_INT16(0, sim.st().yawDeci);  // ジョイント角は 0 のまま
    CalibrationData cal = sim.sup.calibration();
    TEST_ASSERT_EQUAL_INT16(50, cal.yawOffDeci);
    TEST_ASSERT_FALSE(cal.saved);
}

void test_save_success_clears_dirty() {
    Sim sim;
    sim.bootToIdle();
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::CalDirty));  // 保存値なし
    sim.send(saveCalCmd(5));
    TEST_ASSERT_TRUE(sim.sup.lastSaveOk());
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::CalDirty));
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::SaveError));
    TEST_ASSERT_EQUAL_UINT8(5, sim.st().saveSeq);
    TEST_ASSERT_EQUAL(1, sim.storage.saveCount);
    TEST_ASSERT_EQUAL_UINT8(kCalBlobVersion, sim.storage.blob.version);
    TEST_ASSERT_EQUAL_UINT16(1111, sim.storage.blob.yawGainCenti);
    TEST_ASSERT_EQUAL_UINT16(calBlobCrc(sim.storage.blob), sim.storage.blob.crc16);
    TEST_ASSERT_TRUE(sim.sup.calibration().saved);
    sim.send(saveCalCmd(5));  // 同じ req の再送は冪等。保存値が同じなら書き込まない
    TEST_ASSERT_TRUE(sim.sup.lastSaveOk());
    TEST_ASSERT_EQUAL(1, sim.storage.saveCount);
    TEST_ASSERT_EQUAL_UINT8(5, sim.st().saveSeq);
    sim.send(saveCalCmd(0));
    TEST_ASSERT_EQUAL_UINT8(1, sim.st().rejectedCount);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::Rejected));
    TEST_ASSERT_EQUAL_UINT8(5, sim.st().saveSeq);
}

void test_save_failure_sets_save_error_and_sets_save_seq() {
    Sim sim;
    sim.bootToIdle();
    sim.storage.failSave = true;
    sim.send(saveCalCmd(6));
    TEST_ASSERT_FALSE(sim.sup.lastSaveOk());
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::SaveError));
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::CalDirty));
    TEST_ASSERT_EQUAL_UINT8(6, sim.st().saveSeq);
    sim.send(setCalCmd(10, 0, 0));
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::SaveError));
    TEST_ASSERT_EQUAL_UINT8(6, sim.st().saveSeq);
    sim.storage.failSave = false;
    sim.send(saveCalCmd(7));
    TEST_ASSERT_TRUE(sim.sup.lastSaveOk());
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::SaveError));
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::CalDirty));
    TEST_ASSERT_EQUAL_UINT8(7, sim.st().saveSeq);
    TEST_ASSERT_EQUAL_INT16(10, sim.storage.blob.yawOffDeci);
}

void test_corrupt_blob_falls_back_to_defaults() {
    {
        Sim sim;
        sim.storage.corrupt = true;
        Supervisor sup(sim.storage, 0, false);
        CalibrationSnapshot snap = sup.calibrationSnapshot();
        TEST_ASSERT_EQUAL_FLOAT(0.0f, snap.yawOffset);
        TEST_ASSERT_EQUAL_FLOAT(0.0f, snap.pitchOffset);
        TEST_ASSERT_FLOAT_WITHIN(0.001f, 11.11f, snap.yawGain);
        TEST_ASSERT_FALSE(snap.saved);
        TEST_ASSERT_TRUE((sup.status().flags & StatusFlags::CalDirty) != 0);
    }
    {
        FakeStorage shared;
        {
            Sim sim(shared, 0);
            sim.bootToIdle();
            sim.send(setCalCmd(25, -10, 2));
            sim.send(saveCalCmd(1));
            TEST_ASSERT_TRUE(sim.sup.lastSaveOk());
        }
        Sim again(shared, 0);
        CalibrationSnapshot snap = again.sup.calibrationSnapshot();
        TEST_ASSERT_FLOAT_WITHIN(0.001f, 2.5f, snap.yawOffset);
        TEST_ASSERT_FLOAT_WITHIN(0.001f, -1.0f, snap.pitchOffset);
        TEST_ASSERT_FALSE(snap.yawInvert);
        TEST_ASSERT_TRUE(snap.pitchInvert);
        TEST_ASSERT_TRUE(snap.saved);
        TEST_ASSERT_FALSE(again.flag(StatusFlags::CalDirty));
        again.advance(500);  // BOOT_CENTER は保存済みキャリブレーションの中立を出す
        TEST_ASSERT_FLOAT_WITHIN(0.1f, 1500.0f + 2.5f * kGain, again.out.yawPulseUs);
        TEST_ASSERT_FLOAT_WITHIN(0.1f, 1500.0f + 1.0f * kGain, again.out.pitchPulseUs);  // −1° を反転
    }
}

void test_set_limits_rules_and_mid_motion() {
    {
        Sim sim;
        sim.bootToIdle();
        sim.send(setLimitsCmd(0, 0, 0, 0));
        LimitsData lim = sim.sup.limits();
        TEST_ASSERT_EQUAL_UINT16(1200, lim.yawVelDeci);
        TEST_ASSERT_EQUAL_UINT16(1000, lim.pitchVelDeci);
        TEST_ASSERT_EQUAL_INT16(600, lim.yawAngDeci);
        TEST_ASSERT_EQUAL_INT16(300, lim.pitchAngDeci);
        TEST_ASSERT_FALSE(sim.flag(StatusFlags::Saturated));
        sim.send(setLimitsCmd(1, 1, 1, 1));
        lim = sim.sup.limits();
        TEST_ASSERT_EQUAL_UINT16(50, lim.yawVelDeci);
        TEST_ASSERT_EQUAL_UINT16(50, lim.pitchVelDeci);
        TEST_ASSERT_EQUAL_INT16(50, lim.yawAngDeci);
        TEST_ASSERT_EQUAL_INT16(50, lim.pitchAngDeci);
        TEST_ASSERT_TRUE(sim.flag(StatusFlags::Saturated));
        sim.send(setLimitsCmd(5000, 5000, 900, 900));  // 絶対上限で飽和
        lim = sim.sup.limits();
        TEST_ASSERT_EQUAL_UINT16(1800, lim.yawVelDeci);
        TEST_ASSERT_EQUAL_UINT16(1200, lim.pitchVelDeci);
        TEST_ASSERT_EQUAL_INT16(600, lim.yawAngDeci);
        TEST_ASSERT_EQUAL_INT16(300, lim.pitchAngDeci);
        assertState(sim, SupervisorState::Idle);  // 保守要求は状態を変えない
    }
    {
        Sim sim;
        sim.bootToIdle();
        sim.send(moveCmd(50, 0));
        TEST_ASSERT_TRUE(sim.settle());
        TEST_ASSERT_EQUAL_INT16(500, sim.st().yawDeci);
        sim.send(setLimitsCmd(0, 0, 100, 0));
        float prev = sim.out.yawPulseUs;
        for (int i = 0; i < 100; ++i) {
            sim.advance(20);
            TEST_ASSERT_TRUE(std::fabs(sim.out.yawPulseUs - prev) <= config::kYawDefaultVel * kDt * kGain * 1.05f);
            TEST_ASSERT_TRUE(std::fabs(sim.yawJoint()) <= 60.0f);
            prev = sim.out.yawPulseUs;
            if (sim.now % 1000 == 0) sim.send(pingCmd(1));
        }
        TEST_ASSERT_EQUAL_INT16(100, sim.st().yawDeci);
        TEST_ASSERT_FALSE(sim.flag(StatusFlags::Moving));
    }
}

void test_gain_change_keeps_pulse() {
    Sim sim;
    sim.bootToIdle();
    sim.send(torqueCmd(true));
    sim.advance(100);
    assertState(sim, SupervisorState::Active);
    TEST_ASSERT_EQUAL(static_cast<int>(GainResult::Saved), static_cast<int>(sim.sup.setGain(7.41f, 7.41f, sim.now)));
    sim.advance(20);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 1500.0f, sim.out.yawPulseUs);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 1500.0f, sim.out.pitchPulseUs);
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::CalDirty));
    TEST_ASSERT_EQUAL_UINT16(741, sim.storage.blob.yawGainCenti);
    sim.send(moveCmd(30, 0));
    TEST_ASSERT_TRUE(sim.settle());
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 1500.0f + 30.0f * 7.41f, sim.out.yawPulseUs);
    TEST_ASSERT_EQUAL_INT16(300, sim.st().yawDeci);
}

void test_gain_rejected_while_moving_or_out_of_range() {
    Sim sim;
    sim.bootToIdle();
    sim.send(moveCmd(30, 0));
    sim.advance(100);
    float before = sim.out.yawPulseUs;
    TEST_ASSERT_EQUAL(static_cast<int>(GainResult::Rejected), static_cast<int>(sim.sup.setGain(7.41f, 7.41f, sim.now)));
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 11.11f, sim.sup.calibrationSnapshot().yawGain);
    TEST_ASSERT_EQUAL(0, sim.storage.saveCount);
    sim.advance(20);
    TEST_ASSERT_TRUE(std::fabs(sim.out.yawPulseUs - before) <= config::kYawDefaultVel * kDt * kGain * 1.05f);
    TEST_ASSERT_TRUE(sim.settle());
    TEST_ASSERT_EQUAL(static_cast<int>(GainResult::Rejected), static_cast<int>(sim.sup.setGain(5.0f, 5.0f, sim.now)));  // 66.7° > 60°
    TEST_ASSERT_EQUAL(static_cast<int>(GainResult::Rejected), static_cast<int>(sim.sup.setGain(4.9f, 11.11f, sim.now)));
    TEST_ASSERT_EQUAL(static_cast<int>(GainResult::Rejected), static_cast<int>(sim.sup.setGain(11.11f, 15.01f, sim.now)));
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 11.11f, sim.sup.calibrationSnapshot().yawGain);
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 1500.0f + 30.0f * kGain, sim.out.yawPulseUs);
}

void test_gain_save_failure_keeps_ram_value_and_marks_dirty() {
    Sim sim;
    sim.bootToIdle();
    sim.send(saveCalCmd(3));
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::CalDirty));
    sim.send(torqueCmd(true));
    sim.advance(100);
    sim.storage.failSave = true;
    TEST_ASSERT_EQUAL(static_cast<int>(GainResult::SaveFailed), static_cast<int>(sim.sup.setGain(7.41f, 7.41f, sim.now)));
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 7.41f, sim.sup.calibrationSnapshot().yawGain);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::CalDirty));
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::SaveError));
    TEST_ASSERT_EQUAL_UINT8(3, sim.st().saveSeq);
    sim.advance(20);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 1500.0f, sim.out.yawPulseUs);
}

void test_gain_change_with_offset_moves_to_original_joint_target() {
    Sim sim;
    sim.bootToIdle();
    sim.send(setCalCmd(50, 0, 0));  // ヨーのオフセット +5°、ジョイント目標は 0°
    TEST_ASSERT_TRUE(sim.settle());
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 1500.0f + 5.0f * kGain, sim.out.yawPulseUs);
    TEST_ASSERT_EQUAL(static_cast<int>(GainResult::Saved), static_cast<int>(sim.sup.setGain(7.41f, 7.41f, sim.now)));
    sim.advance(20);
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 1500.0f + 5.0f * kGain, sim.out.yawPulseUs);  // 直後の µs は変わらない
    float prev = sim.out.yawPulseUs;
    for (int i = 0; i < 60; ++i) {
        sim.advance(20);
        TEST_ASSERT_TRUE(std::fabs(sim.out.yawPulseUs - prev) <= config::kYawDefaultVel * kDt * kGain * 1.05f);
        prev = sim.out.yawPulseUs;
        if (sim.now % 1000 == 0) sim.send(pingCmd(1));
    }
    // 新ゲインのもとで元のジョイント目標 0°（= サーボ角 +5°）へ S 字で移る
    TEST_ASSERT_FLOAT_WITHIN(0.1f, 1500.0f + 5.0f * 7.41f, sim.out.yawPulseUs);
    TEST_ASSERT_EQUAL_INT16(0, sim.st().yawDeci);
}

void test_gain_and_save_follow_maintenance_rules() {
    {
        Sim sim;
        sim.advance(100);  // BOOT 中は破棄（REJECTED にも通信にも数えない）
        TEST_ASSERT_EQUAL(static_cast<int>(GainResult::Rejected), static_cast<int>(sim.sup.setGain(7.41f, 7.41f, sim.now)));
        TEST_ASSERT_FALSE(sim.sup.saveCalibration(3, sim.now));
        TEST_ASSERT_EQUAL(0, sim.storage.saveCount);
        TEST_ASSERT_FLOAT_WITHIN(0.001f, 11.11f, sim.sup.calibrationSnapshot().yawGain);
        TEST_ASSERT_EQUAL_UINT8(0, sim.st().saveSeq);
        TEST_ASSERT_EQUAL_UINT8(0, sim.st().rejectedCount);
    }
    {
        Sim sim;
        sim.bootToIdle();
        sim.send(torqueCmd(true));  // 1500 ms に通信
        sim.advance(2980);          // 4480 ms
        TEST_ASSERT_EQUAL(static_cast<int>(GainResult::Saved), static_cast<int>(sim.sup.setGain(11.11f, 11.11f, sim.now)));
        sim.advance(20);  // 4500 ms: GAIN が通信扱いなので ACTIVE のまま
        assertState(sim, SupervisorState::Active);
        TEST_ASSERT_TRUE(sim.sup.saveCalibration(4, sim.now));
        TEST_ASSERT_EQUAL_UINT8(4, sim.st().saveSeq);
        sim.advance(2980);  // 7480 ms
        assertState(sim, SupervisorState::Active);
        sim.advance(20);  // 7500 ms: 最後の通信（4500）から 3.0 s
        assertState(sim, SupervisorState::Returning);
        TEST_ASSERT_FALSE(sim.sup.saveCalibration(0, sim.now));  // req 0 は拒否
        TEST_ASSERT_EQUAL_UINT8(1, sim.st().rejectedCount);
        TEST_ASSERT_EQUAL_UINT8(4, sim.st().saveSeq);
        assertState(sim, SupervisorState::Returning);  // 保守要求は復帰を解除しない
    }
}

void test_gesture_speed_scales_hold_and_time() {
    auto run = [](GestureId id, float amp, uint8_t speed) -> uint32_t {
        Sim sim;
        sim.bootToIdle();
        sim.send(gestureCmd(id, amp, 1, speed));
        const uint32_t start = sim.now;
        while (sim.flag(StatusFlags::Gesture) && sim.now - start < 20000) {
            sim.advance(20);
            if (sim.now % 1000 == 0) sim.send(pingCmd(1));
        }
        TEST_ASSERT_FALSE(sim.flag(StatusFlags::Gesture));
        return sim.now - start;
    };
    const uint32_t look100 = run(GestureId::LookUp, 15, 100);
    const uint32_t look50 = run(GestureId::LookUp, 15, 50);
    TEST_ASSERT_TRUE(look50 >= look100 + 2000 - 40);  // 保持 2.0 s が 4.0 s になる
    const uint32_t nod100 = run(GestureId::Nod, 15, 100);
    const uint32_t nod50 = run(GestureId::Nod, 15, 50);
    TEST_ASSERT_TRUE(nod50 >= nod100 * 13 / 10);  // 移動は速度上限 50% で遅くなる（静止→静止なので 2 倍にはならない）
    TEST_ASSERT_TRUE(nod50 <= nod100 * 5 / 2);
    const uint32_t tilt100 = run(GestureId::TiltL, 15, 100);
    const uint32_t tilt50 = run(GestureId::TiltL, 15, 50);
    TEST_ASSERT_TRUE(tilt50 >= tilt100 + 1500 - 40);  // 保持 1.5 s が 3.0 s になる
}

void test_status_fields() {
    Sim sim(true);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::Brownout));
    TEST_ASSERT_EQUAL(0, static_cast<int>(sim.st().state));
    TEST_ASSERT_EQUAL_UINT8(0, sim.st().saveSeq);
    TEST_ASSERT_EQUAL_UINT16(0, sim.st().voltageCenti);
    sim.bootToIdle();
    TEST_ASSERT_EQUAL(2, static_cast<int>(sim.st().state));
    sim.send(pingCmd(42));
    TEST_ASSERT_EQUAL_UINT8(42, sim.st().pingSeq);
    assertState(sim, SupervisorState::Idle);
    for (int i = 0; i < 300; ++i) sim.sup.onRejected();
    TEST_ASSERT_EQUAL_UINT8(255, sim.st().rejectedCount);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::Rejected));
    sim.send(pingCmd(43));
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::Rejected));  // 次の受理で下げる
    sim.sup.setPairOpen(true);
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::PairOpen));
    sim.sup.setPairOpen(false);
    TEST_ASSERT_FALSE(sim.flag(StatusFlags::PairOpen));
    TEST_ASSERT_TRUE(sim.flag(StatusFlags::Brownout));
    Status st = sim.st();
    TEST_ASSERT_EQUAL_INT16(0, st.yawDeci);
    TEST_ASSERT_EQUAL_INT16(0, st.pitchDeci);
}

void test_return_speed_switch_uses_transition_rule() {
    Sim sim;
    sim.bootToIdle();
    sim.sup.onLink(true, sim.now);
    sim.send(moveCmd(60, 0));
    float prev = sim.yawJoint();
    float vel = 0.0f;
    for (int i = 0; i < 15; ++i) {
        sim.advance(20);
        float joint = sim.yawJoint();
        vel = (joint - prev) / kDt;
        prev = joint;
    }
    TEST_ASSERT_TRUE(vel > 110.0f);  // 巡航中
    sim.sup.onLink(false, sim.now);
    assertState(sim, SupervisorState::Returning);
    // T_tr = (120 − 90)/1200 + 3·1200/12000 = 0.325 s → 17 tick 目以降は 90 以内
    bool relaxed = false;
    for (int i = 1; i <= 150; ++i) {
        sim.advance(20);
        float joint = sim.yawJoint();
        float v = std::fabs(joint - prev) / kDt;
        prev = joint;
        TEST_ASSERT_TRUE(v <= 120.5f);
        if (i >= 17) TEST_ASSERT_TRUE(v <= config::kReturnYawVel + 0.5f);
        if (sim.sup.state() == SupervisorState::RelaxWait) {
            relaxed = true;
            break;
        }
    }
    TEST_ASSERT_TRUE(relaxed);
    TEST_ASSERT_EQUAL_INT16(0, sim.st().yawDeci);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_boot_mute_then_center_then_idle);
    RUN_TEST(test_boot_discards_requests_but_remembers_stop);
    RUN_TEST(test_move_from_idle_activates_and_moves);
    RUN_TEST(test_silence_3s_returns_then_relaxes);
    RUN_TEST(test_disconnect_during_gesture_returns_immediately);
    RUN_TEST(test_ping_after_reconnect_does_not_resume);
    RUN_TEST(test_return_deadline_2s);
    RUN_TEST(test_stop_is_highest_priority);
    RUN_TEST(test_rejected_input_does_not_feed_watchdog);
    RUN_TEST(test_gesture_queue_rules);
    RUN_TEST(test_maintenance_requests_do_not_cancel_return);
    RUN_TEST(test_torque_off_discards_playing_and_pending);
    RUN_TEST(test_set_limits_during_gesture_follows_transition_rule);
    RUN_TEST(test_nod_large_through_planner_meets_timing);
    RUN_TEST(test_set_cal_from_idle_starts_output_smoothly);
    RUN_TEST(test_save_success_clears_dirty);
    RUN_TEST(test_save_failure_sets_save_error_and_sets_save_seq);
    RUN_TEST(test_corrupt_blob_falls_back_to_defaults);
    RUN_TEST(test_set_limits_rules_and_mid_motion);
    RUN_TEST(test_gain_change_keeps_pulse);
    RUN_TEST(test_gain_rejected_while_moving_or_out_of_range);
    RUN_TEST(test_gain_save_failure_keeps_ram_value_and_marks_dirty);
    RUN_TEST(test_gain_change_with_offset_moves_to_original_joint_target);
    RUN_TEST(test_gain_and_save_follow_maintenance_rules);
    RUN_TEST(test_gesture_speed_scales_hold_and_time);
    RUN_TEST(test_status_fields);
    RUN_TEST(test_return_speed_switch_uses_transition_rule);
    return UNITY_END();
}
