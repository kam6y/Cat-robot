import Foundation

struct UtteranceSegmenter: Sendable {
    struct Configuration: Equatable, Sendable {
        var silenceInterval: TimeInterval
        var maximumDuration: TimeInterval

        init(
            silenceInterval: TimeInterval = 1.2,
            maximumDuration: TimeInterval = 20
        ) {
            self.silenceInterval = silenceInterval
            self.maximumDuration = maximumDuration
        }
    }

    private let configuration: Configuration
    private var finalizedSegments: [String] = []
    private var provisionalText: String?
    private var firstActivityAt: TimeInterval?
    private var latestActivityAt: TimeInterval?

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    mutating func receive(_ event: SpeechRecognitionEvent, at timestamp: TimeInterval) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        firstActivityAt = firstActivityAt ?? timestamp
        latestActivityAt = timestamp

        if event.isFinal {
            finalizedSegments.append(text)
            provisionalText = nil
        } else {
            provisionalText = text
        }
    }

    mutating func utteranceIfReady(at timestamp: TimeInterval) -> String? {
        guard
            !finalizedSegments.isEmpty,
            let firstActivityAt,
            let latestActivityAt
        else {
            return nil
        }

        let silenceElapsed = timestamp - latestActivityAt >= configuration.silenceInterval
        let maximumDurationElapsed = timestamp - firstActivityAt >= configuration.maximumDuration
        guard silenceElapsed || maximumDurationElapsed else { return nil }

        let utterance = finalizedSegments.joined()
        reset()
        return utterance
    }

    private mutating func reset() {
        finalizedSegments.removeAll(keepingCapacity: true)
        provisionalText = nil
        firstActivityAt = nil
        latestActivityAt = nil
    }
}
