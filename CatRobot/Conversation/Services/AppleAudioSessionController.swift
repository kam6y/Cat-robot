import AVFAudio
import Foundation

protocol AudioSessionDriving: AnyObject, Sendable {
    var notificationObject: AnyObject { get }

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
    private nonisolated let eventSource: AudioSessionEventSource

    init() {
        self.init(
            session: LiveAudioSessionDriver(),
            notifications: .default
        )
    }

    init(
        session: any AudioSessionDriving,
        notifications: NotificationCenter
    ) {
        self.session = session
        eventSource = AudioSessionEventSource(
            notifications: notifications,
            object: session.notificationObject
        )
    }

    func activate() async throws {
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: [])
        } catch {
            throw ConversationServiceError.audioSessionFailed
        }
    }

    func deactivate() async {
        try? session.setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}

private final class AudioSessionEventSource: @unchecked Sendable {
    private let lock = NSLock()
    private let notifications: NotificationCenter
    private let object: AnyObject
    private let eventHub = AudioSessionEventBroadcastHub()
    private var observation: AudioSessionNotificationObservation?

    init(
        notifications: NotificationCenter,
        object: AnyObject
    ) {
        self.notifications = notifications
        self.object = object
    }

    func makeStream() -> AsyncStream<AudioSessionEvent> {
        let stream = eventHub.makeStream()
        lock.withLock {
            guard observation == nil else { return }
            observation = AudioSessionNotificationObservation(
                notifications: notifications,
                object: object,
                eventHub: eventHub
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
        eventHub: AudioSessionEventBroadcastHub
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
