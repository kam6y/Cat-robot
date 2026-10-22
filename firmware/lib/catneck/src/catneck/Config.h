// 首ファームウェアの数値定数。出典は設計書 §4.3〜§4.6（Global Constraints）。
#pragma once

#include <cstdint>

namespace catneck::config {

// 周期
constexpr uint32_t kTickMs = 20;
constexpr float kTickSeconds = 0.02f;

// 角度と速度（絶対上限・出荷既定）
constexpr float kYawMaxAngle = 60.0f;
constexpr float kPitchMaxAngle = 30.0f;
constexpr float kYawAbsVel = 180.0f;
constexpr float kPitchAbsVel = 120.0f;
constexpr float kYawDefaultVel = 120.0f;
constexpr float kPitchDefaultVel = 100.0f;
constexpr float kMinVel = 5.0f;
constexpr float kMinAngleLimit = 5.0f;
constexpr float kMaxOffset = 20.0f;

// サーボのパルス変換
constexpr float kDefaultGain = 11.11f;  // µs/°（DS3218 180° 仕様、500〜2500 µs）
constexpr float kMinGain = 5.0f;
constexpr float kMaxGain = 15.0f;
constexpr float kMinPulseUs = 500.0f;
constexpr float kMaxPulseUs = 2500.0f;
constexpr float kNeutralPulseUs = 1500.0f;

// 加速と 2 軸の開始ずらし
constexpr float kAccelTime = 0.2f;
constexpr uint32_t kStaggerTicks = 3;

// 安全状態機械の時間定数（ms）
constexpr uint32_t kBootMuteMs = 500;
constexpr uint32_t kBootIdleMs = 1500;
constexpr uint32_t kSilenceMs = 3000;
constexpr float kReturnYawVel = 90.0f;
constexpr float kReturnPitchVel = 60.0f;
constexpr uint32_t kReturnDeadlineMs = 2000;
constexpr uint32_t kRelaxMs = 2000;
constexpr uint32_t kStatusPeriodMs = 200;

// 版数
constexpr uint8_t kProtocolVersion = 1;
constexpr uint8_t kFwMajor = 0;
constexpr uint8_t kFwMinor = 1;
constexpr uint8_t kFwPatch = 0;
constexpr uint8_t kHwId = 1;

}  // namespace catneck::config
