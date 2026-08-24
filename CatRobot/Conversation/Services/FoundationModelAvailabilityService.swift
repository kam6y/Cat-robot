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

enum FoundationModelAvailabilityPurpose: Equatable, Sendable {
    case contentTagging
}

struct FoundationModelAvailabilityService: ModelAvailabilityChecking {
    private let locale: Locale
    private let snapshot: @Sendable () -> FoundationModelAvailabilitySnapshot

    init(locale: Locale = Locale(identifier: "ja-JP")) {
        self.init(locale: locale, purpose: .contentTagging) { purpose in
            let model: SystemLanguageModel
            switch purpose {
            case .contentTagging:
                model = SystemLanguageModel(useCase: .contentTagging, guardrails: .default)
            }

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
        purpose: FoundationModelAvailabilityPurpose = .contentTagging,
        snapshotForPurpose: @escaping @Sendable (FoundationModelAvailabilityPurpose) -> FoundationModelAvailabilitySnapshot
    ) {
        self.locale = locale
        snapshot = { snapshotForPurpose(purpose) }
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
