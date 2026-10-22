#include "catneck/Supervisor.h"

#include <cmath>

namespace catneck {
namespace {

constexpr float kTargetEpsilon = 1e-6f;

uint8_t clampSpeedPercent(uint8_t speed) {
    if (speed == 0 || speed > 100) return 100;
    return speed;
}

bool sameCalibration(const CalBlob& a, const CalBlob& b) {
    return a.version == b.version && a.yawOffDeci == b.yawOffDeci && a.pitchOffDeci == b.pitchOffDeci &&
           a.invert == b.invert && a.yawGainCenti == b.yawGainCenti && a.pitchGainCenti == b.pitchGainCenti;
}

bool gainInRange(float gain) {
    return std::isfinite(gain) && gain >= config::kMinGain && gain <= config::kMaxGain;
}

int16_t toDeci(float deg) { return static_cast<int16_t>(std::lround(deg * 10.0f)); }

}  // namespace

uint16_t calBlobCrc(const CalBlob& blob) {
    const uint8_t bytes[10] = {
        blob.version,
        static_cast<uint8_t>(blob.yawOffDeci & 0xFF),
        static_cast<uint8_t>((blob.yawOffDeci >> 8) & 0xFF),
        static_cast<uint8_t>(blob.pitchOffDeci & 0xFF),
        static_cast<uint8_t>((blob.pitchOffDeci >> 8) & 0xFF),
        blob.invert,
        static_cast<uint8_t>(blob.yawGainCenti & 0xFF),
        static_cast<uint8_t>(blob.yawGainCenti >> 8),
        static_cast<uint8_t>(blob.pitchGainCenti & 0xFF),
        static_cast<uint8_t>(blob.pitchGainCenti >> 8),
    };
    uint16_t crc = 0xFFFF;
    for (uint8_t b : bytes) {
        crc ^= static_cast<uint16_t>(b) << 8;
        for (int i = 0; i < 8; ++i) {
            crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021) : static_cast<uint16_t>(crc << 1);
        }
    }
    return crc;
}

Supervisor::Supervisor(Storage& storage, uint32_t bootMillis, bool brownout)
    : storage_(storage),
      bootMillis_(bootMillis),
      brownout_(brownout),
      yaw_(kYawAbs, config::kYawDefaultVel),
      pitch_(kPitchAbs, config::kPitchDefaultVel) {
    CalBlob blob{};
    if (storage_.load(blob) && blob.version == kCalBlobVersion && blob.crc16 == calBlobCrc(blob)) {
        bool sat = false;
        yaw_.axis.setCalibration(blob.yawOffDeci / 10.0f, (blob.invert & 1) != 0, &sat);
        pitch_.axis.setCalibration(blob.pitchOffDeci / 10.0f, (blob.invert & 2) != 0, &sat);
        yaw_.axis.setGain(blob.yawGainCenti / 100.0f);
        pitch_.axis.setGain(blob.pitchGainCenti / 100.0f);
        savedBlob_ = blob;
        haveSaved_ = true;
    }
    // 位置検出が無いので、起動時は中立（キャリブレーション後）にいるものとして扱う
    yaw_.planner.reset(yaw_.axis.jointToServo(0.0f));
    pitch_.planner.reset(pitch_.axis.jointToServo(0.0f));
    applyPlannerVelocities();
}

// ---- イベント ------------------------------------------------------------------

void Supervisor::onCommand(const Command& command, Source source, uint32_t nowMillis) {
    (void)source;
    const bool stop = command.type == CommandType::Stop ||
                      (command.type == CommandType::Torque && !command.torque.on);
    if (state_ == SupervisorState::Boot) {
        if (stop) stopDuringBoot_ = true;  // それ以外は破棄（REJECTED にも通信にも数えない）
        return;
    }
    if (stop) {
        noteAccepted(false);
        handleStop(nowMillis);
        return;
    }
    bool saturated = false;
    switch (command.type) {
        case CommandType::Move:
        case CommandType::Center: {
            const float yawJoint = command.type == CommandType::Move ? command.move.yawDeci / 10.0f : 0.0f;
            const float pitchJoint = command.type == CommandType::Move ? command.move.pitchDeci / 10.0f : 0.0f;
            const uint8_t speed = command.type == CommandType::Move ? command.move.speed : command.center.speed;
            if (phase_ != GesturePhase::None) {
                hasPendingMove_ = true;
                pendingMoveYaw_ = yawJoint;
                pendingMovePitch_ = pitchJoint;
                pendingMoveSpeed_ = speed;
            } else {
                speedPercent_ = clampSpeedPercent(speed);
                acceptMotionRequest(nowMillis);
                applyPlannerVelocities();
                applyJointTargets(yawJoint, pitchJoint, &saturated);
                noteAccepted(saturated);
                return;
            }
            acceptMotionRequest(nowMillis);
            noteAccepted(false);
            return;
        }
        case CommandType::Gesture: {
            GestureSpec spec{};
            spec.id = command.gesture.id;
            spec.ampDeg = command.gesture.ampDeci / 10.0f;
            spec.repeats = command.gesture.repeats;
            spec.speedPercent = command.gesture.speed;
            const bool usesYaw = spec.id == GestureId::Shake || spec.id == GestureId::TiltL || spec.id == GestureId::TiltR;
            const bool usesPitch = spec.id != GestureId::Shake;
            const float pitchAmp = (spec.id == GestureId::TiltL || spec.id == GestureId::TiltR) ? spec.ampDeg * 0.5f : spec.ampDeg;
            saturated = (usesYaw && spec.ampDeg > yaw_.axis.limits().maxAngle) ||
                        (usesPitch && pitchAmp > pitch_.axis.limits().maxAngle);
            acceptMotionRequest(nowMillis);
            if (phase_ != GesturePhase::None) {
                hasPendingGesture_ = true;
                pendingGesture_ = spec;
            } else {
                startGesture(spec);
            }
            noteAccepted(saturated);
            return;
        }
        case CommandType::Torque:  // on == true
            acceptMotionRequest(nowMillis);
            noteAccepted(false);
            return;
        case CommandType::SetCal: {
            bool sat1 = false, sat2 = false;
            yaw_.axis.setCalibration(command.setCal.yawOffDeci / 10.0f, (command.setCal.invert & 1) != 0, &sat1);
            pitch_.axis.setCalibration(command.setCal.pitchOffDeci / 10.0f, (command.setCal.invert & 2) != 0, &sat2);
            acceptMotionRequest(nowMillis);
            reapplyJointTargets();  // 現在のジョイント目標を新しいキャリブレーションで言い直す（S 字で移る）
            noteAccepted(sat1 || sat2);
            return;
        }
        case CommandType::SaveCal:
            saveCalibration(command.saveCal.req, nowMillis);
            return;
        case CommandType::SetLimits: {
            bool sat1 = false, sat2 = false;
            const bool ok1 = yaw_.axis.setLimits(command.setLimits.yawAngDeci / 10.0f,
                                                 command.setLimits.yawVelDeci / 10.0f, &sat1);
            const bool ok2 = pitch_.axis.setLimits(command.setLimits.pitchAngDeci / 10.0f,
                                                   command.setLimits.pitchVelDeci / 10.0f, &sat2);
            if (!ok1 || !ok2) {
                onRejected();
                return;
            }
            acceptMaintenanceRequest(nowMillis);
            applyPlannerVelocities();
            reapplyJointTargets();  // 角度上限の再飽和
            noteAccepted(sat1 || sat2);
            return;
        }
        case CommandType::Ping:
            acceptMaintenanceRequest(nowMillis);
            pingSeq_ = command.ping.seq;
            noteAccepted(false);
            return;
        case CommandType::Stop:
            return;  // 上で処理済み
    }
}

void Supervisor::onRejected() {
    rejected_ = true;
    if (rejectedCount_ < 255) ++rejectedCount_;
}

void Supervisor::onLink(bool connected, uint32_t nowMillis) {
    linkUp_ = connected;
    if (!connected && state_ == SupervisorState::Active) enterState(SupervisorState::Returning, nowMillis);
}

void Supervisor::setPairOpen(bool open) { pairOpen_ = open; }

GainResult Supervisor::setGain(float yawUsPerDeg, float pitchUsPerDeg, uint32_t nowMillis) {
    if (state_ == SupervisorState::Boot) return GainResult::Rejected;  // BOOT 中の要求は破棄
    const bool inRange = gainInRange(yawUsPerDeg) && gainInRange(pitchUsPerDeg);
    const bool atRest = plannersAtRest() && phase_ == GesturePhase::None && !hasPendingGesture_ && !hasPendingMove_;
    if (!inRange || !atRest) {
        onRejected();
        return GainResult::Rejected;
    }
    AxisUnit* units[2] = {&yaw_, &pitch_};
    const float gains[2] = {yawUsPerDeg, pitchUsPerDeg};
    float factors[2];
    for (int i = 0; i < 2; ++i) {
        const float oldGain = units[i]->axis.calibration().gain;
        factors[i] = oldGain / gains[i];
        // 再表現後の現在位置をジョイント角に戻した値が設定上限内であること
        const float servo = units[i]->planner.state().pos * factors[i];
        if (std::fabs(units[i]->axis.servoToJoint(servo)) > units[i]->axis.limits().maxAngle + 1e-4f) {
            onRejected();
            return GainResult::Rejected;
        }
    }
    acceptMaintenanceRequest(nowMillis);
    noteAccepted(false);
    for (int i = 0; i < 2; ++i) {
        units[i]->planner.rescale(factors[i]);  // 出力 µs を保ったまま新ゲインの座標へ
        units[i]->axis.setGain(gains[i]);
    }
    reapplyJointTargets();  // 元のジョイント目標を新ゲインで言い直し、S 字で移る
    return persist() ? GainResult::Saved : GainResult::SaveFailed;
}

bool Supervisor::saveCalibration(uint8_t req, uint32_t nowMillis) {
    if (state_ == SupervisorState::Boot) return false;  // BOOT 中の要求は破棄
    if (req == 0) {
        onRejected();
        return false;
    }
    acceptMaintenanceRequest(nowMillis);
    noteAccepted(false);
    const bool ok = persist();
    lastSaveOk_ = ok;
    saveError_ = !ok;
    saveSeq_ = req;
    return ok;
}

// ---- tick --------------------------------------------------------------------

Outputs Supervisor::tick(uint32_t nowMillis) {
    switch (state_) {
        case SupervisorState::Boot:
            if (nowMillis - bootMillis_ >= config::kBootMuteMs) {
                enterState(stopDuringBoot_ ? SupervisorState::Idle : SupervisorState::BootCenter, nowMillis);
            }
            break;
        case SupervisorState::BootCenter:
            if (nowMillis - bootMillis_ >= config::kBootIdleMs) enterState(SupervisorState::Idle, nowMillis);
            break;
        case SupervisorState::Idle:
            break;
        case SupervisorState::Active:
            if (nowMillis - lastCommMillis_ >= config::kSilenceMs) enterState(SupervisorState::Returning, nowMillis);
            break;
        case SupervisorState::Returning:
            if (plannersAtRest()) {
                enterState(SupervisorState::RelaxWait, nowMillis);
            } else if (nowMillis - returnStartMillis_ >= config::kReturnDeadlineMs) {
                // 期限: 上限内で止まれる位置で止めてそこを保持する
                yaw_.planner.setTarget(yaw_.planner.brakingPoint());
                pitch_.planner.setTarget(pitch_.planner.brakingPoint());
                pitchHeld_ = false;
                enterState(SupervisorState::RelaxWait, nowMillis);
            }
            break;
        case SupervisorState::RelaxWait:
            if (nowMillis - relaxStartMillis_ >= config::kRelaxMs) enterState(SupervisorState::Idle, nowMillis);
            break;
    }

    serviceGesture();
    if (pitchHeld_) {
        if (pitchHoldTicks_ > 0) {
            --pitchHoldTicks_;
        } else {
            pitch_.planner.setTarget(pitchHeldTarget_);
            pitchHeld_ = false;
        }
    }
    yaw_.planner.step();
    pitch_.planner.step();

    Outputs out{};
    out.pwmEnabled = state_ == SupervisorState::BootCenter || state_ == SupervisorState::Active ||
                     state_ == SupervisorState::Returning || state_ == SupervisorState::RelaxWait;
    out.yawPulseUs = yaw_.axis.servoToPulseUs(yaw_.planner.state().pos);
    out.pitchPulseUs = pitch_.axis.servoToPulseUs(pitch_.planner.state().pos);
    return out;
}

// ---- 状態遷移 ------------------------------------------------------------------

void Supervisor::enterState(SupervisorState next, uint32_t nowMillis) {
    if (next == state_) return;
    state_ = next;
    switch (next) {
        case SupervisorState::Boot:
        case SupervisorState::BootCenter:
            break;
        case SupervisorState::Idle:
            discardMotion();
            freezePlanners();
            break;
        case SupervisorState::Active:
            applyPlannerVelocities();
            break;
        case SupervisorState::Returning: {
            discardMotion();
            returnStartMillis_ = nowMillis;
            applyPlannerVelocities();
            bool ignored = false;
            applyJointTargets(0.0f, 0.0f, &ignored);
            break;
        }
        case SupervisorState::RelaxWait:
            relaxStartMillis_ = nowMillis;
            break;
    }
}

bool Supervisor::acceptMotionRequest(uint32_t nowMillis) {
    lastCommMillis_ = nowMillis;
    if (state_ != SupervisorState::Active) enterState(SupervisorState::Active, nowMillis);
    return true;
}

void Supervisor::acceptMaintenanceRequest(uint32_t nowMillis) { lastCommMillis_ = nowMillis; }

void Supervisor::handleStop(uint32_t nowMillis) { enterState(SupervisorState::Idle, nowMillis); }

void Supervisor::noteAccepted(bool saturated) {
    rejected_ = false;
    saturated_ = saturated;
}

// ---- 目標と Planner ---------------------------------------------------------------

void Supervisor::applyJointTargets(float yawJoint, float pitchJoint, bool* saturated) {
    bool sat1 = false, sat2 = false;
    yaw_.jointTarget = yaw_.axis.clampJoint(yawJoint, &sat1);
    pitch_.jointTarget = pitch_.axis.clampJoint(pitchJoint, &sat2);
    *saturated = sat1 || sat2;
    setServoTargets(yaw_.axis.jointToServo(yaw_.jointTarget), pitch_.axis.jointToServo(pitch_.jointTarget));
}

void Supervisor::setServoTargets(float yawServo, float pitchServo) {
    const bool bothAtRest = plannersAtRest();
    const bool yawMoves = std::fabs(yawServo - yaw_.planner.state().pos) > kTargetEpsilon;
    const bool pitchMoves = std::fabs(pitchServo - pitch_.planner.state().pos) > kTargetEpsilon;
    yaw_.planner.setTarget(yawServo);
    if (bothAtRest && yawMoves && pitchMoves) {
        // 両軸が同時に静止から動き出す: ピッチを 3 tick 遅らせる（FW-PWR-1）
        pitchHeld_ = true;
        pitchHeldTarget_ = pitchServo;
        pitchHoldTicks_ = config::kStaggerTicks;
    } else if (pitchHeld_) {
        pitchHeldTarget_ = pitchServo;
    } else {
        pitch_.planner.setTarget(pitchServo);
    }
}

void Supervisor::reapplyJointTargets() {
    bool ignored = false;
    applyJointTargets(yaw_.jointTarget, pitch_.jointTarget, &ignored);
}

void Supervisor::applyPlannerVelocities() {
    if (state_ == SupervisorState::Returning || state_ == SupervisorState::RelaxWait) {
        yaw_.planner.setMaxVel(config::kReturnYawVel);
        pitch_.planner.setMaxVel(config::kReturnPitchVel);
        return;
    }
    const float factor = speedPercent_ / 100.0f;
    yaw_.planner.setMaxVel(yaw_.axis.limits().maxVel * factor);
    pitch_.planner.setMaxVel(pitch_.axis.limits().maxVel * factor);
}

void Supervisor::freezePlanners() {
    yaw_.planner.reset(yaw_.planner.state().pos);
    pitch_.planner.reset(pitch_.planner.state().pos);
    pitchHeld_ = false;
    yaw_.jointTarget = yaw_.axis.servoToJoint(yaw_.planner.state().pos);
    pitch_.jointTarget = pitch_.axis.servoToJoint(pitch_.planner.state().pos);
}

bool Supervisor::plannersAtRest() const {
    return yaw_.planner.atTarget() && pitch_.planner.atTarget() && !pitchHeld_;
}

// ---- 定型動作 ------------------------------------------------------------------
// 極値を経由する静止→静止の移動の列。各区切りは両軸が静止してから次へ進む。
// nod: 0 → −amp → +amp →（くり返し）→ 0、shake: 0 → +amp → −amp → … → 0
// tilt: (±amp, −amp/2) で 1.5 s 保持 → 0、look: (0, ±amp) で 2.0 s 保持 → 0

void Supervisor::buildGestureSteps(const GestureSpec& spec) {
    const uint8_t repeats = spec.repeats == 0 ? 1 : (spec.repeats > 3 ? 3 : spec.repeats);
    const float amp = spec.ampDeg;
    // speed は保持時間を 100/speed 倍に伸ばす（移動区間は Planner の速度上限を speed% に縮めて遅くする）
    const uint32_t speed = clampSpeedPercent(spec.speedPercent);
    const uint32_t kTiltHoldTicks = 1500 / config::kTickMs * 100 / speed;
    const uint32_t kLookHoldTicks = 2000 / config::kTickMs * 100 / speed;
    stepCount_ = 0;
    auto push = [this](float yaw, float pitch, uint32_t hold) {
        if (stepCount_ < kMaxGestureSteps) steps_[stepCount_++] = {yaw, pitch, hold};
    };
    switch (spec.id) {
        case GestureId::Nod:
            for (uint8_t i = 0; i < repeats; ++i) {
                push(0.0f, -amp, 0);
                push(0.0f, amp, 0);
            }
            push(0.0f, 0.0f, 0);
            break;
        case GestureId::Shake:
            for (uint8_t i = 0; i < repeats; ++i) {
                push(amp, 0.0f, 0);
                push(-amp, 0.0f, 0);
            }
            push(0.0f, 0.0f, 0);
            break;
        case GestureId::TiltL:
        case GestureId::TiltR: {
            const float yaw = spec.id == GestureId::TiltL ? amp : -amp;
            for (uint8_t i = 0; i < repeats; ++i) {
                push(yaw, -amp * 0.5f, kTiltHoldTicks);
                push(0.0f, 0.0f, 0);
            }
            break;
        }
        case GestureId::LookUp:
        case GestureId::LookDown: {
            const float pitch = spec.id == GestureId::LookUp ? amp : -amp;
            for (uint8_t i = 0; i < repeats; ++i) {
                push(0.0f, pitch, kLookHoldTicks);
                push(0.0f, 0.0f, 0);
            }
            break;
        }
    }
}

void Supervisor::startGesture(const GestureSpec& spec) {
    buildGestureSteps(spec);
    phase_ = GesturePhase::Centering;
    speedPercent_ = clampSpeedPercent(spec.speedPercent);
    applyPlannerVelocities();
    bool ignored = false;
    applyJointTargets(0.0f, 0.0f, &ignored);  // 起点は中立
}

void Supervisor::applyGestureStep() {
    const GestureStep& step = steps_[stepIndex_];
    holdRemaining_ = step.holdTicks;
    bool ignored = false;
    applyJointTargets(step.yaw, step.pitch, &ignored);
}

void Supervisor::serviceGesture() {
    if (phase_ == GesturePhase::Centering && plannersAtRest()) {
        phase_ = GesturePhase::Playing;
        stepIndex_ = 0;
        if (stepCount_ == 0) {
            phase_ = GesturePhase::None;
            finishGesture();
            return;
        }
        applyGestureStep();
        return;
    }
    if (phase_ != GesturePhase::Playing || !plannersAtRest()) return;
    if (holdRemaining_ > 0) {
        --holdRemaining_;
        return;
    }
    ++stepIndex_;
    if (stepIndex_ >= stepCount_) {
        phase_ = GesturePhase::None;
        finishGesture();
        return;
    }
    applyGestureStep();
}

void Supervisor::finishGesture() {
    if (hasPendingGesture_) {
        hasPendingGesture_ = false;
        startGesture(pendingGesture_);
        return;
    }
    if (hasPendingMove_) {
        hasPendingMove_ = false;
        speedPercent_ = clampSpeedPercent(pendingMoveSpeed_);
        applyPlannerVelocities();
        bool ignored = false;
        applyJointTargets(pendingMoveYaw_, pendingMovePitch_, &ignored);
    }
}

void Supervisor::discardMotion() {
    phase_ = GesturePhase::None;
    hasPendingGesture_ = false;
    hasPendingMove_ = false;
}

// ---- キャリブレーションの保存 --------------------------------------------------------

CalBlob Supervisor::currentBlob() const {
    CalBlob blob{};
    blob.version = kCalBlobVersion;
    blob.yawOffDeci = toDeci(yaw_.axis.calibration().offset);
    blob.pitchOffDeci = toDeci(pitch_.axis.calibration().offset);
    blob.invert = static_cast<uint8_t>((yaw_.axis.calibration().invert ? 1 : 0) |
                                       (pitch_.axis.calibration().invert ? 2 : 0));
    blob.yawGainCenti = static_cast<uint16_t>(std::lround(yaw_.axis.calibration().gain * 100.0f));
    blob.pitchGainCenti = static_cast<uint16_t>(std::lround(pitch_.axis.calibration().gain * 100.0f));
    blob.crc16 = calBlobCrc(blob);
    return blob;
}

bool Supervisor::isDirty() const { return !haveSaved_ || !sameCalibration(currentBlob(), savedBlob_); }

bool Supervisor::persist() {
    const CalBlob blob = currentBlob();
    if (haveSaved_ && sameCalibration(blob, savedBlob_)) return true;  // 同じなら書かない（NVS の摩耗を避ける）
    if (!storage_.save(blob)) return false;
    savedBlob_ = blob;
    haveSaved_ = true;
    return true;
}

// ---- 読み取り ------------------------------------------------------------------

Status Supervisor::status() const {
    Status st{};
    st.yawDeci = toDeci(yaw_.axis.servoToJoint(yaw_.planner.state().pos));
    st.pitchDeci = toDeci(pitch_.axis.servoToJoint(pitch_.planner.state().pos));
    const bool pwm = state_ == SupervisorState::BootCenter || state_ == SupervisorState::Active ||
                     state_ == SupervisorState::Returning || state_ == SupervisorState::RelaxWait;
    uint16_t flags = 0;
    if (linkUp_) flags |= StatusFlags::Link;
    if (pwm) flags |= StatusFlags::Torque;
    if (!plannersAtRest()) flags |= StatusFlags::Moving;
    if (brownout_) flags |= StatusFlags::Brownout;
    if (saturated_) flags |= StatusFlags::Saturated;
    if (isDirty()) flags |= StatusFlags::CalDirty;
    if (phase_ != GesturePhase::None || hasPendingGesture_) flags |= StatusFlags::Gesture;
    if (rejected_) flags |= StatusFlags::Rejected;
    if (state_ == SupervisorState::Returning || state_ == SupervisorState::RelaxWait) flags |= StatusFlags::Returning;
    if (pairOpen_) flags |= StatusFlags::PairOpen;
    if (saveError_) flags |= StatusFlags::SaveError;
    st.flags = flags;
    st.pingSeq = pingSeq_;
    st.state = state_;
    st.voltageCenti = 0;
    st.rejectedCount = rejectedCount_;
    st.saveSeq = saveSeq_;
    return st;
}

CalibrationData Supervisor::calibration() const {
    CalibrationData cal{};
    cal.yawOffDeci = toDeci(yaw_.axis.calibration().offset);
    cal.pitchOffDeci = toDeci(pitch_.axis.calibration().offset);
    cal.invert = static_cast<uint8_t>((yaw_.axis.calibration().invert ? 1 : 0) |
                                      (pitch_.axis.calibration().invert ? 2 : 0));
    cal.saved = !isDirty();
    return cal;
}

CalibrationSnapshot Supervisor::calibrationSnapshot() const {
    CalibrationSnapshot snap{};
    snap.yawOffset = yaw_.axis.calibration().offset;
    snap.pitchOffset = pitch_.axis.calibration().offset;
    snap.yawInvert = yaw_.axis.calibration().invert;
    snap.pitchInvert = pitch_.axis.calibration().invert;
    snap.yawGain = yaw_.axis.calibration().gain;
    snap.pitchGain = pitch_.axis.calibration().gain;
    snap.saved = !isDirty();
    return snap;
}

LimitsData Supervisor::limits() const {
    LimitsData lim{};
    lim.yawVelDeci = static_cast<uint16_t>(std::lround(yaw_.axis.limits().maxVel * 10.0f));
    lim.pitchVelDeci = static_cast<uint16_t>(std::lround(pitch_.axis.limits().maxVel * 10.0f));
    lim.yawAngDeci = toDeci(yaw_.axis.limits().maxAngle);
    lim.pitchAngDeci = toDeci(pitch_.axis.limits().maxAngle);
    return lim;
}

}  // namespace catneck
