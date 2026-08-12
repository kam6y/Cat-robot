import Foundation
import FoundationModels

struct FoundationModelAvailabilitySnapshot: Sendable {
    enum Availability: Sendable {
        case available
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
    }

    let availability: Availability
    let supportsLocale: Bool
}

struct FoundationModelAvailabilityService: ModelAvailabilityChecking {
    private let locale: Locale
    private let snapshot: @Sendable () -> FoundationModelAvailabilitySnapshot

    init(locale: Locale = Locale(identifier: "ja-JP")) {
        let model = SystemLanguageModel(useCase: .general, guardrails: .default)
        self.init(locale: locale) {
            let availability: FoundationModelAvailabilitySnapshot.Availability
            switch model.availability {
            case .available:
                availability = .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    availability = .deviceNotEligible
                case .appleIntelligenceNotEnabled:
                    availability = .appleIntelligenceNotEnabled
                case .modelNotReady:
                    availability = .modelNotReady
                @unknown default:
                    availability = .modelNotReady
                }
            }

            return FoundationModelAvailabilitySnapshot(
                availability: availability,
                supportsLocale: model.supportsLocale(locale)
            )
        }
    }

    init(
        locale: Locale,
        snapshot: @escaping @Sendable () -> FoundationModelAvailabilitySnapshot
    ) {
        self.locale = locale
        self.snapshot = snapshot
    }

    func availability() async -> ModelAvailability {
        let value = snapshot()
        guard value.supportsLocale else {
            return .unsupportedLocale
        }

        switch value.availability {
        case .available:
            return .available
        case .deviceNotEligible:
            return .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            return .appleIntelligenceNotEnabled
        case .modelNotReady:
            return .modelNotReady
        }
    }
}
