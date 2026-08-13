import Foundation
import OSLog

struct ConversationLatencyToken: Hashable, Sendable {
    let rawValue: UUID
}

enum ConversationLatencyPath: UInt8, Hashable, Sendable {
    case fast
    case classified
}

enum ConversationLatencyCancellation: UInt8, Hashable, Sendable {
    case unselectedPath
    case noResponse
    case ambiguous
    case failure
    case lifecycle
    case typedReplacement
    case shutdown
}

enum ConversationLatencyMetric: UInt8, CaseIterable, Hashable, Sendable {
    case fastFirstCaption
    case classifiedFirstCaption
    case fastSpeechStart
    case classifiedSpeechStart
}

struct ConversationLatencySignpostContext: Equatable, Sendable {
    let turnID: UInt64
    let boundaryAt: TimeInterval
    var lastASRActivityAt: TimeInterval?
    let segmentationInterval: TimeInterval
}

enum ConversationLatencySignpostOutcome: Equatable, Sendable {
    case success
    case cancelled(ConversationLatencyCancellation)
}

struct ConversationLatencySignpostHandle: Hashable, Sendable {
    let rawValue: UUID
}

@MainActor
protocol ConversationLatencyTracking: AnyObject, Sendable {
    func beginVoiceTurn(
        turnID: UInt64,
        boundaryAt: TimeInterval,
        lastASRActivityAt: TimeInterval?,
        segmentationInterval: TimeInterval
    ) -> ConversationLatencyToken

    func noteASRActivity(
        at timestamp: TimeInterval,
        for token: ConversationLatencyToken
    )

    func selectPath(
        _ path: ConversationLatencyPath,
        for token: ConversationLatencyToken,
        at timestamp: TimeInterval
    )

    func firstCaptionVisible(
        for token: ConversationLatencyToken,
        at timestamp: TimeInterval
    )

    func speechStarted(
        for token: ConversationLatencyToken,
        at timestamp: TimeInterval
    )

    func cancel(
        _ token: ConversationLatencyToken,
        reason: ConversationLatencyCancellation,
        at timestamp: TimeInterval
    )
}

@MainActor
protocol ConversationLatencySignposting: AnyObject, Sendable {
    func begin(
        _ metric: ConversationLatencyMetric,
        context: ConversationLatencySignpostContext
    ) -> ConversationLatencySignpostHandle

    func end(
        _ handle: ConversationLatencySignpostHandle,
        metric: ConversationLatencyMetric,
        context: ConversationLatencySignpostContext,
        outcome: ConversationLatencySignpostOutcome,
        at timestamp: TimeInterval
    )
}

@MainActor
final class ConversationLatencyTracker: ConversationLatencyTracking {
    private struct ActiveTurn {
        var context: ConversationLatencySignpostContext
        let handles: [ConversationLatencyMetric: ConversationLatencySignpostHandle]
        var remainingMetrics: Set<ConversationLatencyMetric>
        var selectedPath: ConversationLatencyPath?
    }

    private let signposts: any ConversationLatencySignposting
    private var activeTurns: [ConversationLatencyToken: ActiveTurn] = [:]

    init(signposts: any ConversationLatencySignposting) {
        self.signposts = signposts
    }

    static func live() -> ConversationLatencyTracker {
        ConversationLatencyTracker(signposts: OSConversationLatencySignposter())
    }

    func beginVoiceTurn(
        turnID: UInt64,
        boundaryAt: TimeInterval,
        lastASRActivityAt: TimeInterval?,
        segmentationInterval: TimeInterval
    ) -> ConversationLatencyToken {
        let token = ConversationLatencyToken(rawValue: UUID())
        let context = ConversationLatencySignpostContext(
            turnID: turnID,
            boundaryAt: boundaryAt,
            lastASRActivityAt: lastASRActivityAt,
            segmentationInterval: segmentationInterval
        )
        let handles = Dictionary(
            uniqueKeysWithValues: ConversationLatencyMetric.allCases.map { metric in
                (metric, signposts.begin(metric, context: context))
            }
        )

        activeTurns[token] = ActiveTurn(
            context: context,
            handles: handles,
            remainingMetrics: Set(ConversationLatencyMetric.allCases),
            selectedPath: nil
        )
        return token
    }

    func noteASRActivity(
        at timestamp: TimeInterval,
        for token: ConversationLatencyToken
    ) {
        guard var turn = activeTurns[token] else { return }
        turn.context.lastASRActivityAt = timestamp
        activeTurns[token] = turn
    }

    func selectPath(
        _ path: ConversationLatencyPath,
        for token: ConversationLatencyToken,
        at timestamp: TimeInterval
    ) {
        guard var turn = activeTurns[token], turn.selectedPath == nil else { return }
        turn.selectedPath = path

        for metric in metrics(for: alternatePath(to: path)) {
            end(
                metric,
                in: &turn,
                outcome: .cancelled(.unselectedPath),
                at: timestamp
            )
        }

        store(turn, for: token)
    }

    func firstCaptionVisible(
        for token: ConversationLatencyToken,
        at timestamp: TimeInterval
    ) {
        guard var turn = activeTurns[token], let path = turn.selectedPath else { return }
        end(firstCaptionMetric(for: path), in: &turn, outcome: .success, at: timestamp)
        store(turn, for: token)
    }

    func speechStarted(
        for token: ConversationLatencyToken,
        at timestamp: TimeInterval
    ) {
        guard var turn = activeTurns[token], let path = turn.selectedPath else { return }
        end(speechStartMetric(for: path), in: &turn, outcome: .success, at: timestamp)
        store(turn, for: token)
    }

    func cancel(
        _ token: ConversationLatencyToken,
        reason: ConversationLatencyCancellation,
        at timestamp: TimeInterval
    ) {
        guard var turn = activeTurns.removeValue(forKey: token) else { return }

        for metric in ConversationLatencyMetric.allCases {
            end(metric, in: &turn, outcome: .cancelled(reason), at: timestamp)
        }
    }

    private func store(_ turn: ActiveTurn, for token: ConversationLatencyToken) {
        if turn.remainingMetrics.isEmpty {
            activeTurns[token] = nil
        } else {
            activeTurns[token] = turn
        }
    }

    private func end(
        _ metric: ConversationLatencyMetric,
        in turn: inout ActiveTurn,
        outcome: ConversationLatencySignpostOutcome,
        at timestamp: TimeInterval
    ) {
        guard turn.remainingMetrics.remove(metric) != nil,
              let handle = turn.handles[metric] else { return }

        signposts.end(
            handle,
            metric: metric,
            context: turn.context,
            outcome: outcome,
            at: timestamp
        )
    }

    private func alternatePath(to path: ConversationLatencyPath) -> ConversationLatencyPath {
        switch path {
        case .fast:
            .classified
        case .classified:
            .fast
        }
    }

    private func metrics(for path: ConversationLatencyPath) -> [ConversationLatencyMetric] {
        [firstCaptionMetric(for: path), speechStartMetric(for: path)]
    }

    private func firstCaptionMetric(
        for path: ConversationLatencyPath
    ) -> ConversationLatencyMetric {
        switch path {
        case .fast:
            .fastFirstCaption
        case .classified:
            .classifiedFirstCaption
        }
    }

    private func speechStartMetric(
        for path: ConversationLatencyPath
    ) -> ConversationLatencyMetric {
        switch path {
        case .fast:
            .fastSpeechStart
        case .classified:
            .classifiedSpeechStart
        }
    }
}

@MainActor
private final class OSConversationLatencySignposter: ConversationLatencySignposting {
    private struct ActiveInterval {
        let metric: ConversationLatencyMetric
        let state: OSSignpostIntervalState
    }

    private let signposter: OSSignposter
    private var activeIntervals: [ConversationLatencySignpostHandle: ActiveInterval] = [:]

    init() {
        signposter = OSSignposter(
            subsystem: Bundle.main.bundleIdentifier ?? "com.kamby.CatRobot",
            category: "ConversationLatency"
        )
    }

    func begin(
        _ metric: ConversationLatencyMetric,
        context: ConversationLatencySignpostContext
    ) -> ConversationLatencySignpostHandle {
        let handle = ConversationLatencySignpostHandle(rawValue: UUID())
        let signpostID = signposter.makeSignpostID()
        let lastASRActivityAt = context.lastASRActivityAt ?? -1
        let state: OSSignpostIntervalState

        switch metric {
        case .fastFirstCaption:
            state = signposter.beginInterval(
                "FastPathFirstCaption",
                id: signpostID,
                "turnID=\(context.turnID) boundaryAt=\(context.boundaryAt) lastASRActivityAt=\(lastASRActivityAt) segmentationInterval=\(context.segmentationInterval)"
            )
        case .classifiedFirstCaption:
            state = signposter.beginInterval(
                "ClassifiedFirstCaption",
                id: signpostID,
                "turnID=\(context.turnID) boundaryAt=\(context.boundaryAt) lastASRActivityAt=\(lastASRActivityAt) segmentationInterval=\(context.segmentationInterval)"
            )
        case .fastSpeechStart:
            state = signposter.beginInterval(
                "FastPathSpeechStart",
                id: signpostID,
                "turnID=\(context.turnID) boundaryAt=\(context.boundaryAt) lastASRActivityAt=\(lastASRActivityAt) segmentationInterval=\(context.segmentationInterval)"
            )
        case .classifiedSpeechStart:
            state = signposter.beginInterval(
                "ClassifiedSpeechStart",
                id: signpostID,
                "turnID=\(context.turnID) boundaryAt=\(context.boundaryAt) lastASRActivityAt=\(lastASRActivityAt) segmentationInterval=\(context.segmentationInterval)"
            )
        }

        activeIntervals[handle] = ActiveInterval(metric: metric, state: state)
        return handle
    }

    func end(
        _ handle: ConversationLatencySignpostHandle,
        metric: ConversationLatencyMetric,
        context: ConversationLatencySignpostContext,
        outcome: ConversationLatencySignpostOutcome,
        at timestamp: TimeInterval
    ) {
        guard let interval = activeIntervals.removeValue(forKey: handle),
              interval.metric == metric else { return }

        let lastASRActivityAt = context.lastASRActivityAt ?? -1
        let elapsedFromBoundary = timestamp - context.boundaryAt
        let elapsedFromASR = timestamp - lastASRActivityAt
        let outcomeCode = outcome.signpostCode

        switch metric {
        case .fastFirstCaption:
            signposter.endInterval(
                "FastPathFirstCaption",
                interval.state,
                "turnID=\(context.turnID) at=\(timestamp) boundaryAt=\(context.boundaryAt) lastASRActivityAt=\(lastASRActivityAt) segmentationInterval=\(context.segmentationInterval) elapsedFromBoundary=\(elapsedFromBoundary) elapsedFromASR=\(elapsedFromASR) outcome=\(outcomeCode)"
            )
        case .classifiedFirstCaption:
            signposter.endInterval(
                "ClassifiedFirstCaption",
                interval.state,
                "turnID=\(context.turnID) at=\(timestamp) boundaryAt=\(context.boundaryAt) lastASRActivityAt=\(lastASRActivityAt) segmentationInterval=\(context.segmentationInterval) elapsedFromBoundary=\(elapsedFromBoundary) elapsedFromASR=\(elapsedFromASR) outcome=\(outcomeCode)"
            )
        case .fastSpeechStart:
            signposter.endInterval(
                "FastPathSpeechStart",
                interval.state,
                "turnID=\(context.turnID) at=\(timestamp) boundaryAt=\(context.boundaryAt) lastASRActivityAt=\(lastASRActivityAt) segmentationInterval=\(context.segmentationInterval) elapsedFromBoundary=\(elapsedFromBoundary) elapsedFromASR=\(elapsedFromASR) outcome=\(outcomeCode)"
            )
        case .classifiedSpeechStart:
            signposter.endInterval(
                "ClassifiedSpeechStart",
                interval.state,
                "turnID=\(context.turnID) at=\(timestamp) boundaryAt=\(context.boundaryAt) lastASRActivityAt=\(lastASRActivityAt) segmentationInterval=\(context.segmentationInterval) elapsedFromBoundary=\(elapsedFromBoundary) elapsedFromASR=\(elapsedFromASR) outcome=\(outcomeCode)"
            )
        }
    }
}

private extension ConversationLatencySignpostOutcome {
    var signpostCode: UInt64 {
        switch self {
        case .success:
            0
        case .cancelled(let reason):
            UInt64(reason.rawValue) + 1
        }
    }
}
