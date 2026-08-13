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

    func testNormalStopDeliversTailResultBeforeFinishingWithoutCancellation() async throws {
        let tail = SpeechRecognitionEvent(text: "語尾。", isFinal: true)
        let driver = FakeSpeechCaptureDriver(
            tailResultOnStop: tail,
            suspendNormalStop: true
        )
        let recognizer = makeRecognizer(driverFactory: { driver })
        let stream = try await recognizer.start()
        let collected = Task {
            var events: [SpeechRecognitionEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }
        let stop = Task { await recognizer.stop() }

        let didBeginNormalStop = await eventually { await driver.normalStopCount == 1 }
        XCTAssertTrue(didBeginNormalStop)
        await driver.resumeNormalStop()
        await stop.value

        let events = try await collected.value
        XCTAssertEqual(events, [tail])
        let cancelCallCount = await driver.cancelCallCount
        XCTAssertEqual(cancelCallCount, 0)
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

        let prepareCount = await driver.prepareCount
        let startCount = await driver.startCount
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(startCount, 0)
    }

    func testPreparedDriverIsReusedForStartWithoutPreparingTwice() async throws {
        let driver = FakeSpeechCaptureDriver()
        let recognizer = makeRecognizer(driverFactory: { driver })

        try await recognizer.prepare()
        let stream = try await recognizer.start()

        let prepareCount = await driver.prepareCount
        let startCount = await driver.startCount
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(startCount, 1)
        await recognizer.stop()
        _ = stream
    }

    func testStopFromPreparedCancelsRouteBoundDriverAndKeepsReservationForFreshPrepare() async throws {
        let locale = Locale(identifier: "ja-JP")
        let inventory = TaskFiveSpeechAssetInventory(locale: locale)
        let first = FakeSpeechCaptureDriver()
        let second = FakeSpeechCaptureDriver()
        let factory = FakeSpeechCaptureDriverFactory(drivers: [first, second])
        let recognizer = AppleSpeechRecognizer(
            assetPreparer: SpeechAssetPreparer(locale: locale, inventory: inventory),
            driverFactory: factory.make
        )
        try await recognizer.prepare()

        await recognizer.stop()

        let firstCancelCount = await first.cancelCallCount
        let releasedLocales = await inventory.releasedLocales
        XCTAssertEqual(firstCancelCount, 1)
        XCTAssertTrue(releasedLocales.isEmpty)

        try await recognizer.prepare()

        let firstPrepareCount = await first.prepareCount
        let secondPrepareCount = await second.prepareCount
        XCTAssertEqual(factory.creationCount, 2)
        XCTAssertEqual(firstPrepareCount, 1)
        XCTAssertEqual(secondPrepareCount, 1)
        await recognizer.shutdown()
    }

    func testStopOwnsSuspendedPreparationAndKeepsReservationForFreshPrepare() async throws {
        let locale = Locale(identifier: "ja-JP")
        let inventory = TaskFiveSpeechAssetInventory(locale: locale)
        let cancellationProbe = LockedFlag()
        let first = FakeSpeechCaptureDriver(
            suspendPreparation: true,
            preparationCancellationProbe: cancellationProbe
        )
        let second = FakeSpeechCaptureDriver()
        let factory = FakeSpeechCaptureDriverFactory(drivers: [first, second])
        let recognizer = AppleSpeechRecognizer(
            assetPreparer: SpeechAssetPreparer(locale: locale, inventory: inventory),
            driverFactory: factory.make
        )
        let prepareOutcome = Task { () -> ConversationServiceError? in
            do {
                try await recognizer.prepare()
                return nil
            } catch {
                return error as? ConversationServiceError
            }
        }
        let didBeginPreparation = await eventually { await first.prepareCount == 1 }
        XCTAssertTrue(didBeginPreparation)

        let stopCompleted = LockedFlag()
        let stop = Task {
            await recognizer.stop()
            stopCompleted.set()
        }
        let didCancelPreparation = await eventually { cancellationProbe.value }
        XCTAssertTrue(didCancelPreparation)
        XCTAssertFalse(stopCompleted.value)
        do {
            try await recognizer.prepare()
            XCTFail("A second prepare must not enter while stop owns preparation teardown")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureAlreadyRunning)
        }
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertFalse(stopCompleted.value)
        await first.resumePreparation()
        await stop.value

        let preparationResult = await prepareOutcome.value
        let firstCancelCount = await first.cancelCallCount
        let releasedLocales = await inventory.releasedLocales
        XCTAssertEqual(preparationResult, .cancelled)
        XCTAssertEqual(firstCancelCount, 1)
        XCTAssertTrue(releasedLocales.isEmpty)

        try await recognizer.prepare()
        let secondPrepareCount = await second.prepareCount
        XCTAssertEqual(factory.creationCount, 2)
        XCTAssertEqual(secondPrepareCount, 1)
        await recognizer.shutdown()
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
        let immediateTeardownCount = await driver.cancelCallCount
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
        let immediateTeardownCount = await driver.cancelCallCount
        XCTAssertEqual(entries, [.normalStop, .normalStopCompleted, .releaseReservation])
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
        await driver.emitConfiguredFailure()

        await assertCaptureFailure(from: stream)

        let didCancel = await eventually { await driver.cancelCallCount == 1 }
        XCTAssertTrue(didCancel)
        let immediateTeardownCount = await driver.cancelCallCount
        XCTAssertEqual(immediateTeardownCount, 1)
    }

    func testResultFailureThrowsCaptureFailureAndTearsDownExactlyOnce() async throws {
        let driver = FakeSpeechCaptureDriver(resultFailure: .failed)
        let recognizer = makeRecognizer(driverFactory: { driver })
        let stream = try await recognizer.start()
        await driver.emitConfiguredFailure()

        await assertCaptureFailure(from: stream)

        let didCancel = await eventually { await driver.cancelCallCount == 1 }
        XCTAssertTrue(didCancel)
        let immediateTeardownCount = await driver.cancelCallCount
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

        let immediateTeardownCount = await driver.cancelCallCount
        XCTAssertEqual(immediateTeardownCount, 1)
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

        let didCancel = await eventually { await driver.cancelCallCount == 1 }
        XCTAssertTrue(didCancel)
        let immediateTeardownCount = await driver.cancelCallCount
        XCTAssertEqual(immediateTeardownCount, 1)
    }

    func testStartFailureJoinsTheOwnedTeardownAndCannotOverwriteTheNextRun() async throws {
        let first = FakeSpeechCaptureDriver(
            engineStartFailure: .failed,
            suspendStart: true,
            suspendCancellation: true
        )
        let second = FakeSpeechCaptureDriver()
        let factory = FakeSpeechCaptureDriverFactory(drivers: [first, second])
        let recognizer = makeRecognizer(driverFactory: factory.make)
        let startOutcome = Task { () -> ConversationServiceError? in
            do {
                _ = try await recognizer.start()
                return nil
            } catch {
                return error as? ConversationServiceError
            }
        }

        let didBeginStart = await eventually { await first.startCount == 1 }
        XCTAssertTrue(didBeginStart)
        await first.emitFailure(.speechCaptureFailed)
        let didTakeOwnership = await waitUntilTeardownOwns(recognizer)
        XCTAssertTrue(didTakeOwnership)
        let cancelCountBeforeStartSettled = await first.cancelCallCount
        XCTAssertEqual(cancelCountBeforeStartSettled, 0)
        await first.resumeStart()
        let didReachStartFailure = await eventually { await first.didReachStartFailure }
        XCTAssertTrue(didReachStartFailure)
        let didBeginCancellation = await eventually { await first.cancelCallCount == 1 }
        XCTAssertTrue(didBeginCancellation)

        var unexpectedStream: AsyncThrowingStream<SpeechRecognitionEvent, Error>?
        for _ in 0..<100 {
            do {
                unexpectedStream = try await recognizer.start()
                break
            } catch let error as ConversationServiceError {
                XCTAssertEqual(error, .speechCaptureAlreadyRunning)
            }
            await Task.yield()
        }
        XCTAssertNil(unexpectedStream)
        let firstCancelCountBeforeResume = await first.cancelCallCount
        XCTAssertEqual(firstCancelCountBeforeResume, 1)

        await first.resumeCancellation()
        let firstStartOutcome = await startOutcome.value
        XCTAssertEqual(firstStartOutcome, .speechCaptureFailed)

        let secondStream = try await recognizer.start()
        await first.emitFailure(.speechCaptureFailed)
        do {
            _ = try await recognizer.start()
            XCTFail("A stale first-run failure reopened the recognizer")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureAlreadyRunning)
        }
        await recognizer.stop()
        XCTAssertEqual(factory.creationCount, 2)
        _ = secondStream
    }

    func testStopWaitsForSuspendedSuccessfulStartAndMakesStartThrowCancelled() async throws {
        let log = SpeechCaptureTestLog()
        let first = FakeSpeechCaptureDriver(
            log: log,
            suspendNormalStop: true,
            suspendStart: true,
            logStartSettlement: true
        )
        let second = FakeSpeechCaptureDriver()
        let factory = FakeSpeechCaptureDriverFactory(drivers: [first, second])
        let recognizer = makeRecognizer(driverFactory: factory.make)
        let startCompleted = LockedFlag()
        let startOutcome = Task {
            defer { startCompleted.set() }
            return await captureStartOutcome(from: recognizer)
        }

        let didBeginStart = await eventually { await first.startCount == 1 }
        XCTAssertTrue(didBeginStart)
        let stop = Task { await recognizer.stop() }
        let didTakeOwnership = await waitUntilTeardownOwns(recognizer)
        XCTAssertTrue(didTakeOwnership)

        await first.resumeStart()
        let didBeginStop = await eventually { await first.normalStopCount == 1 }
        XCTAssertTrue(didBeginStop)
        do {
            _ = try await recognizer.start()
            XCTFail("Expected teardown to retain exclusive ownership")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureAlreadyRunning)
        }
        XCTAssertEqual(factory.creationCount, 1)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(startCompleted.value)
        await first.resumeNormalStop()

        await stop.value
        let outcome = await startOutcome.value
        let entries = await log.entries
        let cancellationCount = await first.cancelCallCount
        XCTAssertEqual(outcome, .failed(.cancelled))
        XCTAssertEqual(entries, [.startSettled, .normalStop, .normalStopCompleted])
        XCTAssertEqual(cancellationCount, 0)

        let nextStream = try await recognizer.start()
        XCTAssertEqual(factory.creationCount, 2)
        await recognizer.stop()
        _ = nextStream
    }

    func testShutdownWaitsForSuspendedSuccessfulStartBeforeTeardownAndRelease() async throws {
        let log = SpeechCaptureTestLog()
        let locale = Locale(identifier: "ja-JP")
        let inventory = TaskFiveSpeechAssetInventory(
            locale: locale,
            log: log,
            suspendRelease: true
        )
        let driver = FakeSpeechCaptureDriver(
            log: log,
            suspendNormalStop: true,
            suspendStart: true,
            logStartSettlement: true
        )
        let recognizer = AppleSpeechRecognizer(
            assetPreparer: SpeechAssetPreparer(locale: locale, inventory: inventory),
            driverFactory: { driver }
        )
        let startCompleted = LockedFlag()
        let startOutcome = Task {
            defer { startCompleted.set() }
            return await captureStartOutcome(from: recognizer)
        }

        let didBeginStart = await eventually { await driver.startCount == 1 }
        XCTAssertTrue(didBeginStart)
        let shutdown = Task { await recognizer.shutdown() }
        let didTakeOwnership = await waitUntilTeardownOwns(recognizer)
        XCTAssertTrue(didTakeOwnership)

        await driver.resumeStart()
        let didBeginStop = await eventually { await driver.normalStopCount == 1 }
        XCTAssertTrue(didBeginStop)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(startCompleted.value)
        await driver.resumeNormalStop()
        await inventory.waitUntilReleaseStarts()
        let entriesDuringRelease = await log.entries
        XCTAssertEqual(
            entriesDuringRelease,
            [.startSettled, .normalStop, .normalStopCompleted, .releaseReservation]
        )
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(startCompleted.value)
        await inventory.resumeRelease()

        await shutdown.value
        let outcome = await startOutcome.value
        let entries = await log.entries
        let cancellationCount = await driver.cancelCallCount
        XCTAssertEqual(outcome, .failed(.cancelled))
        XCTAssertEqual(
            entries,
            [.startSettled, .normalStop, .normalStopCompleted, .releaseReservation]
        )
        XCTAssertEqual(cancellationCount, 0)
    }

    func testFailureDuringSuspendedStartWaitsForSettlementBeforeImmediateTeardown() async {
        let log = SpeechCaptureTestLog()
        let driver = FakeSpeechCaptureDriver(
            log: log,
            suspendStart: true,
            suspendCancellation: true,
            logStartSettlement: true
        )
        let recognizer = makeRecognizer(driverFactory: { driver })
        let startCompleted = LockedFlag()
        let startOutcome = Task {
            defer { startCompleted.set() }
            return await captureStartOutcome(from: recognizer)
        }

        let didBeginStart = await eventually { await driver.startCount == 1 }
        XCTAssertTrue(didBeginStart)
        await driver.emitFailure(.speechCaptureFailed)
        let didTakeOwnership = await waitUntilTeardownOwns(recognizer)
        XCTAssertTrue(didTakeOwnership)

        let cancellationCountBeforeStartSettled = await driver.cancelCallCount
        XCTAssertEqual(cancellationCountBeforeStartSettled, 0)
        await driver.resumeStart()
        let didBeginCancellation = await eventually { await driver.cancelCallCount == 1 }
        XCTAssertTrue(didBeginCancellation)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(startCompleted.value)
        await driver.resumeCancellation()

        let outcome = await startOutcome.value
        let entries = await log.entries
        let cancellationCount = await driver.cancelCallCount
        XCTAssertEqual(outcome, .failed(.speechCaptureFailed))
        XCTAssertEqual(entries, [.startSettled, .immediateTeardown])
        XCTAssertEqual(cancellationCount, 1)
    }

    func testStartTeardownOwnershipKeepsEachLifecycleGenerationScoped() {
        let startID = UUID()
        let originalLifecycleID = UUID()
        let newerStartID = UUID()
        let newerLifecycleID = UUID()
        var ownership = SpeechStartTeardownOwnership()

        ownership.record(
            lifecycleID: originalLifecycleID,
            forStartID: startID
        )
        ownership.record(
            lifecycleID: newerLifecycleID,
            forStartID: newerStartID
        )

        XCTAssertNotEqual(originalLifecycleID, newerLifecycleID)
        XCTAssertEqual(
            ownership.takeLifecycleID(forStartID: startID),
            originalLifecycleID
        )
        XCTAssertEqual(
            ownership.takeLifecycleID(forStartID: newerStartID),
            newerLifecycleID
        )
        XCTAssertNil(ownership.takeLifecycleID(forStartID: startID))
    }

    func testShutdownOwnsSuspendedPreparationAndCancelsItsPreparedDriverBeforeRelease() async throws {
        let log = SpeechCaptureTestLog()
        let locale = Locale(identifier: "ja-JP")
        let inventory = TaskFiveSpeechAssetInventory(locale: locale, log: log)
        let cancellationProbe = LockedFlag()
        let first = FakeSpeechCaptureDriver(
            log: log,
            suspendPreparation: true,
            preparationCancellationProbe: cancellationProbe
        )
        let second = FakeSpeechCaptureDriver()
        let factory = FakeSpeechCaptureDriverFactory(drivers: [first, second])
        let recognizer = AppleSpeechRecognizer(
            assetPreparer: SpeechAssetPreparer(locale: locale, inventory: inventory),
            driverFactory: factory.make
        )
        let prepareOutcome = Task { () -> ConversationServiceError? in
            do {
                try await recognizer.prepare()
                return nil
            } catch {
                return error as? ConversationServiceError
            }
        }

        let didBeginPreparation = await eventually { await first.prepareCount == 1 }
        XCTAssertTrue(didBeginPreparation)
        let shutdown = Task { await recognizer.shutdown() }
        let didCancelPreparation = await eventually { cancellationProbe.value }
        XCTAssertTrue(didCancelPreparation)
        await first.resumePreparation()

        await shutdown.value
        let preparationResult = await prepareOutcome.value
        let firstCancelCount = await first.cancelCallCount
        let logEntries = await log.entries
        XCTAssertEqual(preparationResult, .cancelled)
        XCTAssertEqual(firstCancelCount, 1)
        XCTAssertEqual(logEntries, [.immediateTeardown, .releaseReservation])

        let stream = try await recognizer.start()
        XCTAssertEqual(factory.creationCount, 2)
        let secondPrepareCount = await second.prepareCount
        XCTAssertEqual(secondPrepareCount, 1)
        await recognizer.stop()
        _ = stream
    }

    func testRunPhaseAcceptsTailEventsButSuppressesFailuresDuringGracefulFinalization() {
        var phase = SpeechCaptureRunPhase()
        phase.didPrepare()
        phase.didStart()
        phase.beginGracefulFinalization()

        XCTAssertTrue(phase.acceptsEvents)
        XCTAssertFalse(phase.acceptsFailures)

        phase.finish()
        XCTAssertFalse(phase.acceptsEvents)
        XCTAssertFalse(phase.acceptsFailures)
    }

    func testRunPhaseRejectsLateEventsDuringImmediateCancellation() {
        var phase = SpeechCaptureRunPhase()
        phase.didPrepare()
        phase.didStart()
        phase.beginImmediateCancellation()

        XCTAssertFalse(phase.acceptsEvents)
        XCTAssertFalse(phase.acceptsFailures)
    }

    func testCancellationCoordinatorCoalescesReentrantCallersUntilOperationFinishes() async {
        let coordinator = SpeechCaptureCancellationCoordinator()
        let gate = AsyncGate()
        let operationCount = LockedCounter()
        let completionCount = LockedCounter()
        let secondStarted = LockedFlag()
        let operation: @Sendable () async -> Void = {
            operationCount.increment()
            await gate.wait()
        }

        let first = Task {
            await coordinator.cancel(operation: operation)
            completionCount.increment()
        }
        let didBeginOperation = await eventually { operationCount.value == 1 }
        XCTAssertTrue(didBeginOperation)
        let second = Task {
            secondStarted.set()
            await coordinator.cancel(operation: operation)
            completionCount.increment()
        }

        let didStartSecondCaller = await eventually { secondStarted.value }
        XCTAssertTrue(didStartSecondCaller)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(operationCount.value, 1)
        XCTAssertEqual(completionCount.value, 0)

        await gate.open()
        await first.value
        await second.value
        XCTAssertEqual(operationCount.value, 1)
        XCTAssertEqual(completionCount.value, 2)
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

    private func waitUntilTeardownOwns(
        _ recognizer: AppleSpeechRecognizer
    ) async -> Bool {
        for _ in 0..<1_000 {
            do {
                try await recognizer.prepare()
            } catch let error as ConversationServiceError {
                if error == .speechCaptureAlreadyRunning {
                    return true
                }
            } catch {}
            await Task.yield()
        }
        return false
    }
}

private enum SpeechCaptureTestError: Error, Sendable {
    case failed
}

private enum SpeechCaptureTestLogEntry: Equatable, Sendable {
    case startSettled
    case normalStop
    case normalStopCompleted
    case immediateTeardown
    case releaseReservation
}

private enum CaptureStartOutcome: Equatable, Sendable {
    case returnedStream
    case failed(ConversationServiceError?)
}

private func captureStartOutcome(
    from recognizer: AppleSpeechRecognizer
) async -> CaptureStartOutcome {
    do {
        _ = try await recognizer.start()
        return .returnedStream
    } catch {
        return .failed(error as? ConversationServiceError)
    }
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
    private let tailResultOnStop: SpeechRecognitionEvent?
    private let suspendNormalStop: Bool
    private let suspendPreparation: Bool
    private let preparationCancellationProbe: LockedFlag?
    private let suspendStart: Bool
    private let suspendCancellation: Bool
    private let logStartSettlement: Bool

    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var normalStopCount = 0
    private(set) var cancelCallCount = 0
    private(set) var didReachStartFailure = false
    private var eventHandler: (@Sendable (SpeechRecognitionEvent) -> Void)?
    private var failureHandler: (@Sendable (ConversationServiceError) -> Void)?
    private let normalStopGate = AsyncGate()
    private let preparationGate = AsyncGate()
    private let startGate = AsyncGate()
    private let cancellationGate = AsyncGate()

    init(
        results: [SpeechRecognitionEvent] = [],
        analysisFailure: SpeechCaptureTestError? = nil,
        resultFailure: SpeechCaptureTestError? = nil,
        engineStartFailure: SpeechCaptureTestError? = nil,
        log: SpeechCaptureTestLog? = nil,
        tailResultOnStop: SpeechRecognitionEvent? = nil,
        suspendNormalStop: Bool = false,
        suspendPreparation: Bool = false,
        preparationCancellationProbe: LockedFlag? = nil,
        suspendStart: Bool = false,
        suspendCancellation: Bool = false,
        logStartSettlement: Bool = false
    ) {
        self.results = results
        self.analysisFailure = analysisFailure
        self.resultFailure = resultFailure
        self.engineStartFailure = engineStartFailure
        self.log = log
        self.tailResultOnStop = tailResultOnStop
        self.suspendNormalStop = suspendNormalStop
        self.suspendPreparation = suspendPreparation
        self.preparationCancellationProbe = preparationCancellationProbe
        self.suspendStart = suspendStart
        self.suspendCancellation = suspendCancellation
        self.logStartSettlement = logStartSettlement
    }

    func prepare(with transcriber: SpeechTranscriber) async throws {
        prepareCount += 1
        guard suspendPreparation else { return }
        await withTaskCancellationHandler {
            await preparationGate.wait()
        } onCancel: { [preparationCancellationProbe] in
            preparationCancellationProbe?.set()
        }
    }

    func start(
        onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void,
        onFailure: @escaping @Sendable (ConversationServiceError) -> Void
    ) async throws {
        startCount += 1
        eventHandler = onEvent
        failureHandler = onFailure
        if suspendStart {
            await startGate.wait()
        }
        if logStartSettlement {
            await log?.append(.startSettled)
        }
        if engineStartFailure != nil {
            didReachStartFailure = true
            throw SpeechCaptureTestError.failed
        }
        for result in results {
            onEvent(result)
        }
    }

    func stop() async throws {
        normalStopCount += 1
        await log?.append(.normalStop)
        if suspendNormalStop {
            await normalStopGate.wait()
        }
        if let tailResultOnStop {
            eventHandler?(tailResultOnStop)
        }
        await log?.append(.normalStopCompleted)
    }

    func cancel() async {
        cancelCallCount += 1
        guard cancelCallCount == 1 else { return }
        await log?.append(.immediateTeardown)
        if suspendCancellation {
            await cancellationGate.wait()
        }
    }

    func emitFailure(_ error: ConversationServiceError) {
        failureHandler?(error)
    }

    func emitConfiguredFailure() {
        guard analysisFailure != nil || resultFailure != nil else { return }
        failureHandler?(.speechCaptureFailed)
    }

    func resumeNormalStop() async {
        await normalStopGate.open()
    }

    func resumePreparation() async {
        await preparationGate.open()
    }

    func resumeStart() async {
        await startGate.open()
    }

    func resumeCancellation() async {
        await cancellationGate.open()
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

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
