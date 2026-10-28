#include "catneck/SerialParser.h"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "catneck/Config.h"

namespace catneck {
namespace {

constexpr size_t kMaxLine = 160;
constexpr size_t kMaxTokens = 24;
constexpr size_t kMaxHexBytes = 20;

const char* const kBadArgs = "BAD_ARGS";
const char* const kUnknown = "UNKNOWN";
const char* const kRange = "RANGE";

ParsedLine makeError(const char* error) {
    ParsedLine p{};
    p.kind = ParsedLine::Kind::Error;
    p.error = error;
    return p;
}

ParsedLine makeAction(ConsoleAction action) {
    ParsedLine p{};
    p.kind = ParsedLine::Kind::Action;
    p.action = action;
    return p;
}

ParsedLine makeCommand(const Command& command) {
    ParsedLine p{};
    p.kind = ParsedLine::Kind::Command;
    p.command = command;
    return p;
}

bool equalsIgnoreCase(const char* a, const char* b) {
    for (;; ++a, ++b) {
        int ca = std::toupper(static_cast<unsigned char>(*a));
        int cb = std::toupper(static_cast<unsigned char>(*b));
        if (ca != cb) return false;
        if (ca == '\0') return true;
    }
}

// 10 進の実数（符号・小数可）。トークン全体を消費しなければ失敗。
bool parseFloat(const char* tok, float* out) {
    if (*tok == '\0') return false;
    char* end = nullptr;
    double v = std::strtod(tok, &end);
    if (end == tok || *end != '\0' || !std::isfinite(v)) return false;
    *out = static_cast<float>(v);
    return true;
}

// 度 → 0.1° 単位（四捨五入）。lo..hi の範囲外は失敗。
bool parseDeci(const char* tok, long lo, long hi, long* out) {
    float v = 0.0f;
    if (!parseFloat(tok, &v)) return false;
    double d = std::round(static_cast<double>(v) * 10.0);
    if (d < static_cast<double>(lo) || d > static_cast<double>(hi)) return false;
    *out = static_cast<long>(d);
    return true;
}

// 符号なし整数。lo..hi の範囲外は失敗。
bool parseUInt(const char* tok, unsigned long lo, unsigned long hi, unsigned long* out) {
    if (*tok == '\0' || !std::isdigit(static_cast<unsigned char>(*tok))) return false;
    char* end = nullptr;
    unsigned long v = std::strtoul(tok, &end, 10);
    if (end == tok || *end != '\0' || v < lo || v > hi) return false;
    *out = v;
    return true;
}

bool parseGestureId(const char* tok, GestureId* out) {
    struct Name {
        const char* name;
        GestureId id;
    };
    static const Name kNames[] = {
        {"nod", GestureId::Nod},        {"shake", GestureId::Shake},
        {"tilt_l", GestureId::TiltL},   {"tilt_r", GestureId::TiltR},
        {"look_up", GestureId::LookUp}, {"look_down", GestureId::LookDown},
    };
    for (const Name& n : kNames) {
        if (equalsIgnoreCase(tok, n.name)) {
            *out = n.id;
            return true;
        }
    }
    unsigned long v = 0;
    if (!parseUInt(tok, 1, 6, &v)) return false;
    *out = static_cast<GestureId>(v);
    return true;
}

int hexValue(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

const char* decodeErrorName(DecodeError e) {
    switch (e) {
        case DecodeError::None: return "NONE";
        case DecodeError::Empty: return "EMPTY";
        case DecodeError::UnknownType: return "UNKNOWN_TYPE";
        case DecodeError::BadLength: return "BAD_LENGTH";
        case DecodeError::BadGestureId: return "BAD_GESTURE_ID";
        case DecodeError::BadTorqueValue: return "BAD_TORQUE_VALUE";
        case DecodeError::NegativeAngleLimit: return "NEGATIVE_ANGLE_LIMIT";
        case DecodeError::BadSaveReq: return "BAD_SAVE_REQ";
    }
    return "UNKNOWN_ERROR";
}

// HEX の引数（空白区切りでも連結でもよい）をバイト列に戻し、BLE と同じ復号器に通す。
ParsedLine parseHex(char** tokens, size_t count) {
    uint8_t bytes[kMaxHexBytes];
    size_t n = 0;
    int pending = -1;
    for (size_t i = 0; i < count; ++i) {
        for (const char* p = tokens[i]; *p != '\0'; ++p) {
            int v = hexValue(*p);
            if (v < 0) return makeError(kBadArgs);
            if (pending < 0) {
                pending = v;
            } else {
                if (n >= kMaxHexBytes) return makeError(kBadArgs);
                bytes[n++] = static_cast<uint8_t>((pending << 4) | v);
                pending = -1;
            }
        }
    }
    if (pending >= 0 || n == 0) return makeError(kBadArgs);
    DecodeResult r = decodeCommand(bytes, n);
    if (!r.ok) return makeError(decodeErrorName(r.error));
    return makeCommand(r.command);
}

ParsedLine parseMove(char** args, size_t count) {
    if (count < 2 || count > 3) return makeError(kBadArgs);
    long yaw = 0, pitch = 0;
    unsigned long speed = 0;
    if (!parseDeci(args[0], INT16_MIN, INT16_MAX, &yaw)) return makeError(kBadArgs);
    if (!parseDeci(args[1], INT16_MIN, INT16_MAX, &pitch)) return makeError(kBadArgs);
    if (count == 3 && !parseUInt(args[2], 0, 255, &speed)) return makeError(kBadArgs);
    Command c{};
    c.type = CommandType::Move;
    c.move.yawDeci = static_cast<int16_t>(yaw);
    c.move.pitchDeci = static_cast<int16_t>(pitch);
    c.move.speed = static_cast<uint8_t>(speed);
    return makeCommand(c);
}

ParsedLine parseGesture(char** args, size_t count) {
    if (count < 2 || count > 4) return makeError(kBadArgs);
    GestureId id;
    if (!parseGestureId(args[0], &id)) return makeError(kBadArgs);
    long amp = 0;
    if (!parseDeci(args[1], 0, 100000, &amp)) return makeError(kBadArgs);
    if (amp > 255) amp = 255;  // uint8 の上限 25.5° で飽和（角度上限の飽和は Supervisor 側）
    unsigned long repeats = 1, speed = 0;
    if (count >= 3 && !parseUInt(args[2], 0, 255, &repeats)) return makeError(kBadArgs);
    if (count == 4 && !parseUInt(args[3], 0, 255, &speed)) return makeError(kBadArgs);
    Command c{};
    c.type = CommandType::Gesture;
    c.gesture.id = id;
    c.gesture.ampDeci = static_cast<uint8_t>(amp);
    c.gesture.repeats = static_cast<uint8_t>(repeats);
    c.gesture.speed = static_cast<uint8_t>(speed);
    return makeCommand(c);
}

ParsedLine parseOptionalByte(CommandType type, char** args, size_t count) {
    if (count > 1) return makeError(kBadArgs);
    unsigned long v = 0;
    if (count == 1 && !parseUInt(args[0], 0, 255, &v)) return makeError(kBadArgs);
    Command c{};
    c.type = type;
    switch (type) {
        case CommandType::Center: c.center.speed = static_cast<uint8_t>(v); break;
        case CommandType::Ping: c.ping.seq = static_cast<uint8_t>(v); break;
        case CommandType::SaveCal: c.saveCal.req = static_cast<uint8_t>(v); break;
        default: return makeError(kUnknown);
    }
    return makeCommand(c);
}

ParsedLine parseTorque(char** args, size_t count) {
    unsigned long v = 0;
    if (count != 1 || !parseUInt(args[0], 0, 1, &v)) return makeError(kBadArgs);
    Command c{};
    c.type = CommandType::Torque;
    c.torque.on = v == 1;
    return makeCommand(c);
}

ParsedLine parseCal(char** args, size_t count) {
    if (count != 3) return makeError(kBadArgs);
    long yaw = 0, pitch = 0;
    unsigned long invert = 0;
    if (!parseDeci(args[0], INT16_MIN, INT16_MAX, &yaw)) return makeError(kBadArgs);
    if (!parseDeci(args[1], INT16_MIN, INT16_MAX, &pitch)) return makeError(kBadArgs);
    if (!parseUInt(args[2], 0, 3, &invert)) return makeError(kBadArgs);
    Command c{};
    c.type = CommandType::SetCal;
    c.setCal.yawOffDeci = static_cast<int16_t>(yaw);
    c.setCal.pitchOffDeci = static_cast<int16_t>(pitch);
    c.setCal.invert = static_cast<uint8_t>(invert);
    return makeCommand(c);
}

ParsedLine parseLimits(char** args, size_t count) {
    if (count != 4) return makeError(kBadArgs);
    long v[4];
    if (!parseDeci(args[0], 0, UINT16_MAX, &v[0])) return makeError(kBadArgs);
    if (!parseDeci(args[1], 0, UINT16_MAX, &v[1])) return makeError(kBadArgs);
    // 負の角度上限は BLE の復号器と同じく拒否する
    if (!parseDeci(args[2], 0, INT16_MAX, &v[2])) return makeError(kBadArgs);
    if (!parseDeci(args[3], 0, INT16_MAX, &v[3])) return makeError(kBadArgs);
    Command c{};
    c.type = CommandType::SetLimits;
    c.setLimits.yawVelDeci = static_cast<uint16_t>(v[0]);
    c.setLimits.pitchVelDeci = static_cast<uint16_t>(v[1]);
    c.setLimits.yawAngDeci = static_cast<int16_t>(v[2]);
    c.setLimits.pitchAngDeci = static_cast<int16_t>(v[3]);
    return makeCommand(c);
}

ParsedLine parseGain(char** args, size_t count) {
    if (count != 2) return makeError(kBadArgs);
    float yaw = 0.0f, pitch = 0.0f;
    if (!parseFloat(args[0], &yaw) || !parseFloat(args[1], &pitch)) return makeError(kBadArgs);
    if (yaw < config::kMinGain || yaw > config::kMaxGain || pitch < config::kMinGain ||
        pitch > config::kMaxGain) {
        return makeError(kRange);
    }
    ParsedLine p = makeAction(ConsoleAction::Gain);
    p.gainYaw = yaw;
    p.gainPitch = pitch;
    return p;
}

ParsedLine parseWord(const char* expected, ConsoleAction action, char** args, size_t count) {
    if (count != 1 || !equalsIgnoreCase(args[0], expected)) return makeError(kBadArgs);
    return makeAction(action);
}

ParsedLine parseStop() {
    Command c{};
    c.type = CommandType::Stop;
    return makeCommand(c);
}

}  // namespace

ParsedLine parseLine(const char* line, size_t len) {
    if (line == nullptr || len >= kMaxLine) return makeError(kBadArgs);
    char buf[kMaxLine];
    std::memcpy(buf, line, len);
    buf[len] = '\0';

    char* tokens[kMaxTokens];
    size_t count = 0;
    char* p = buf;
    while (*p != '\0') {
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') ++p;
        if (*p == '\0') break;
        if (count >= kMaxTokens) return makeError(kBadArgs);
        tokens[count++] = p;
        while (*p != '\0' && *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n') ++p;
        if (*p != '\0') *p++ = '\0';
    }
    if (count == 0) return makeError(kUnknown);

    const char* verb = tokens[0];
    char** args = tokens + 1;
    size_t argc = count - 1;

    if (equalsIgnoreCase(verb, "MOVE")) return parseMove(args, argc);
    if (equalsIgnoreCase(verb, "GESTURE")) return parseGesture(args, argc);
    if (equalsIgnoreCase(verb, "STOP")) return argc == 0 ? parseStop() : makeError(kBadArgs);
    if (equalsIgnoreCase(verb, "CENTER")) return parseOptionalByte(CommandType::Center, args, argc);
    if (equalsIgnoreCase(verb, "TORQUE")) return parseTorque(args, argc);
    if (equalsIgnoreCase(verb, "PING")) return parseOptionalByte(CommandType::Ping, args, argc);
    if (equalsIgnoreCase(verb, "CAL")) return parseCal(args, argc);
    if (equalsIgnoreCase(verb, "SAVE")) return parseOptionalByte(CommandType::SaveCal, args, argc);
    if (equalsIgnoreCase(verb, "LIMITS")) return parseLimits(args, argc);
    if (equalsIgnoreCase(verb, "GAIN")) return parseGain(args, argc);
    if (equalsIgnoreCase(verb, "HEX")) return parseHex(args, argc);
    if (equalsIgnoreCase(verb, "STATUS")) return argc == 0 ? makeAction(ConsoleAction::Status) : makeError(kBadArgs);
    if (equalsIgnoreCase(verb, "INFO")) return argc == 0 ? makeAction(ConsoleAction::Info) : makeError(kBadArgs);
    if (equalsIgnoreCase(verb, "HELP")) return argc == 0 ? makeAction(ConsoleAction::Help) : makeError(kBadArgs);
    if (equalsIgnoreCase(verb, "WATCH")) {
        if (argc == 1 && equalsIgnoreCase(args[0], "ON")) return makeAction(ConsoleAction::WatchOn);
        if (argc == 1 && equalsIgnoreCase(args[0], "OFF")) return makeAction(ConsoleAction::WatchOff);
        return makeError(kBadArgs);
    }
    if (equalsIgnoreCase(verb, "BONDS")) return parseWord("CLEAR", ConsoleAction::BondsClear, args, argc);
    if (equalsIgnoreCase(verb, "PAIR")) return parseWord("OPEN", ConsoleAction::PairOpen, args, argc);
    return makeError(kUnknown);
}

namespace {
// 0.1° 単位 → "-12.3" のような文字列（符号は整数部が 0 でも付く）
void formatDeci(int16_t deci, char* out, size_t cap) {
    int v = deci;
    const char* sign = v < 0 ? "-" : "";
    if (v < 0) v = -v;
    std::snprintf(out, cap, "%s%d.%d", sign, v / 10, v % 10);
}
}  // namespace

size_t formatStatusLine(const Status& status, char* out, size_t cap) {
    if (out == nullptr || cap == 0) return 0;
    char yaw[12], pitch[12];
    formatDeci(status.yawDeci, yaw, sizeof yaw);
    formatDeci(status.pitchDeci, pitch, sizeof pitch);
    int n = std::snprintf(out, cap, "STATUS yaw=%s pitch=%s flags=0x%04X seq=%u state=%u err=%u save=%u", yaw,
                          pitch, static_cast<unsigned>(status.flags), static_cast<unsigned>(status.pingSeq),
                          static_cast<unsigned>(status.state), static_cast<unsigned>(status.rejectedCount),
                          static_cast<unsigned>(status.saveSeq));
    if (n < 0) {
        out[0] = '\0';
        return 0;
    }
    size_t written = static_cast<size_t>(n);
    return written < cap ? written : cap - 1;
}

}  // namespace catneck
