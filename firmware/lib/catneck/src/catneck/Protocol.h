// プロトコル版 1 の符号化・復号（設計書 §4.6）。多バイトはリトルエンディアン。
#pragma once

#include <cstddef>
#include <cstdint>

namespace catneck {

enum class CommandType : uint8_t {
    Move = 0x01,
    Gesture = 0x02,
    Stop = 0x03,
    Center = 0x04,
    Torque = 0x05,
    SetCal = 0x06,
    SaveCal = 0x07,
    SetLimits = 0x08,
    Ping = 0x09,
    GestureAt = 0x0A,
};

enum class GestureId : uint8_t {
    Nod = 1,
    Shake = 2,
    TiltL = 3,
    TiltR = 4,
    LookUp = 5,
    LookDown = 6,
};

struct MoveCmd {
    int16_t yawDeci;
    int16_t pitchDeci;
    uint8_t speed;
};
struct GestureCmd {
    GestureId id;
    uint8_t ampDeci;
    uint8_t repeats;
    uint8_t speed;
    int16_t yawCenterDeci;    // GestureAt only; legacy Gesture uses zero
    int16_t pitchCenterDeci;
};
struct CenterCmd {
    uint8_t speed;
};
struct TorqueCmd {
    bool on;
};
struct SetCalCmd {
    int16_t yawOffDeci;
    int16_t pitchOffDeci;
    uint8_t invert;
};
struct SaveCalCmd {
    uint8_t req;
};
struct SetLimitsCmd {
    uint16_t yawVelDeci;
    uint16_t pitchVelDeci;
    int16_t yawAngDeci;
    int16_t pitchAngDeci;
};
struct PingCmd {
    uint8_t seq;
};

struct Command {
    CommandType type;
    union {
        MoveCmd move;
        GestureCmd gesture;
        CenterCmd center;
        TorqueCmd torque;
        SetCalCmd setCal;
        SaveCalCmd saveCal;
        SetLimitsCmd setLimits;
        PingCmd ping;
    };
};

enum class DecodeError : uint8_t {
    None,
    Empty,
    UnknownType,
    BadLength,
    BadGestureId,
    BadTorqueValue,
    NegativeAngleLimit,
    BadSaveReq,
};

struct DecodeResult {
    bool ok;
    DecodeError error;
    Command command;
};

// Command 特性に書かれたバイト列を復号する。拒否の順序は 空 → 種別 → 長さ → 値。
DecodeResult decodeCommand(const uint8_t* data, size_t len);

namespace StatusFlags {
constexpr uint16_t Link = 1u << 0;
constexpr uint16_t Torque = 1u << 1;
constexpr uint16_t Moving = 1u << 2;
constexpr uint16_t Brownout = 1u << 3;
constexpr uint16_t Saturated = 1u << 4;
constexpr uint16_t CalDirty = 1u << 5;
constexpr uint16_t Gesture = 1u << 6;
constexpr uint16_t Rejected = 1u << 7;
constexpr uint16_t Returning = 1u << 8;
constexpr uint16_t PairOpen = 1u << 9;
constexpr uint16_t SaveError = 1u << 10;
}  // namespace StatusFlags

enum class SupervisorState : uint8_t {
    Boot = 0,
    BootCenter = 1,
    Idle = 2,
    Active = 3,
    Returning = 4,
    RelaxWait = 5,
};

struct Status {
    int16_t yawDeci;
    int16_t pitchDeci;
    uint16_t flags;
    uint8_t pingSeq;
    SupervisorState state;
    uint16_t voltageCenti;
    uint8_t rejectedCount;
    uint8_t saveSeq;
};
constexpr size_t kStatusSize = 12;
void encodeStatus(const Status& status, uint8_t* out12);

struct CalibrationData {
    int16_t yawOffDeci;
    int16_t pitchOffDeci;
    uint8_t invert;
    bool saved;
};
constexpr size_t kCalibrationSize = 6;
void encodeCalibration(const CalibrationData& cal, uint8_t* out6);
// Calibration 特性への Write（6 B のみ。saved 欄は無視）
bool decodeCalibrationWrite(const uint8_t* data, size_t len, SetCalCmd& out);

struct LimitsData {
    uint16_t yawVelDeci;
    uint16_t pitchVelDeci;
    int16_t yawAngDeci;
    int16_t pitchAngDeci;
};
constexpr size_t kLimitsSize = 8;
void encodeLimits(const LimitsData& limits, uint8_t* out8);
// Limits 特性への Write（8 B のみ）
bool decodeLimitsWrite(const uint8_t* data, size_t len, SetLimitsCmd& out);

namespace InfoCapabilities {
constexpr uint8_t AnchoredGesture = 1u << 1;
}

struct InfoData {
    uint8_t protocol;
    uint8_t major;
    uint8_t minor;
    uint8_t patch;
    uint8_t hwId;
    uint8_t caps;
};
constexpr size_t kInfoSize = 8;
void encodeInfo(const InfoData& info, uint8_t* out8);

}  // namespace catneck
