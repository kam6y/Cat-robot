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
    private var firstActivityAt: TimeInterval?
    private var latestActivityAt: TimeInterval?

    var hasActivity: Bool {
        firstActivityAt != nil
    }

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    var silenceInterval: TimeInterval { configuration.silenceInterval }

    func flushDelay(at timestamp: TimeInterval) -> TimeInterval {
        let hardRemaining = max(
            0,
            configuration.maximumDuration - (timestamp - (firstActivityAt ?? timestamp))
        )
        return min(configuration.silenceInterval, hardRemaining)
    }

    mutating func receive(_ event: SpeechRecognitionEvent, at timestamp: TimeInterval) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        firstActivityAt = firstActivityAt ?? timestamp
        latestActivityAt = timestamp

        if event.isFinal {
            finalizedSegments.append(text)
        }
    }

    mutating func utteranceIfReady(at timestamp: TimeInterval) -> String? {
        guard let firstActivityAt else { return nil }

        let maximumDurationElapsed = timestamp >= firstActivityAt + configuration.maximumDuration
        guard !finalizedSegments.isEmpty else {
            if maximumDurationElapsed {
                reset()
            }
            return nil
        }

        guard let latestActivityAt else { return nil }
        let silenceElapsed = timestamp >= latestActivityAt + configuration.silenceInterval
        guard silenceElapsed || maximumDurationElapsed else { return nil }

        let utterance = finalizedSegments.joined()
        reset()
        return utterance
    }

    private mutating func reset() {
        finalizedSegments.removeAll(keepingCapacity: true)
        firstActivityAt = nil
        latestActivityAt = nil
    }
}
