import Combine
import Foundation

@MainActor
final class FaceSizeTuningModel: ObservableObject {
    static let baselineScale = 0.85
    static let scaleRange = 0.5...1.0
    static let step = 0.005

    @Published private(set) var scale: Double
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: "faceScale") as? Double ?? Self.baselineScale
        scale = Self.normalized(stored)
    }

    func setScale(_ value: Double) {
        scale = Self.normalized(value)
        defaults.set(scale, forKey: "faceScale")
    }

    func reset() {
        setScale(Self.baselineScale)
    }

    var percentageText: String {
        String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), scale * 100)
    }

    var copyValue: String {
        let number = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), scale)
        return "顔サイズ: \(percentageText)\nConversationView.faceScale = \(number)"
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return baselineScale }
        let bounded = min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
        return (bounded * 200).rounded() / 200
    }
}
