import AVFAudio
import Dispatch
import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class AppleAudioSessionControllerTests: XCTestCase {
    func testConstructionDefersNotificationObserversUntilEventsAreRequested() {
        let center = CountingNotificationCenter()
        let session = FakeAudioSession()
        let controller = AppleAudioSessionController(
            session: session,
            notifications: center
        )

        XCTAssertEqual(center.addObserverCallCount, 0)

        _ = controller.events

        XCTAssertEqual(center.addObserverCallCount, 2)
    }

    func testMultipleEventStreamsShareOneNotificationObservation() {
        let center = CountingNotificationCenter()
        let session = FakeAudioSession()
        let controller = AppleAudioSessionController(
            session: session,
            notifications: center
        )

        _ = controller.events
        _ = controller.events

        XCTAssertEqual(center.addObserverCallCount, 2)
    }

    func testActivateUsesPlayAndRecordDefaultModeSpeakerAndBluetoothHFP() async throws {
        let session = FakeAudioSession()
        let controller = AppleAudioSessionController(
            session: session,
            notifications: NotificationCenter()
        )

        try await controller.activate()

        XCTAssertEqual(session.categoryCalls, [
            .init(
                category: .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            ),
        ])
        XCTAssertEqual(session.activationCalls, [
            .init(isActive: true, options: []),
        ])
        XCTAssertTrue(session.isActive)
    }

    func testBlockingActivationLeavesMainActorResponsive() async throws {
        let activationGate = BlockingActivationGate()
        let session = FakeAudioSession(activationGate: activationGate)
        let controller = AppleAudioSessionController(
            session: session,
            notifications: NotificationCenter()
        )
        activationGate.releaseWhenMainActorProgressesOrTimesOut()

        let activation = Task {
            try await controller.activate()
        }
        let didEnterActivation = await eventually { activationGate.didEnter }
        XCTAssertTrue(didEnterActivation)
        activationGate.signalMainActorProgress()

        try await activation.value
        XCTAssertTrue(activationGate.progressPrecededRelease)
    }

    func testCategoryFailureMapsToAudioSessionFailureAndSkipsActivation() async {
        let session = FakeAudioSession(categoryShouldFail: true)
        let controller = AppleAudioSessionController(
            session: session,
            notifications: NotificationCenter()
        )

        do {
            try await controller.activate()
            XCTFail("Expected category configuration to fail")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .audioSessionFailed)
        }

        XCTAssertEqual(session.categoryCalls.count, 1)
        XCTAssertTrue(session.activationCalls.isEmpty)
        XCTAssertFalse(session.isActive)
    }

    func testActivationFailureMapsToAudioSessionFailure() async {
        let session = FakeAudioSession(activationShouldFail: true)
        let controller = AppleAudioSessionController(
            session: session,
            notifications: NotificationCenter()
        )

        do {
            try await controller.activate()
            XCTFail("Expected activation to fail")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .audioSessionFailed)
        }

        XCTAssertEqual(session.categoryCalls.count, 1)
        XCTAssertEqual(session.activationCalls, [
            .init(isActive: true, options: []),
        ])
        XCTAssertFalse(session.isActive)
    }

    func testDeactivateIsBestEffortAndNotifiesOtherSessions() async {
        let session = FakeAudioSession(deactivationShouldFail: true)
        let controller = AppleAudioSessionController(
            session: session,
            notifications: NotificationCenter()
        )

        await controller.deactivate()

        XCTAssertEqual(session.activationCalls, [
            .init(
                isActive: false,
                options: [.notifyOthersOnDeactivation]
            ),
        ])
    }

    func testInterruptionEventsStayOrderedAndNeverReactivateAutomatically() async throws {
        let center = NotificationCenter()
        let session = FakeAudioSession()
        let controller = AppleAudioSessionController(
            session: session,
            notifications: center
        )
        try await controller.activate()
        let events = controller.events

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue,
            ]
        )
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey:
                    AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )

        let received = try await collect(events, count: 2)
        XCTAssertEqual(received, [
            .interruptionBegan,
            .interruptionEnded(shouldResume: true),
        ])
        XCTAssertEqual(
            session.activationCalls.filter(\.isActive).count,
            1
        )
    }

    func testInterruptionEndWithoutOptionsPublishesShouldResumeFalse() async throws {
        let center = NotificationCenter()
        let session = FakeAudioSession()
        let controller = AppleAudioSessionController(
            session: session,
            notifications: center
        )
        let events = controller.events

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
            ]
        )

        let received = try await collect(events, count: 1)
        XCTAssertEqual(received, [.interruptionEnded(shouldResume: false)])
        XCTAssertTrue(session.activationCalls.isEmpty)
    }

    func testMalformedAndUnknownInterruptionTypesAreIgnored() async throws {
        let center = NotificationCenter()
        let session = FakeAudioSession()
        let controller = AppleAudioSessionController(
            session: session,
            notifications: center
        )
        let events = controller.events

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object
        )
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object,
            userInfo: [AVAudioSessionInterruptionTypeKey: "began"]
        )
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object,
            userInfo: [AVAudioSessionInterruptionTypeKey: UInt.max]
        )
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: session.object,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
            ]
        )

        let received = try await collect(events, count: 1)
        XCTAssertEqual(received, [.routeChanged])
    }

    func testCategoryAndMalformedRouteChangesAreIgnoredButPhysicalChangesPublish() async throws {
        let center = NotificationCenter()
        let session = FakeAudioSession()
        let controller = AppleAudioSessionController(
            session: session,
            notifications: center
        )
        let ignoredEvents = controller.events

        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: session.object,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.categoryChange.rawValue,
            ]
        )
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: session.object
        )
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: session.object,
            userInfo: [AVAudioSessionRouteChangeReasonKey: "new device"]
        )
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: session.object,
            userInfo: [AVAudioSessionRouteChangeReasonKey: UInt.max]
        )
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue,
            ]
        )

        let receivedAfterIgnoredChanges = try await collect(
            ignoredEvents,
            count: 1
        )
        XCTAssertEqual(receivedAfterIgnoredChanges, [.interruptionBegan])

        let physicalEvents = controller.events
        let physicalReasons: [AVAudioSession.RouteChangeReason] = [
            .unknown,
            .newDeviceAvailable,
            .oldDeviceUnavailable,
            .override,
            .wakeFromSleep,
            .noSuitableRouteForCategory,
            .routeConfigurationChange,
        ]
        for reason in physicalReasons {
            center.post(
                name: AVAudioSession.routeChangeNotification,
                object: session.object,
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
            )
        }

        let receivedPhysicalChanges = try await collect(
            physicalEvents,
            count: physicalReasons.count
        )
        XCTAssertEqual(
            receivedPhysicalChanges,
            Array(repeating: .routeChanged, count: physicalReasons.count)
        )
    }

    func testNotificationsFromAnotherSessionObjectAreIgnored() async throws {
        let center = NotificationCenter()
        let session = FakeAudioSession()
        let controller = AppleAudioSessionController(
            session: session,
            notifications: center
        )
        let events = controller.events

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: NSObject(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue,
            ]
        )
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
            ]
        )

        let received = try await collect(events, count: 1)
        XCTAssertEqual(received, [.interruptionEnded(shouldResume: false)])
    }

    func testSubscribersReceiveSameEventAndCancellationIsIsolated() async {
        let center = NotificationCenter()
        let session = FakeAudioSession()
        let controller = AppleAudioSessionController(
            session: session,
            notifications: center
        )
        let first = AudioEventCollector(stream: controller.events)
        let second = AudioEventCollector(stream: controller.events)

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue,
            ]
        )

        let didBroadcast = await eventually {
            first.events == [.interruptionBegan]
                && second.events == [.interruptionBegan]
        }
        XCTAssertTrue(didBroadcast)
        let didCancelFirst = await first.cancelAndWait()
        XCTAssertTrue(didCancelFirst)

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
            ]
        )

        let didKeepSecondSubscriber = await eventually {
            second.events == [
                .interruptionBegan,
                .interruptionEnded(shouldResume: false),
            ]
        }
        XCTAssertTrue(didKeepSecondSubscriber)
        XCTAssertEqual(first.events, [.interruptionBegan])
        let didCancelSecond = await second.cancelAndWait()
        XCTAssertTrue(didCancelSecond)
    }

    func testCancellingSubscriberRemovesOnlyItsBroadcastRegistration() async {
        let hub = AudioSessionEventBroadcastHub()
        let first = AudioEventCollector(stream: hub.makeStream())
        let second = AudioEventCollector(stream: hub.makeStream())
        XCTAssertEqual(hub.subscriberCount, 2)

        let didCancelFirst = await first.cancelAndWait()
        XCTAssertTrue(didCancelFirst)
        let didRemoveFirst = await eventually { hub.subscriberCount == 1 }
        XCTAssertTrue(didRemoveFirst)

        hub.publish(.routeChanged)
        let didReachSecond = await eventually {
            second.events == [.routeChanged]
        }
        XCTAssertTrue(didReachSecond)
        XCTAssertTrue(first.events.isEmpty)

        let didCancelSecond = await second.cancelAndWait()
        XCTAssertTrue(didCancelSecond)
        let didRemoveSecond = await eventually { hub.subscriberCount == 0 }
        XCTAssertTrue(didRemoveSecond)
    }

    func testControllerDeallocationRemovesObserversAndFinishesStreams() async {
        let center = CountingNotificationCenter()
        let session = FakeAudioSession()
        var controller: AppleAudioSessionController? = AppleAudioSessionController(
            session: session,
            notifications: center
        )
        weak var weakController = controller
        let collector = AudioEventCollector(stream: controller!.events)

        controller = nil

        let didReleaseController = await eventually { weakController == nil }
        XCTAssertTrue(didReleaseController)
        XCTAssertEqual(center.removeObserverCallCount, 2)
        let didFinishStream = await collector.waitUntilFinished()
        XCTAssertTrue(didFinishStream)

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: session.object,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue,
            ]
        )
        XCTAssertTrue(collector.events.isEmpty)
    }
}

private final class CountingNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAddObserverCallCount = 0
    private var storedRemoveObserverCallCount = 0

    var addObserverCallCount: Int {
        lock.withLock { storedAddObserverCallCount }
    }

    var removeObserverCallCount: Int {
        lock.withLock { storedRemoveObserverCallCount }
    }

    override func addObserver(
        forName name: NSNotification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @Sendable @escaping (Notification) -> Void
    ) -> any NSObjectProtocol {
        lock.withLock { storedAddObserverCallCount += 1 }
        return super.addObserver(
            forName: name,
            object: obj,
            queue: queue,
            using: block
        )
    }

    override func removeObserver(_ observer: Any) {
        lock.withLock { storedRemoveObserverCallCount += 1 }
        super.removeObserver(observer)
    }
}

private struct FakeCategoryCall: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
}

private struct FakeActivationCall: Equatable {
    let isActive: Bool
    let options: AVAudioSession.SetActiveOptions
}

private enum FakeAudioSessionError: Error {
    case categoryFailed
    case activationFailed
    case deactivationFailed
}

private final class FakeAudioSession: AudioSessionDriving, @unchecked Sendable {
    let object = NSObject()

    var notificationObject: AnyObject { object }

    private struct State {
        var categoryCalls: [FakeCategoryCall] = []
        var activationCalls: [FakeActivationCall] = []
        var isActive = false
    }

    private let lock = NSLock()
    private let categoryShouldFail: Bool
    private let activationShouldFail: Bool
    private let deactivationShouldFail: Bool
    private let activationGate: BlockingActivationGate?
    private var state = State()

    init(
        categoryShouldFail: Bool = false,
        activationShouldFail: Bool = false,
        deactivationShouldFail: Bool = false,
        activationGate: BlockingActivationGate? = nil
    ) {
        self.categoryShouldFail = categoryShouldFail
        self.activationShouldFail = activationShouldFail
        self.deactivationShouldFail = deactivationShouldFail
        self.activationGate = activationGate
    }

    var categoryCalls: [FakeCategoryCall] {
        lock.withLock { state.categoryCalls }
    }

    var activationCalls: [FakeActivationCall] {
        lock.withLock { state.activationCalls }
    }

    var isActive: Bool {
        lock.withLock { state.isActive }
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        state.categoryCalls.append(.init(
            category: category,
            mode: mode,
            options: options
        ))
        if categoryShouldFail {
            throw FakeAudioSessionError.categoryFailed
        }
    }

    func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions
    ) throws {
        lock.withLock {
            state.activationCalls.append(.init(
                isActive: active,
                options: options
            ))
        }
        if active {
            activationGate?.blockActivation()
        }
        if active, activationShouldFail {
            throw FakeAudioSessionError.activationFailed
        }
        if !active, deactivationShouldFail {
            throw FakeAudioSessionError.deactivationFailed
        }
        lock.withLock { state.isActive = active }
    }
}

private final class BlockingActivationGate: @unchecked Sendable {
    private struct State {
        var didEnter = false
        var progressPrecededRelease = false
    }

    private let lock = NSLock()
    private let mainActorProgress = DispatchSemaphore(value: 0)
    private let releaseActivation = DispatchSemaphore(value: 0)
    private var state = State()

    var didEnter: Bool {
        lock.withLock { state.didEnter }
    }

    var progressPrecededRelease: Bool {
        lock.withLock { state.progressPrecededRelease }
    }

    func releaseWhenMainActorProgressesOrTimesOut() {
        DispatchQueue.global().async { [self] in
            let result = mainActorProgress.wait(timeout: .now() + 2)
            lock.withLock {
                state.progressPrecededRelease = result == .success
            }
            releaseActivation.signal()
        }
    }

    func blockActivation() {
        lock.withLock { state.didEnter = true }
        releaseActivation.wait()
    }

    func signalMainActorProgress() {
        mainActorProgress.signal()
    }
}

@MainActor
private final class AudioEventCollector {
    private let recorder: AudioEventRecorder
    private let didFinish: XCTestExpectation
    private let didFinishAfterCancellation: XCTestExpectation
    private let task: Task<Void, Never>

    var events: [AudioSessionEvent] {
        recorder.events
    }

    init(
        stream: AsyncStream<AudioSessionEvent>,
        stopAfterCount: Int? = nil
    ) {
        let recorder = AudioEventRecorder()
        let didFinish = XCTestExpectation(description: "audio event collector finished")
        let didFinishAfterCancellation = XCTestExpectation(
            description: "cancelled audio event collector finished"
        )
        self.recorder = recorder
        self.didFinish = didFinish
        self.didFinishAfterCancellation = didFinishAfterCancellation
        task = Task { @MainActor in
            defer {
                didFinish.fulfill()
                didFinishAfterCancellation.fulfill()
            }
            for await event in stream {
                recorder.append(event)
                if let stopAfterCount,
                   recorder.events.count == stopAfterCount {
                    return
                }
            }
        }
    }

    func cancelAndWait(timeout: TimeInterval = 1) async -> Bool {
        task.cancel()
        return await waitUntilFinished(timeout: timeout)
    }

    func waitUntilFinished(timeout: TimeInterval = 1) async -> Bool {
        let result = await XCTWaiter.fulfillment(
            of: [didFinish],
            timeout: timeout
        )
        guard result == .completed else {
            task.cancel()
            let cleanupResult = await XCTWaiter.fulfillment(
                of: [didFinishAfterCancellation],
                timeout: 0.1
            )
            if cleanupResult == .completed {
                _ = await task.result
            }
            return false
        }
        _ = await task.result
        return true
    }
}

@MainActor
private final class AudioEventRecorder {
    private(set) var events: [AudioSessionEvent] = []

    func append(_ event: AudioSessionEvent) {
        events.append(event)
    }
}

private enum AudioEventCollectionError: Error {
    case timedOut
}

@MainActor
private func collect(
    _ stream: AsyncStream<AudioSessionEvent>,
    count: Int
) async throws -> [AudioSessionEvent] {
    let collector = AudioEventCollector(
        stream: stream,
        stopAfterCount: count
    )
    guard await collector.waitUntilFinished() else {
        throw AudioEventCollectionError.timedOut
    }
    return collector.events
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}
