#include <unity.h>

#include <cstdint>
#include <cstring>
#include <initializer_list>

#include "catneck/Protocol.h"

using namespace catneck;

void setUp() {}
void tearDown() {}

namespace {

DecodeResult decode(std::initializer_list<uint8_t> bytes) {
    uint8_t buf[32] = {};
    size_t n = 0;
    for (uint8_t b : bytes) buf[n++] = b;
    return decodeCommand(buf, n);
}

}  // namespace

void test_decode_move() {
    DecodeResult r = decode({0x01, 0xC8, 0x00, 0xCE, 0xFF, 0x64});
    TEST_ASSERT_TRUE(r.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::None), static_cast<int>(r.error));
    TEST_ASSERT_EQUAL(static_cast<int>(CommandType::Move), static_cast<int>(r.command.type));
    TEST_ASSERT_EQUAL_INT16(200, r.command.move.yawDeci);
    TEST_ASSERT_EQUAL_INT16(-50, r.command.move.pitchDeci);
    TEST_ASSERT_EQUAL_UINT8(100, r.command.move.speed);
}

void test_decode_gesture_and_bad_id() {
    DecodeResult r = decode({0x02, 1, 150, 2, 100});
    TEST_ASSERT_TRUE(r.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(GestureId::Nod), static_cast<int>(r.command.gesture.id));
    TEST_ASSERT_EQUAL_UINT8(150, r.command.gesture.ampDeci);
    TEST_ASSERT_EQUAL_UINT8(2, r.command.gesture.repeats);
    TEST_ASSERT_EQUAL_UINT8(100, r.command.gesture.speed);

    DecodeResult zero = decode({0x02, 0, 150, 1, 100});
    TEST_ASSERT_FALSE(zero.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::BadGestureId), static_cast<int>(zero.error));
    DecodeResult seven = decode({0x02, 7, 150, 1, 100});
    TEST_ASSERT_FALSE(seven.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::BadGestureId), static_cast<int>(seven.error));
}

void test_decode_rejects_bad_lengths() {
    DecodeResult empty = decodeCommand(nullptr, 0);
    TEST_ASSERT_FALSE(empty.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::Empty), static_cast<int>(empty.error));

    // 種別ごとの固定長 ±1
    const uint8_t types[] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09};
    const size_t lengths[] = {6, 5, 1, 2, 2, 6, 2, 9, 2};
    for (size_t i = 0; i < 9; ++i) {
        uint8_t buf[20] = {};
        buf[0] = types[i];
        if (types[i] == 0x02) buf[1] = 1;  // 有効な id
        if (types[i] == 0x05) buf[1] = 1;  // 有効な on
        if (types[i] == 0x07) buf[1] = 1;  // 有効な req
        DecodeResult longer = decodeCommand(buf, lengths[i] + 1);
        TEST_ASSERT_FALSE_MESSAGE(longer.ok, "length+1 must be rejected");
        TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::BadLength), static_cast<int>(longer.error));
        if (lengths[i] > 1) {
            DecodeResult shorter = decodeCommand(buf, lengths[i] - 1);
            TEST_ASSERT_FALSE_MESSAGE(shorter.ok, "length-1 must be rejected");
            TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::BadLength), static_cast<int>(shorter.error));
        }
    }

    uint8_t big[21] = {0x01};
    DecodeResult tooLong = decodeCommand(big, 21);
    TEST_ASSERT_FALSE(tooLong.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::BadLength), static_cast<int>(tooLong.error));
}

void test_decode_unknown_type() {
    DecodeResult r = decode({0x0A});
    TEST_ASSERT_FALSE(r.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::UnknownType), static_cast<int>(r.error));
    DecodeResult z = decode({0x00, 1, 2});
    TEST_ASSERT_FALSE(z.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::UnknownType), static_cast<int>(z.error));
}

void test_decode_torque_and_set_limits() {
    DecodeResult torque2 = decode({0x05, 2});
    TEST_ASSERT_FALSE(torque2.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::BadTorqueValue), static_cast<int>(torque2.error));
    DecodeResult torque1 = decode({0x05, 1});
    TEST_ASSERT_TRUE(torque1.ok);
    TEST_ASSERT_TRUE(torque1.command.torque.on);
    DecodeResult torque0 = decode({0x05, 0});
    TEST_ASSERT_TRUE(torque0.ok);
    TEST_ASSERT_FALSE(torque0.command.torque.on);

    // yawAngDeci = -1
    DecodeResult neg = decode({0x08, 0xB0, 0x04, 0xE8, 0x03, 0xFF, 0xFF, 0x2C, 0x01});
    TEST_ASSERT_FALSE(neg.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::NegativeAngleLimit), static_cast<int>(neg.error));

    DecodeResult zeros = decode({0x08, 0, 0, 0, 0, 0, 0, 0, 0});
    TEST_ASSERT_TRUE(zeros.ok);
    TEST_ASSERT_EQUAL_UINT16(0, zeros.command.setLimits.yawVelDeci);
    TEST_ASSERT_EQUAL_INT16(0, zeros.command.setLimits.pitchAngDeci);

    DecodeResult full = decode({0x08, 0xB0, 0x04, 0xE8, 0x03, 0x58, 0x02, 0x2C, 0x01});
    TEST_ASSERT_TRUE(full.ok);
    TEST_ASSERT_EQUAL_UINT16(1200, full.command.setLimits.yawVelDeci);
    TEST_ASSERT_EQUAL_UINT16(1000, full.command.setLimits.pitchVelDeci);
    TEST_ASSERT_EQUAL_INT16(600, full.command.setLimits.yawAngDeci);
    TEST_ASSERT_EQUAL_INT16(300, full.command.setLimits.pitchAngDeci);
}

void test_decode_save_cal_req() {
    DecodeResult r = decode({0x07, 9});
    TEST_ASSERT_TRUE(r.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(CommandType::SaveCal), static_cast<int>(r.command.type));
    TEST_ASSERT_EQUAL_UINT8(9, r.command.saveCal.req);
    DecodeResult zero = decode({0x07, 0});
    TEST_ASSERT_FALSE(zero.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::BadSaveReq), static_cast<int>(zero.error));
    DecodeResult shortOne = decode({0x07});
    TEST_ASSERT_FALSE(shortOne.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(DecodeError::BadLength), static_cast<int>(shortOne.error));
}

void test_decode_simple_commands() {
    DecodeResult stop = decode({0x03});
    TEST_ASSERT_TRUE(stop.ok);
    TEST_ASSERT_EQUAL(static_cast<int>(CommandType::Stop), static_cast<int>(stop.command.type));
    DecodeResult center = decode({0x04, 50});
    TEST_ASSERT_TRUE(center.ok);
    TEST_ASSERT_EQUAL_UINT8(50, center.command.center.speed);
    DecodeResult ping = decode({0x09, 0xAB});
    TEST_ASSERT_TRUE(ping.ok);
    TEST_ASSERT_EQUAL_UINT8(0xAB, ping.command.ping.seq);
    DecodeResult cal = decode({0x06, 0x19, 0x00, 0xF6, 0xFF, 0x03});
    TEST_ASSERT_TRUE(cal.ok);
    TEST_ASSERT_EQUAL_INT16(25, cal.command.setCal.yawOffDeci);
    TEST_ASSERT_EQUAL_INT16(-10, cal.command.setCal.pitchOffDeci);
    TEST_ASSERT_EQUAL_UINT8(3, cal.command.setCal.invert);
}

void test_encode_status_layout() {
    Status st{};
    st.yawDeci = -123;
    st.pitchDeci = 45;
    st.flags = StatusFlags::Link | StatusFlags::Torque | StatusFlags::SaveError;
    st.pingSeq = 7;
    st.state = SupervisorState::Active;
    st.voltageCenti = 0;
    st.rejectedCount = 3;
    st.saveSeq = 250;
    uint8_t out[kStatusSize] = {};
    encodeStatus(st, out);
    const uint8_t expected[kStatusSize] = {0x85, 0xFF, 0x2D, 0x00, 0x03, 0x04, 0x07, 0x03, 0x00, 0x00, 0x03, 0xFA};
    TEST_ASSERT_EQUAL_UINT8_ARRAY(expected, out, kStatusSize);
    TEST_ASSERT_EQUAL(12, kStatusSize);
}

void test_encode_calibration_limits_info() {
    CalibrationData cal{-25, 10, 2, true};
    uint8_t c[kCalibrationSize] = {};
    encodeCalibration(cal, c);
    const uint8_t ce[kCalibrationSize] = {0xE7, 0xFF, 0x0A, 0x00, 0x02, 0x01};
    TEST_ASSERT_EQUAL_UINT8_ARRAY(ce, c, kCalibrationSize);

    LimitsData lim{1200, 1000, 600, 300};
    uint8_t l[kLimitsSize] = {};
    encodeLimits(lim, l);
    const uint8_t le[kLimitsSize] = {0xB0, 0x04, 0xE8, 0x03, 0x58, 0x02, 0x2C, 0x01};
    TEST_ASSERT_EQUAL_UINT8_ARRAY(le, l, kLimitsSize);

    InfoData info{1, 0, 1, 0, 1, 0};
    uint8_t i[kInfoSize] = {0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE};
    encodeInfo(info, i);
    const uint8_t ie[kInfoSize] = {0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00};
    TEST_ASSERT_EQUAL_UINT8_ARRAY(ie, i, kInfoSize);
}

void test_decode_calibration_and_limits_write() {
    const uint8_t c6[6] = {0x19, 0x00, 0xF6, 0xFF, 0x01, 0x01};
    SetCalCmd cal{};
    TEST_ASSERT_TRUE(decodeCalibrationWrite(c6, 6, cal));
    TEST_ASSERT_EQUAL_INT16(25, cal.yawOffDeci);
    TEST_ASSERT_EQUAL_INT16(-10, cal.pitchOffDeci);
    TEST_ASSERT_EQUAL_UINT8(1, cal.invert);
    TEST_ASSERT_FALSE(decodeCalibrationWrite(c6, 5, cal));
    TEST_ASSERT_FALSE(decodeCalibrationWrite(c6, 7 > 6 ? 6 + 1 : 6, cal));

    const uint8_t l8[8] = {0xB0, 0x04, 0xE8, 0x03, 0x58, 0x02, 0x2C, 0x01};
    SetLimitsCmd lim{};
    TEST_ASSERT_TRUE(decodeLimitsWrite(l8, 8, lim));
    TEST_ASSERT_EQUAL_UINT16(1200, lim.yawVelDeci);
    TEST_ASSERT_EQUAL_INT16(300, lim.pitchAngDeci);
    TEST_ASSERT_FALSE(decodeLimitsWrite(l8, 7, lim));
    uint8_t l9[9] = {};
    TEST_ASSERT_FALSE(decodeLimitsWrite(l9, 9, lim));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_decode_move);
    RUN_TEST(test_decode_gesture_and_bad_id);
    RUN_TEST(test_decode_rejects_bad_lengths);
    RUN_TEST(test_decode_unknown_type);
    RUN_TEST(test_decode_torque_and_set_limits);
    RUN_TEST(test_decode_save_cal_req);
    RUN_TEST(test_decode_simple_commands);
    RUN_TEST(test_encode_status_layout);
    RUN_TEST(test_encode_calibration_limits_info);
    RUN_TEST(test_decode_calibration_and_limits_write);
    return UNITY_END();
}
