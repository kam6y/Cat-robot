import AVFAudio
import Foundation

struct AudioSessionConfiguration: Equatable, Sendable {
    struct Port: Equatable, Sendable {
        var uid: String
        var type: String
        var dataSourceID: String?
        var channelNumbers: [Int]?
    }
    var sampleRate: Double
    var inputChannels: Int
    var outputChannels: Int
    var inputs: [Port]
    var outputs: [Port]
}

protocol AudioSessionDriving: AnyObject, Sendable {
    var notificationObject: AnyObject { get }
    var currentConfiguration: AudioSessionConfiguration { get }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions
    ) throws
}

actor AppleAudioSessionController: AudioSessionControlling {
    nonisolated var events: AsyncStream<AudioSessionEvent> {
        eventSource.makeStream()
    }

    private let session: any AudioSessionDriving
    /// 収録と再生が共有する engine。セッションが active な間だけ動かす（nil なら従来どおりセッションだけを扱う）。
    private let engine: ConversationAudioEngine?
    private nonisolated let eventSource: AudioSessionEventSource

    init(engine: ConversationAudioEngine? = nil) {
        self.init(
            session: LiveAudioSessionDriver(),
            notifications: .default,
            engine: engine
        )
    }

    init(
        session: any AudioSessionDriving,
        notifications: NotificationCenter,
        engine: ConversationAudioEngine? = nil
    ) {
        self.session = session
        self.engine = engine
        eventSource = AudioSessionEventSource(
            notifications: notifications,
            session: session,
            engine: engine
        )
    }

    /// セッションを active にしてから共有 engine を起動する。engine が起動できなければ会話の音声は成立しないので、
    /// セッションだけを active に残さず失敗にする。
    /// 音声会話: 収録と再生（duplex）。共有 engine は voice processing を有効にして起動する。
    func activate() async throws {
        try activate(mode: .duplex, category: .playAndRecord, options: [.defaultToSpeaker, .allowBluetoothHFP])
    }

    /// 一時停止中の文字入力の返答: 再生だけを有効にし、マイク（入力 I/O）を起動しない。
    func activatePlaybackOnly() async throws {
        try activate(mode: .playbackOnly, category: .playback, options: [])
    }

    private func activate(mode: ConversationAudioMode, category: AVAudioSession.Category,
                          options: AVAudioSession.CategoryOptions) throws {
        // モードが変わるなら、カテゴリを変える前に engine を止める（動いている engine の下でカテゴリを変えない）。
        if let engine, let current = engine.mode, current != mode { engine.deactivate() }
        do {
            try session.setCategory(category, mode: .default, options: options)
            try session.setActive(true, options: [])
        } catch {
            throw ConversationServiceError.audioSessionFailed
        }
        do {
            try engine?.activate(mode: mode)
            eventSource.captureConfiguration()
        } catch {
            try? session.setActive(false, options: [])
            throw ConversationServiceError.audioSessionFailed
        }
    }

    /// 共有 engine を止めてからセッションを手放す（セッション側が失敗しても engine は止める）。
    func deactivate() async {
        engine?.deactivate()
        try? session.setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        eventSource.clearConfiguration()
    }
}

private final class AudioSessionEventSource: @unchecked Sendable {
    private let lock = NSLock()
    private let notifications: NotificationCenter
    private let session: any AudioSessionDriving
    private let engine: ConversationAudioEngine?
    private var configuredAudio: AudioSessionConfiguration?
    private let eventHub = AudioSessionEventBroadcastHub()
    private var observation: AudioSessionNotificationObservation?

    init(
        notifications: NotificationCenter,
        session: any AudioSessionDriving,
        engine: ConversationAudioEngine?
    ) {
        self.notifications = notifications
        self.session = session
        self.engine = engine
    }

    func captureConfiguration() {
        let current = session.currentConfiguration
        lock.withLock { configuredAudio = current }
    }

    func clearConfiguration() {
        lock.withLock { configuredAudio = nil }
    }

    private func ignoresConfigurationChange() -> Bool {
        guard let engine else { return false }
        let current = session.currentConfiguration
        // Voice-processing startup/teardown can notify after the next capture has started.
        // Compare the effective configuration, not when the notification happened to arrive.
        if !engine.hasActiveAudioOwners {
            lock.withLock { configuredAudio = current }
            return true
        }
        let configured = lock.withLock { configuredAudio }
        return configured == current
    }

    func makeStream() -> AsyncStream<AudioSessionEvent> {
        let stream = eventHub.makeStream()
        lock.withLock {
            guard observation == nil else { return }
            observation = AudioSessionNotificationObservation(
                notifications: notifications,
                object: session.notificationObject,
                eventHub: eventHub,
                ignoresConfigurationChange: { [weak self] in self?.ignoresConfigurationChange() ?? false }
            )
        }
        return stream
    }

    deinit {
        observation = nil
        eventHub.finish()
    }
}

final class AudioSessionEventBroadcastHub: @unchecked Sendable {
    private struct Subscriber {
        let id: UUID
        let continuation: AsyncStream<AudioSessionEvent>.Continuation
    }

    private let lock = NSLock()
    private var subscribers: [Subscriber] = []
    private var isFinished = false

    var subscriberCount: Int {
        lock.withLock { subscribers.count }
    }

    func makeStream() -> AsyncStream<AudioSessionEvent> {
        let id = UUID()
        let pair = AsyncStream<AudioSessionEvent>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id: id)
        }

        let shouldFinish = lock.withLock {
            guard !isFinished else { return true }
            subscribers.append(.init(
                id: id,
                continuation: pair.continuation
            ))
            return false
        }
        if shouldFinish {
            pair.continuation.finish()
        }
        return pair.stream
    }

    func publish(_ event: AudioSessionEvent) {
        let continuations = lock.withLock {
            subscribers.map(\.continuation)
        }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    func finish() {
        let continuations = lock.withLock {
            guard !isFinished else {
                return [AsyncStream<AudioSessionEvent>.Continuation]()
            }
            isFinished = true
            let continuations = subscribers.map(\.continuation)
            subscribers.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeSubscriber(id: UUID) {
        lock.withLock {
            subscribers.removeAll { $0.id == id }
        }
    }
}

private final class AudioSessionNotificationObservation: @unchecked Sendable {
    private let notifications: NotificationCenter
    private let observerTokens: [NSObjectProtocol]

    init(
        notifications: NotificationCenter,
        object: AnyObject,
        eventHub: AudioSessionEventBroadcastHub,
        ignoresConfigurationChange: @escaping @Sendable () -> Bool
    ) {
        self.notifications = notifications
        observerTokens = [
            notifications.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: object,
                queue: nil
            ) { [eventHub] notification in
                guard let event = Self.interruptionEvent(from: notification) else {
                    return
                }
                eventHub.publish(event)
            },
            notifications.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: object,
                queue: nil
            ) { [eventHub] notification in
                guard Self.isPublishedRouteChange(notification) else { return }
                let reason = Self.unsignedInteger(notification.userInfo?[AVAudioSessionRouteChangeReasonKey])
                if reason == AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue,
                   ignoresConfigurationChange() { return }
                eventHub.publish(.routeChanged)
            },
        ]
    }

    deinit {
        for token in observerTokens {
            notifications.removeObserver(token)
        }
    }

    private static func interruptionEvent(
        from notification: Notification
    ) -> AudioSessionEvent? {
        guard let type = unsignedInteger(
            notification.userInfo?[AVAudioSessionInterruptionTypeKey]
        ) else {
            return nil
        }

        switch type {
        case AVAudioSession.InterruptionType.began.rawValue:
            return .interruptionBegan
        case AVAudioSession.InterruptionType.ended.rawValue:
            let optionsRawValue = unsignedInteger(
                notification.userInfo?[AVAudioSessionInterruptionOptionKey]
            ) ?? 0
            let options = AVAudioSession.InterruptionOptions(
                rawValue: optionsRawValue
            )
            return .interruptionEnded(
                shouldResume: options.contains(.shouldResume)
            )
        default:
            return nil
        }
    }

    private static func isPublishedRouteChange(
        _ notification: Notification
    ) -> Bool {
        guard let reason = unsignedInteger(
            notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
        ) else {
            return false
        }

        switch reason {
        case AVAudioSession.RouteChangeReason.categoryChange.rawValue:
            return false
        case AVAudioSession.RouteChangeReason.unknown.rawValue,
             AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
             AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
             AVAudioSession.RouteChangeReason.override.rawValue,
             AVAudioSession.RouteChangeReason.wakeFromSleep.rawValue,
             AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue,
             AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue:
            return true
        default:
            return false
        }
    }

    private static func unsignedInteger(_ value: Any?) -> UInt? {
        (value as? NSNumber)?.uintValue
    }
}

private final class LiveAudioSessionDriver: AudioSessionDriving {
    private let session: AVAudioSession

    var notificationObject: AnyObject { session }
    var currentConfiguration: AudioSessionConfiguration {
        let route = session.currentRoute
        return AudioSessionConfiguration(
            sampleRate: session.sampleRate,
            inputChannels: session.inputNumberOfChannels,
            outputChannels: session.outputNumberOfChannels,
            inputs: route.inputs.map(Self.port), outputs: route.outputs.map(Self.port)
        )
    }

    private static func port(_ port: AVAudioSessionPortDescription) -> AudioSessionConfiguration.Port {
        .init(uid: port.uid, type: port.portType.rawValue,
              dataSourceID: port.selectedDataSource?.dataSourceID.stringValue,
              channelNumbers: port.channels?.map { Int($0.channelNumber) })
    }

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        try session.setCategory(category, mode: mode, options: options)
    }

    func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions
    ) throws {
        try session.setActive(active, options: options)
    }
}
