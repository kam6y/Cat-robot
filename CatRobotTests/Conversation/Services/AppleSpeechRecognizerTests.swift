import Foundation
import Speech
import XCTest
@testable import CatRobot

final class AppleSpeechRecognizerTests: XCTestCase {
    func testStartForwardsUntrimmedProgressiveAndFinalResultsWithoutClosingAtFinal() async throws {
        let driver = FakeSpeechCaptureDriver(results: [
            .init(text: " こん。", isFinal: false),
            .init(text: "こんにちは。 ", isFinal: true),
            .init(text: "次", isFinal: false),
        ])
        let recognizer = makeRecognizer(driverFactory: { driver })

        let stream = try await recognizer.start()
        var events: [SpeechRecognitionEvent] = []
        for try await event in stream {
            events.append(event)
            if events.count == 3 { break }
        }

        XCTAssertEqual(events, [
            SpeechRecognitionEvent(text: " こん。", isFinal: false),
            SpeechRecognitionEvent(text: "こんにちは。 ", isFinal: true),
            SpeechRecognitionEvent(text: "次", isFinal: false),
        ])
        await recognizer.stop()
    }

    func testNormalStopFlushesThenFinalizesAndDrainsResultsWithoutCancellation() async throws {
        let driver = FakeSpeechCaptureDriver()
        let recognizer = makeRecognizer(driverFactory: { driver })
        let stream = try await recognizer.start()

        await recognizer.stop()
        _ = stream

        let calls = await driver.calls
        XCTAssertEqual(calls, [
            .prepare, .installTap, .beginAnalysis, .startEngine,
            .removeTap, .stopEngine, .resetEngine,
            .flushConverter, .finishInput, .finalizeAnalyzer, .drainResults,
        ])
        let immediateTeardownCount = await driver.immediateTeardownCount
        XCTAssertEqual(immediateTeardownCount, 0)
    }

    func testSecondStartDoesNotCreateParallelCapture() async throws {
        let factory = FakeSpeechCaptureDriverFactory()
        let recognizer = makeRecognizer(driverFactory: factory.make)
        let stream = try await recognizer.start()

        do {
            _ = try await recognizer.start()
            XCTFail("Expected a second capture to be rejected")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureAlreadyRunning)
        }

        XCTAssertEqual(factory.creationCount, 1)
        await recognizer.stop()
        _ = stream
    }

    func testPrepareDoesNotInstallTapOrStartEngineAndIsIdempotent() async throws {
        let driver = FakeSpeechCaptureDriver()
        let recognizer = makeRecognizer(driverFactory: { driver })

        try await recognizer.prepare()
        try await recognizer.prepare()

        let calls = await driver.calls
        XCTAssertEqual(calls, [.prepare])
    }

    func testPreparedDriverIsReusedForStartWithoutPreparingTwice() async throws {
        let driver = FakeSpeechCaptureDriver()
        let recognizer = makeRecognizer(driverFactory: { driver })

        try await recognizer.prepare()
        let stream = try await recognizer.start()

        let calls = await driver.calls
        XCTAssertEqual(calls, [.prepare, .installTap, .beginAnalysis, .startEngine])
        await recognizer.stop()
        _ = stream
    }

    func testStartAfterStopCreatesAndPreparesFreshDriver() async throws {
        let first = FakeSpeechCaptureDriver()
        let second = FakeSpeechCaptureDriver()
        let factory = FakeSpeechCaptureDriverFactory(drivers: [first, second])
        let recognizer = makeRecognizer(driverFactory: factory.make)

        let firstStream = try await recognizer.start()
        await recognizer.stop()
        let secondStream = try await recognizer.start()

        XCTAssertEqual(factory.creationCount, 2)
        let firstPrepareCount = await first.prepareCount
        let secondPrepareCount = await second.prepareCount
        XCTAssertEqual(firstPrepareCount, 1)
        XCTAssertEqual(secondPrepareCount, 1)
        await recognizer.stop()
        _ = (firstStream, secondStream)
    }

    func testShutdownTearsDownBeforeReleasingSuccessfulReservationOnlyOnce() async throws {
        let log = SpeechCaptureTestLog()
        let locale = Locale(identifier: "ja-JP")
        let inventory = TaskFiveSpeechAssetInventory(locale: locale, log: log)
        let preparer = SpeechAssetPreparer(locale: locale, inventory: inventory)
        let driver = FakeSpeechCaptureDriver(log: log)
        let recognizer = AppleSpeechRecognizer(
            assetPreparer: preparer,
            driverFactory: { driver }
        )
        try await recognizer.prepare()

        await recognizer.shutdown()
        await recognizer.shutdown()

        let releasedLocales = await inventory.releasedLocales
        let immediateTeardownCount = await driver.immediateTeardownCount
        let entries = await log.entries
        XCTAssertEqual(releasedLocales, [locale])
        XCTAssertEqual(immediateTeardownCount, 1)
        XCTAssertEqual(entries, [.immediateTeardown, .releaseReservation])
    }

    func testRunningShutdownCompletesNormalStopBeforeReleasingReservation() async throws {
        let log = SpeechCaptureTestLog()
        let locale = Locale(identifier: "ja-JP")
        let inventory = TaskFiveSpeechAssetInventory(locale: locale, log: log)
        let preparer = SpeechAssetPreparer(locale: locale, inventory: inventory)
        let driver = FakeSpeechCaptureDriver(log: log)
        let recognizer = AppleSpeechRecognizer(
            assetPreparer: preparer,
            driverFactory: { driver }
        )
        let stream = try await recognizer.start()

        await recognizer.shutdown()

        let entries = await log.entries
        let immediateTeardownCount = await driver.immediateTeardownCount
        XCTAssertEqual(entries, [.normalStop, .releaseReservation])
        XCTAssertEqual(immediateTeardownCount, 0)
        _ = stream
    }

    func testShutdownRejectsNewStartUntilReservationReleaseCompletes() async throws {
        let locale = Locale(identifier: "ja-JP")
        let inventory = TaskFiveSpeechAssetInventory(
            locale: locale,
            suspendRelease: true
        )
        let first = FakeSpeechCaptureDriver()
        let second = FakeSpeechCaptureDriver()
        let factory = FakeSpeechCaptureDriverFactory(drivers: [first, second])
        let recognizer = AppleSpeechRecognizer(
            assetPreparer: SpeechAssetPreparer(locale: locale, inventory: inventory),
            driverFactory: factory.make
        )
        let stream = try await recognizer.start()
        let shutdown = Task { await recognizer.shutdown() }
        await inventory.waitUntilReleaseStarts()

        do {
            _ = try await recognizer.start()
            XCTFail("Expected shutdown to retain exclusive ownership")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureAlreadyRunning)
        }

        await inventory.resumeRelease()
        await shutdown.value
        XCTAssertEqual(factory.creationCount, 1)
        _ = stream
    }

    func testAnalysisFailureThrowsCaptureFailureAndTearsDownExactlyOnce() async throws {
        let driver = FakeSpeechCaptureDriver(analysisFailure: .failed)
        let recognizer = makeRecognizer(driverFactory: { driver })
        let stream = try await recognizer.start()

        await assertCaptureFailure(from: stream)

        await driver.waitUntilImmediateTeardown()
        let immediateTeardownCount = await driver.immediateTeardownCount
        XCTAssertEqual(immediateTeardownCount, 1)
    }

    func testResultFailureThrowsCaptureFailureAndTearsDownExactlyOnce() async throws {
        let driver = FakeSpeechCaptureDriver(resultFailure: .failed)
        let recognizer = makeRecognizer(driverFactory: { driver })
        let stream = try await recognizer.start()

        await assertCaptureFailure(from: stream)

        await driver.waitUntilImmediateTeardown()
        let immediateTeardownCount = await driver.immediateTeardownCount
        XCTAssertEqual(immediateTeardownCount, 1)
    }

    func testEngineStartFailureCleansInstalledCaptureExactlyOnce() async {
        let driver = FakeSpeechCaptureDriver(engineStartFailure: .failed)
        let recognizer = makeRecognizer(driverFactory: { driver })

        do {
            _ = try await recognizer.start()
            XCTFail("Expected engine start failure")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureFailed)
        }

        let immediateTeardownCount = await driver.immediateTeardownCount
        let calls = await driver.calls
        XCTAssertEqual(immediateTeardownCount, 1)
        XCTAssertEqual(calls, [
            .prepare, .installTap, .beginAnalysis, .startEngine,
            .removeTap, .stopEngine, .resetEngine, .finishInput,
            .cancelTasks, .cancelAnalyzer,
        ])
    }

    func testConsumerCancellationStopsCaptureImmediately() async throws {
        let driver = FakeSpeechCaptureDriver()
        let recognizer = makeRecognizer(driverFactory: { driver })
        let stream = try await recognizer.start()
        let consumer = Task {
            for try await _ in stream {}
        }

        consumer.cancel()
        _ = await consumer.result

        await driver.waitUntilImmediateTeardown()
        let immediateTeardownCount = await driver.immediateTeardownCount
        XCTAssertEqual(immediateTeardownCount, 1)
    }

    private func assertCaptureFailure(
        from stream: AsyncThrowingStream<SpeechRecognitionEvent, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            for try await _ in stream {}
            XCTFail("Expected capture failure", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ConversationServiceError,
                .speechCaptureFailed,
                file: file,
                line: line
            )
        }
    }
}

private enum SpeechCaptureTestError: Error, Sendable {
    case failed
}

private enum SpeechCaptureCall: Equatable, Sendable {
    case prepare
    case installTap
    case beginAnalysis
    case startEngine
    case removeTap
    case stopEngine
    case resetEngine
    case flushConverter
    case finishInput
    case finalizeAnalyzer
    case drainResults
    case cancelTasks
    case cancelAnalyzer
}

private enum SpeechCaptureTestLogEntry: Equatable, Sendable {
    case normalStop
    case immediateTeardown
    case releaseReservation
}

private func makeRecognizer(
    driverFactory: @escaping @Sendable () -> any SpeechCaptureDriving
) -> AppleSpeechRecognizer {
    let locale = Locale(identifier: "ja-JP")
    let inventory = TaskFiveSpeechAssetInventory(locale: locale)
    return AppleSpeechRecognizer(
        assetPreparer: SpeechAssetPreparer(locale: locale, inventory: inventory),
        driverFactory: driverFactory
    )
}

private actor SpeechCaptureTestLog {
    private(set) var entries: [SpeechCaptureTestLogEntry] = []

    func append(_ entry: SpeechCaptureTestLogEntry) {
        entries.append(entry)
    }
}

private actor FakeSpeechCaptureDriver: SpeechCaptureDriving {
    private let results: [SpeechRecognitionEvent]
    private let analysisFailure: SpeechCaptureTestError?
    private let resultFailure: SpeechCaptureTestError?
    private let engineStartFailure: SpeechCaptureTestError?
    private let log: SpeechCaptureTestLog?

    private(set) var calls: [SpeechCaptureCall] = []
    private(set) var immediateTeardownCount = 0
    private var teardownWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        results: [SpeechRecognitionEvent] = [],
        analysisFailure: SpeechCaptureTestError? = nil,
        resultFailure: SpeechCaptureTestError? = nil,
        engineStartFailure: SpeechCaptureTestError? = nil,
        log: SpeechCaptureTestLog? = nil
    ) {
        self.results = results
        self.analysisFailure = analysisFailure
        self.resultFailure = resultFailure
        self.engineStartFailure = engineStartFailure
        self.log = log
    }

    func prepare(with transcriber: SpeechTranscriber) async throws {
        calls.append(.prepare)
    }

    func start(
        onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void,
        onFailure: @escaping @Sendable (ConversationServiceError) -> Void
    ) async throws {
        calls.append(.installTap)
        calls.append(.beginAnalysis)
        calls.append(.startEngine)
        if engineStartFailure != nil {
            throw SpeechCaptureTestError.failed
        }
        for result in results {
            onEvent(result)
        }
        if analysisFailure != nil || resultFailure != nil {
            onFailure(.speechCaptureFailed)
        }
    }

    func stop() async throws {
        calls.append(contentsOf: [
            .removeTap, .stopEngine, .resetEngine,
            .flushConverter, .finishInput, .finalizeAnalyzer, .drainResults,
        ])
        await log?.append(.normalStop)
    }

    func cancel() async {
        guard immediateTeardownCount == 0 else { return }
        immediateTeardownCount += 1
        calls.append(contentsOf: [
            .removeTap, .stopEngine, .resetEngine, .finishInput,
            .cancelTasks, .cancelAnalyzer,
        ])
        await log?.append(.immediateTeardown)
        let waiters = teardownWaiters
        teardownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    var prepareCount: Int {
        calls.filter { $0 == .prepare }.count
    }

    func waitUntilImmediateTeardown() async {
        guard immediateTeardownCount == 0 else { return }
        await withCheckedContinuation { continuation in
            teardownWaiters.append(continuation)
        }
    }
}

private final class FakeSpeechCaptureDriverFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var drivers: [FakeSpeechCaptureDriver]
    private var count = 0

    init(drivers: [FakeSpeechCaptureDriver] = []) {
        self.drivers = drivers
    }

    var creationCount: Int {
        lock.withLock { count }
    }

    func make() -> any SpeechCaptureDriving {
        lock.withLock {
            defer { count += 1 }
            if drivers.isEmpty {
                return FakeSpeechCaptureDriver()
            }
            return drivers.removeFirst()
        }
    }
}

private actor TaskFiveSpeechAssetInventory: SpeechAssetInventory {
    private let locale: Locale
    private let log: SpeechCaptureTestLog?
    private let suspendRelease: Bool
    private(set) var releasedLocales: [Locale] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        locale: Locale,
        log: SpeechCaptureTestLog? = nil,
        suspendRelease: Bool = false
    ) {
        self.locale = locale
        self.log = log
        self.suspendRelease = suspendRelease
    }

    func isSpeechTranscriberAvailable() async -> Bool { true }

    func equivalentSupportedLocale(to locale: Locale) async -> Locale? {
        self.locale
    }

    func installIfNeeded(supporting transcriber: SpeechTranscriber) async throws {}

    func isInstalled(_ transcriber: SpeechTranscriber) async -> Bool { true }

    func reserve(locale: Locale) async throws -> Bool { true }

    func release(reservedLocale: Locale) async -> Bool {
        releasedLocales.append(reservedLocale)
        await log?.append(.releaseReservation)
        let waiters = releaseStartWaiters
        releaseStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if suspendRelease {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return true
    }

    func waitUntilReleaseStarts() async {
        guard releasedLocales.isEmpty else { return }
        await withCheckedContinuation { continuation in
            releaseStartWaiters.append(continuation)
        }
    }

    func resumeRelease() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
