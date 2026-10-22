#include "catneck/Planner.h"

#include <algorithm>
#include <cmath>

#include "catneck/Config.h"

namespace catneck {
namespace {
constexpr double kTimeEpsilon = 1e-12;
constexpr double kRestEpsilon = 1e-10;

double direction(double value) { return value < 0.0 ? -1.0 : 1.0; }
}  // namespace

Planner::Planner(float dtSeconds)
    : dt_(std::isfinite(dtSeconds) && dtSeconds > 0.0f ? dtSeconds : config::kTickSeconds) {}

void Planner::reset(float pos) {
    if (!std::isfinite(pos)) return;
    motion_ = {pos, 0.0, 0.0};
    target_ = pos;
    limit_ = requestedLimit_;
    transitioning_ = false;
    replan();
    publish();
}

void Planner::setTarget(float pos) {
    if (!std::isfinite(pos) || target_ == pos) return;
    target_ = pos;
    replan();
}

void Planner::setMaxVel(float v) {
    if (!std::isfinite(v) || v <= 0.0f || requestedLimit_ == v) return;
    requestedLimit_ = v;
    if (v < limit_ && (std::fabs(motion_.vel) > kRestEpsilon ||
                       std::fabs(motion_.acc) > kRestEpsilon)) {
        // A full stop is a valid new-cap entry (v=0, a=0). With A=10V,
        // J=100V, even the worst viable initial acceleration stops in <=0.3s,
        // no later than (Vold-Vnew)/A + 3A/J. Keep old A/J until that point.
        transitioning_ = true;
    } else {
        limit_ = v;
        transitioning_ = false;
    }
    replan();
}

float Planner::maxVel() const { return static_cast<float>(limit_); }
float Planner::maxAcc() const { return static_cast<float>(2.0 * limit_ / config::kAccelTime); }
float Planner::maxJerk() const {
    const double time = config::kAccelTime;
    return static_cast<float>(4.0 * limit_ / (time * time));
}

void Planner::rescale(float factor) {
    if (!std::isfinite(factor) || factor <= 0.0f || motion_.vel != 0.0 || motion_.acc != 0.0) return;
    motion_.pos *= factor;
    target_ *= factor;
    replan();
    publish();
}

void Planner::integrate(Motion& state, double jerk, double seconds) {
    state.pos += state.vel * seconds + state.acc * seconds * seconds / 2.0
                 + jerk * seconds * seconds * seconds / 6.0;
    state.vel += state.acc * seconds + jerk * seconds * seconds / 2.0;
    state.acc += jerk * seconds;
}

void Planner::append(Path& path, double jerk, double seconds) {
    if (seconds <= kTimeEpsilon) return;
    // At most 3 stop phases + 7 rest-to-rest phases; no dynamic allocation.
    path.segments[path.count++] = {seconds, jerk};
    integrate(path.end, jerk, seconds);
}

void Planner::changeVelocity(Path& path, double velocity) const {
    const double acceleration = maxAcc();
    const double jerk = maxJerk();
    const double delta = velocity - path.end.vel;
    const double initial = path.end.acc;
    if (std::fabs(delta) < kRestEpsilon && std::fabs(initial) < kRestEpsilon) return;

    // Canceling a alone changes v by a*|a|/(2J). Choose the side of that
    // boundary, then solve the triangular/trapezoidal acceleration area.
    const double sign = direction(delta - initial * std::fabs(initial) / (2.0 * jerk));
    const double a = sign * initial;
    const double dv = sign * delta;
    const double peak = std::min(acceleration, std::sqrt(std::max(0.0, jerk * dv + a * a / 2.0)));
    const double hold = peak > kRestEpsilon
        ? std::max(0.0, (dv - (2.0 * peak * peak - a * a) / (2.0 * jerk)) / peak)
        : 0.0;
    append(path, sign * jerk, std::max(0.0, (peak - a) / jerk));
    append(path, 0.0, hold);
    append(path, -sign * jerk, peak / jerk);
    path.end.vel = velocity;
    path.end.acc = 0.0;
}

Planner::Path Planner::stopPath() const {
    Path path;
    path.end = motion_;
    changeVelocity(path, 0.0);
    return path;
}

Planner::Path Planner::throughVelocity(Motion start, double velocity, double coast) const {
    Path path;
    path.end = start;
    changeVelocity(path, velocity);
    append(path, 0.0, coast);
    changeVelocity(path, 0.0);
    return path;
}

Planner::Path Planner::movePath(Motion start, double target) const {
    Path stop;
    stop.end = start;
    changeVelocity(stop, 0.0);
    const double sign = direction(std::fabs(start.vel) > kRestEpsilon ? start.vel :
                                  std::fabs(start.acc) > kRestEpsilon ? start.acc : target - start.pos);

    if (sign * (target - stop.end.pos) < -1e-9) {
        // Retarget inside the braking distance: keep the original stop point,
        // then reverse. New targets cannot extend the excursion in this direction.
        const Path returning = movePath(stop.end, target);
        for (std::size_t i = 0; i < returning.count; ++i) {
            append(stop, returning.segments[i].jerk, returning.segments[i].seconds);
        }
        stop.end = returning.end;
        return stop;
    }

    const double distance = sign * (target - start.pos);
    Path path = throughVelocity(start, sign * limit_);
    const double fullDistance = sign * (path.end.pos - start.pos);
    if (fullDistance <= distance) {
        path = throughVelocity(start, sign * limit_, (distance - fullDistance) / limit_);
    } else {
        // The endpoint is monotonic in the cruise velocity. The low endpoint
        // is the minimum stop; the high endpoint uses the velocity cap.
        const double positiveAcc = std::max(0.0, sign * start.acc);
        double low = positiveAcc > 0.0
            ? std::max(0.0, sign * start.vel + positiveAcc * positiveAcc / (2.0 * maxJerk()))
            : 0.0;
        double high = limit_;
        for (int i = 0; i < 48; ++i) {
            const double middle = (low + high) / 2.0;
            const Path candidate = throughVelocity(start, sign * middle);
            if (sign * (candidate.end.pos - start.pos) < distance) low = middle;
            else high = middle;
        }
        path = throughVelocity(start, sign * ((low + high) / 2.0));
    }
    // The analytic trajectory ends at rest; only floating point roundoff is
    // corrected here, never a near-target velocity/acceleration truncation.
    path.end = {target, 0.0, 0.0};
    return path;
}

void Planner::replan() {
    path_ = transitioning_ ? stopPath() : movePath(motion_, target_);
    segment_ = 0;
    remaining_ = path_.count == 0 ? 0.0 : path_.segments[0].seconds;
}

void Planner::publish() {
    state_ = {static_cast<float>(motion_.pos), static_cast<float>(motion_.vel),
              static_cast<float>(motion_.acc)};
}

const PlannerState& Planner::step() {
    double time = dt_;
    while (time > kTimeEpsilon) {
        if (segment_ == path_.count) {
            motion_ = path_.end;
            if (!transitioning_) break;
            limit_ = requestedLimit_;
            transitioning_ = false;
            replan();
            continue;
        }
        const double elapsed = std::min(time, remaining_);
        integrate(motion_, path_.segments[segment_].jerk, elapsed);
        time -= elapsed;
        remaining_ -= elapsed;
        if (remaining_ <= kTimeEpsilon) {
            ++segment_;
            if (segment_ < path_.count) remaining_ = path_.segments[segment_].seconds;
            else motion_ = path_.end;
        }
    }
    publish();
    return state_;
}

const PlannerState& Planner::state() const { return state_; }
float Planner::target() const { return static_cast<float>(target_); }
bool Planner::atTarget() const {
    return !transitioning_ && segment_ == path_.count && motion_.pos == target_
           && motion_.vel == 0.0 && motion_.acc == 0.0;
}
float Planner::brakingPoint() const { return static_cast<float>(stopPath().end.pos); }
}  // namespace catneck
