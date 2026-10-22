#include "catneck/Protocol.h"

namespace catneck {

namespace {

uint16_t readU16(const uint8_t* p) {
    return static_cast<uint16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8));
}

int16_t readI16(const uint8_t* p) {
    return static_cast<int16_t>(readU16(p));
}

void writeU16(uint8_t* p, uint16_t v) {
    p[0] = static_cast<uint8_t>(v & 0xFF);
    p[1] = static_cast<uint8_t>(v >> 8);
}

void writeI16(uint8_t* p, int16_t v) {
    writeU16(p, static_cast<uint16_t>(v));
}

// 種別ごとの固定長。未知の種別は 0。
size_t expectedLength(uint8_t type) {
    switch (static_cast<CommandType>(type)) {
        case CommandType::Move: return 6;
        case CommandType::Gesture: return 5;
        case CommandType::Stop: return 1;
        case CommandType::Center: return 2;
        case CommandType::Torque: return 2;
        case CommandType::SetCal: return 6;
        case CommandType::SaveCal: return 2;
        case CommandType::SetLimits: return 9;
        case CommandType::Ping: return 2;
    }
    return 0;
}

DecodeResult fail(DecodeError error) {
    DecodeResult r{};
    r.ok = false;
    r.error = error;
    return r;
}

}  // namespace

DecodeResult decodeCommand(const uint8_t* data, size_t len) {
    if (data == nullptr || len == 0) {
        return fail(DecodeError::Empty);
    }
    const size_t expected = expectedLength(data[0]);
    if (expected == 0) {
        return fail(DecodeError::UnknownType);
    }
    if (len != expected) {
        return fail(DecodeError::BadLength);
    }

    DecodeResult r{};
    r.ok = true;
    r.error = DecodeError::None;
    r.command.type = static_cast<CommandType>(data[0]);
    switch (r.command.type) {
        case CommandType::Move:
            r.command.move.yawDeci = readI16(data + 1);
            r.command.move.pitchDeci = readI16(data + 3);
            r.command.move.speed = data[5];
            break;
        case CommandType::Gesture:
            if (data[1] < 1 || data[1] > 6) {
                return fail(DecodeError::BadGestureId);
            }
            r.command.gesture.id = static_cast<GestureId>(data[1]);
            r.command.gesture.ampDeci = data[2];
            r.command.gesture.repeats = data[3];
            r.command.gesture.speed = data[4];
            break;
        case CommandType::Stop:
            break;
        case CommandType::Center:
            r.command.center.speed = data[1];
            break;
        case CommandType::Torque:
            if (data[1] > 1) {
                return fail(DecodeError::BadTorqueValue);
            }
            r.command.torque.on = data[1] == 1;
            break;
        case CommandType::SetCal:
            r.command.setCal.yawOffDeci = readI16(data + 1);
            r.command.setCal.pitchOffDeci = readI16(data + 3);
            r.command.setCal.invert = data[5];
            break;
        case CommandType::SaveCal:
            if (data[1] == 0) {
                return fail(DecodeError::BadSaveReq);
            }
            r.command.saveCal.req = data[1];
            break;
        case CommandType::SetLimits:
            r.command.setLimits.yawVelDeci = readU16(data + 1);
            r.command.setLimits.pitchVelDeci = readU16(data + 3);
            r.command.setLimits.yawAngDeci = readI16(data + 5);
            r.command.setLimits.pitchAngDeci = readI16(data + 7);
            if (r.command.setLimits.yawAngDeci < 0 || r.command.setLimits.pitchAngDeci < 0) {
                return fail(DecodeError::NegativeAngleLimit);
            }
            break;
        case CommandType::Ping:
            r.command.ping.seq = data[1];
            break;
    }
    return r;
}

void encodeStatus(const Status& status, uint8_t* out12) {
    writeI16(out12 + 0, status.yawDeci);
    writeI16(out12 + 2, status.pitchDeci);
    writeU16(out12 + 4, status.flags);
    out12[6] = status.pingSeq;
    out12[7] = static_cast<uint8_t>(status.state);
    writeU16(out12 + 8, status.voltageCenti);
    out12[10] = status.rejectedCount;
    out12[11] = status.saveSeq;
}

void encodeCalibration(const CalibrationData& cal, uint8_t* out6) {
    writeI16(out6 + 0, cal.yawOffDeci);
    writeI16(out6 + 2, cal.pitchOffDeci);
    out6[4] = cal.invert;
    out6[5] = cal.saved ? 1 : 0;
}

bool decodeCalibrationWrite(const uint8_t* data, size_t len, SetCalCmd& out) {
    if (data == nullptr || len != kCalibrationSize) {
        return false;
    }
    out.yawOffDeci = readI16(data + 0);
    out.pitchOffDeci = readI16(data + 2);
    out.invert = data[4];
    return true;
}

void encodeLimits(const LimitsData& limits, uint8_t* out8) {
    writeU16(out8 + 0, limits.yawVelDeci);
    writeU16(out8 + 2, limits.pitchVelDeci);
    writeI16(out8 + 4, limits.yawAngDeci);
    writeI16(out8 + 6, limits.pitchAngDeci);
}

bool decodeLimitsWrite(const uint8_t* data, size_t len, SetLimitsCmd& out) {
    if (data == nullptr || len != kLimitsSize) {
        return false;
    }
    out.yawVelDeci = readU16(data + 0);
    out.pitchVelDeci = readU16(data + 2);
    out.yawAngDeci = readI16(data + 4);
    out.pitchAngDeci = readI16(data + 6);
    return true;
}

void encodeInfo(const InfoData& info, uint8_t* out8) {
    out8[0] = info.protocol;
    out8[1] = info.major;
    out8[2] = info.minor;
    out8[3] = info.patch;
    out8[4] = info.hwId;
    out8[5] = info.caps;
    out8[6] = 0;
    out8[7] = 0;
}

}  // namespace catneck
