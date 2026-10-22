#include <unity.h>

#include <cstdio>
#include <cstring>

#include "catneck/SerialParser.h"

using namespace catneck;

void setUp() {}
void tearDown() {}

namespace {

ParsedLine parse(const char* line) { return parseLine(line, std::strlen(line)); }

void assertCommand(const ParsedLine& p, CommandType type) {
    TEST_ASSERT_EQUAL(static_cast<int>(ParsedLine::Kind::Command), static_cast<int>(p.kind));
    TEST_ASSERT_EQUAL(static_cast<int>(type), static_cast<int>(p.command.type));
}

void assertError(const ParsedLine& p, const char* error) {
    TEST_ASSERT_EQUAL(static_cast<int>(ParsedLine::Kind::Error), static_cast<int>(p.kind));
    TEST_ASSERT_EQUAL_STRING(error, p.error);
}

void assertAction(const ParsedLine& p, ConsoleAction action) {
    TEST_ASSERT_EQUAL(static_cast<int>(ParsedLine::Kind::Action), static_cast<int>(p.kind));
    TEST_ASSERT_EQUAL(static_cast<int>(action), static_cast<int>(p.action));
}

}  // namespace

void test_move_line() {
    ParsedLine p = parse("move 20 -5 100");
    assertCommand(p, CommandType::Move);
    TEST_ASSERT_EQUAL_INT16(200, p.command.move.yawDeci);
    TEST_ASSERT_EQUAL_INT16(-50, p.command.move.pitchDeci);
    TEST_ASSERT_EQUAL_UINT8(100, p.command.move.speed);

    ParsedLine noSpeed = parse("MOVE 12.34 0.56");
    assertCommand(noSpeed, CommandType::Move);
    TEST_ASSERT_EQUAL_INT16(123, noSpeed.command.move.yawDeci);
    TEST_ASSERT_EQUAL_INT16(6, noSpeed.command.move.pitchDeci);
    TEST_ASSERT_EQUAL_UINT8(0, noSpeed.command.move.speed);

    assertError(parse("MOVE 20"), "BAD_ARGS");
    assertError(parse("MOVE a b"), "BAD_ARGS");
    assertError(parse("MOVE 1 2 3 4"), "BAD_ARGS");
}

void test_gesture_names_and_ids() {
    ParsedLine nod = parse("GESTURE nod 15");
    assertCommand(nod, CommandType::Gesture);
    TEST_ASSERT_EQUAL(static_cast<int>(GestureId::Nod), static_cast<int>(nod.command.gesture.id));
    TEST_ASSERT_EQUAL_UINT8(150, nod.command.gesture.ampDeci);
    TEST_ASSERT_EQUAL_UINT8(1, nod.command.gesture.repeats);
    TEST_ASSERT_EQUAL_UINT8(0, nod.command.gesture.speed);

    ParsedLine shake = parse("gesture 2 25 3 50");
    assertCommand(shake, CommandType::Gesture);
    TEST_ASSERT_EQUAL(static_cast<int>(GestureId::Shake), static_cast<int>(shake.command.gesture.id));
    TEST_ASSERT_EQUAL_UINT8(250, shake.command.gesture.ampDeci);
    TEST_ASSERT_EQUAL_UINT8(3, shake.command.gesture.repeats);
    TEST_ASSERT_EQUAL_UINT8(50, shake.command.gesture.speed);

    const char* names[] = {"tilt_l", "TILT_R", "look_up", "Look_Down"};
    const GestureId ids[] = {GestureId::TiltL, GestureId::TiltR, GestureId::LookUp, GestureId::LookDown};
    for (int i = 0; i < 4; ++i) {
        char line[40];
        std::snprintf(line, sizeof line, "gesture %s 8", names[i]);
        ParsedLine g = parse(line);
        assertCommand(g, CommandType::Gesture);
        TEST_ASSERT_EQUAL(static_cast<int>(ids[i]), static_cast<int>(g.command.gesture.id));
        TEST_ASSERT_EQUAL_UINT8(80, g.command.gesture.ampDeci);
    }

    assertError(parse("gesture jump 1"), "BAD_ARGS");
    assertError(parse("gesture 7 1"), "BAD_ARGS");
    assertError(parse("gesture nod"), "BAD_ARGS");
    ParsedLine big = parse("gesture nod 30");  // 25.5° 超は 255 に飽和
    TEST_ASSERT_EQUAL_UINT8(255, big.command.gesture.ampDeci);
}

void test_simple_commands() {
    assertCommand(parse("STOP"), CommandType::Stop);
    assertError(parse("STOP 1"), "BAD_ARGS");

    ParsedLine center = parse("CENTER 50");
    assertCommand(center, CommandType::Center);
    TEST_ASSERT_EQUAL_UINT8(50, center.command.center.speed);
    ParsedLine centerDefault = parse("center");
    assertCommand(centerDefault, CommandType::Center);
    TEST_ASSERT_EQUAL_UINT8(0, centerDefault.command.center.speed);

    ParsedLine torque = parse("TORQUE 1");
    assertCommand(torque, CommandType::Torque);
    TEST_ASSERT_TRUE(torque.command.torque.on);
    ParsedLine torqueOff = parse("torque 0");
    TEST_ASSERT_FALSE(torqueOff.command.torque.on);
    assertError(parse("TORQUE 2"), "BAD_ARGS");

    ParsedLine ping = parse("PING 9");
    assertCommand(ping, CommandType::Ping);
    TEST_ASSERT_EQUAL_UINT8(9, ping.command.ping.seq);
    ParsedLine pingDefault = parse("ping");
    TEST_ASSERT_EQUAL_UINT8(0, pingDefault.command.ping.seq);

    ParsedLine save = parse("SAVE 3");
    assertCommand(save, CommandType::SaveCal);
    TEST_ASSERT_EQUAL_UINT8(3, save.command.saveCal.req);
    ParsedLine saveDefault = parse("save");
    assertCommand(saveDefault, CommandType::SaveCal);
    TEST_ASSERT_EQUAL_UINT8(0, saveDefault.command.saveCal.req);  // 0 = 「前回 +1」を Console が埋める印

    ParsedLine cal = parse("CAL 2.5 -1 3");
    assertCommand(cal, CommandType::SetCal);
    TEST_ASSERT_EQUAL_INT16(25, cal.command.setCal.yawOffDeci);
    TEST_ASSERT_EQUAL_INT16(-10, cal.command.setCal.pitchOffDeci);
    TEST_ASSERT_EQUAL_UINT8(3, cal.command.setCal.invert);
    assertError(parse("CAL 1 2"), "BAD_ARGS");

    ParsedLine limits = parse("LIMITS 120 100 60 30");
    assertCommand(limits, CommandType::SetLimits);
    TEST_ASSERT_EQUAL_UINT16(1200, limits.command.setLimits.yawVelDeci);
    TEST_ASSERT_EQUAL_UINT16(1000, limits.command.setLimits.pitchVelDeci);
    TEST_ASSERT_EQUAL_INT16(600, limits.command.setLimits.yawAngDeci);
    TEST_ASSERT_EQUAL_INT16(300, limits.command.setLimits.pitchAngDeci);
    ParsedLine keep = parse("limits 0 0 0 0");
    assertCommand(keep, CommandType::SetLimits);
    TEST_ASSERT_EQUAL_UINT16(0, keep.command.setLimits.yawVelDeci);
}

void test_actions() {
    assertAction(parse("STATUS"), ConsoleAction::Status);
    assertAction(parse("watch on"), ConsoleAction::WatchOn);
    assertAction(parse("WATCH OFF"), ConsoleAction::WatchOff);
    assertError(parse("WATCH"), "BAD_ARGS");
    assertAction(parse("INFO"), ConsoleAction::Info);
    assertAction(parse("help"), ConsoleAction::Help);
    assertAction(parse("BONDS CLEAR"), ConsoleAction::BondsClear);
    assertError(parse("BONDS"), "BAD_ARGS");
    assertAction(parse("PAIR OPEN"), ConsoleAction::PairOpen);

    ParsedLine gain = parse("GAIN 11.11 11.11");
    assertAction(gain, ConsoleAction::Gain);
    TEST_ASSERT_EQUAL_FLOAT(11.11f, gain.gainYaw);
    TEST_ASSERT_EQUAL_FLOAT(11.11f, gain.gainPitch);
    assertError(parse("GAIN 4 11"), "RANGE");
    assertError(parse("GAIN 11 15.01"), "RANGE");
    assertError(parse("GAIN 11"), "BAD_ARGS");
    assertError(parse("GAIN x y"), "BAD_ARGS");
}

void test_hex_matches_binary_decoder() {
    ParsedLine hex = parse("HEX 01 C8 00 CE FF 64");
    assertCommand(hex, CommandType::Move);
    const uint8_t raw[] = {0x01, 0xC8, 0x00, 0xCE, 0xFF, 0x64};
    DecodeResult direct = decodeCommand(raw, sizeof raw);
    TEST_ASSERT_EQUAL_INT16(direct.command.move.yawDeci, hex.command.move.yawDeci);
    TEST_ASSERT_EQUAL_INT16(direct.command.move.pitchDeci, hex.command.move.pitchDeci);
    TEST_ASSERT_EQUAL_UINT8(direct.command.move.speed, hex.command.move.speed);

    ParsedLine compact = parse("hex 0905");
    assertCommand(compact, CommandType::Ping);
    TEST_ASSERT_EQUAL_UINT8(5, compact.command.ping.seq);

    assertError(parse("HEX 02 00"), "BAD_LENGTH");
    assertError(parse("HEX 0A"), "UNKNOWN_TYPE");
    assertError(parse("HEX"), "BAD_ARGS");
    assertError(parse("HEX zz"), "BAD_ARGS");
    assertError(parse("HEX 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15"), "BAD_ARGS");
}

void test_unknown_and_crlf() {
    assertError(parse("FOO\r"), "UNKNOWN");
    assertCommand(parse("STOP\r"), CommandType::Stop);
    assertCommand(parse("  stop  "), CommandType::Stop);
    assertError(parse(""), "UNKNOWN");
    assertError(parse("\r"), "UNKNOWN");
}

void test_format_status_line() {
    Status st{};
    st.yawDeci = -123;
    st.pitchDeci = 45;
    st.flags = StatusFlags::Link | StatusFlags::Torque | StatusFlags::SaveError;  // 0x0403
    st.pingSeq = 7;
    st.state = SupervisorState::Active;
    st.rejectedCount = 3;
    st.saveSeq = 250;
    char out[96];
    size_t n = formatStatusLine(st, out, sizeof out);
    TEST_ASSERT_EQUAL_STRING("STATUS yaw=-12.3 pitch=4.5 flags=0x0403 seq=7 state=3 err=3 save=250", out);
    TEST_ASSERT_EQUAL(std::strlen(out), n);
    char small[8];
    size_t m = formatStatusLine(st, small, sizeof small);
    TEST_ASSERT_TRUE(m < sizeof small);
    TEST_ASSERT_EQUAL(std::strlen(small), m);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_move_line);
    RUN_TEST(test_gesture_names_and_ids);
    RUN_TEST(test_simple_commands);
    RUN_TEST(test_actions);
    RUN_TEST(test_hex_matches_binary_decoder);
    RUN_TEST(test_unknown_and_crlf);
    RUN_TEST(test_format_status_line);
    return UNITY_END();
}
