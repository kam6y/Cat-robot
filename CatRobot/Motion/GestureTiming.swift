import Foundation

/// Budget estimates, not servo control. Constants and quantization follow firmware Gesture.cpp / Config.h.
enum GestureTiming {
    static func estimate(request: RobotMotionRequest, limits: RobotLimits, current: RobotStatus,
                         anchor: FacePose? = nil) -> TimeInterval {
        let yawVelocity = max(0.1, Double(limits.yawVelocityDeci) / 10)
        let pitchVelocity = max(0.1, Double(limits.pitchVelocityDeci) / 10)
        let isExpressive = request.gesture != .center && request.gesture != .lookAtUser
        let origin = isExpressive ? anchor : nil
        let centering = moveEstimate(yaw: Double(current.yawDeci) / 10 - (origin?.yaw ?? 0),
                                    pitch: Double(current.pitchDeci) / 10 - (origin?.pitch ?? 0),
                                    yawVelocity: yawVelocity, pitchVelocity: pitchVelocity)
        // Firmware may shrink an anchored waveform near limits; requested amplitude gives a conservative budget.
        let amplitude = Double(request.amplitudeDeci) / 10
        let base: Double, ramp: Double, yaw: Double, pitch: Double
        switch request.gesture {
        case .nod: (base, ramp, yaw, pitch) = (1, 1, 0, amplitude)
        case .shake: (base, ramp, yaw, pitch) = (1, 1, amplitude, 0)
        case .tilt: (base, ramp, yaw, pitch) = (2.3, 0.4, amplitude, amplitude * 0.5)
        case .lookUp, .lookDown: (base, ramp, yaw, pitch) = (4, 1, 0, amplitude)
        case .lookAtUser, .center: return max(0.02, centering)
        }
        let sine = request.gesture == .nod || request.gesture == .shake
        let peaks: (Double, Double, Double) = sine ? (9.673596609, 83.142789030, 954.745716690) : (1.875, 5.7735, 60)
        let stretch = max(stretch(amplitude: yaw, velocity: yawVelocity, ramp: ramp, peaks: peaks),
                          stretch(amplitude: pitch, velocity: pitchVelocity, ramp: ramp, peaks: peaks))
        // Firmware rounds the waveform length to 20 ms, then drains the three delayed pitch samples.
        let waveform = (base * stretch / 0.02).rounded() * 0.02 + 0.06
        return centering + waveform
    }

    private static func stretch(amplitude: Double, velocity: Double, ramp: Double,
                                peaks: (Double, Double, Double)) -> Double {
        let v = amplitude * peaks.0 / ramp
        let a = amplitude * peaks.1 / (ramp * ramp)
        let j = amplitude * peaks.2 / (ramp * ramp * ramp)
        return max(1, v / velocity, sqrt(a / (10 * velocity)), cbrt(j / (100 * velocity)))
    }

    private static func moveEstimate(yaw: Double, pitch: Double, yawVelocity: Double, pitchVelocity: Double) -> Double {
        // Rest-to-rest duration for the fixed A=10V, J=100V caps. No trajectory samples or Planner are reproduced.
        func axis(_ distance: Double, velocity: Double) -> Double {
            let distance = abs(distance)
            guard distance > 0.000_001 else { return 0 }
            return distance >= 0.2 * velocity ? distance / velocity + 0.2 : 4 * cbrt(distance / (200 * velocity))
        }
        let yawTime = axis(yaw, velocity: yawVelocity)
        let pitchTime = axis(pitch, velocity: pitchVelocity) + (abs(yaw) > 0.000_001 && abs(pitch) > 0.000_001 ? 0.06 : 0)
        return ceil(max(yawTime, pitchTime) / 0.02) * 0.02
    }
}
