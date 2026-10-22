#pragma once

#include <array>
#include <cstddef>

namespace catneck {

struct PlannerState {
    float pos;
    float vel;
    float acc;
};

// Servo-angle trajectory. The caller clamps joint targets before conversion.
class Planner {
public:
    explicit Planner(float dtSeconds = 0.02f);
    void reset(float pos);
    void setTarget(float pos);
    // A decrease retains the effective old limits until a jerk-limited stop;
    // repeated calls with the same requested cap do not restart that transition.
    void setMaxVel(float v);
    // Effective limits (old limits during a decrease transition).
    float maxVel() const;
    float maxAcc() const;
    float maxJerk() const;
    // Calibration-only operation: ignored unless already at rest, factor > 0.
    void rescale(float factor);
    const PlannerState& step();
    const PlannerState& state() const;
    float target() const;
    bool atTarget() const;
    float brakingPoint() const;

private:
    struct Segment {
        double seconds = 0.0;
        double jerk = 0.0;
    };
    struct Motion {
        double pos = 0.0;
        double vel = 0.0;
        double acc = 0.0;
    };
    struct Path {
        std::array<Segment, 10> segments{};
        std::size_t count = 0;
        Motion end;
    };

    static void integrate(Motion& state, double jerk, double seconds);
    static void append(Path& path, double jerk, double seconds);
    void changeVelocity(Path& path, double velocity) const;
    Path stopPath() const;
    Path throughVelocity(Motion start, double velocity, double coast = 0.0) const;
    Path movePath(Motion start, double target) const;
    void replan();
    void publish();

    double dt_;
    double target_ = 0.0;
    double limit_ = 100.0;
    double requestedLimit_ = 100.0;
    Motion motion_;
    PlannerState state_{0.0f, 0.0f, 0.0f};
    Path path_;
    std::size_t segment_ = 0;
    double remaining_ = 0.0;
    bool transitioning_ = false;
};

}  // namespace catneck
