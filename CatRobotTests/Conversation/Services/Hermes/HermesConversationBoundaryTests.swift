import Foundation
import XCTest
@testable import CatRobot

/// Navigator の観測を正式な Driver の直列検証へ取り込んだ回帰試験。
final class HermesConversationBoundaryTests: XCTestCase {
    private let connection = HermesConnection(endpoint: URL(string: "https://hermes.test:8443/")!,
                                              credential: HermesCredential(apiKey: "client-key"))

    private func makeService(_ server: FakeHermesServer, records: InMemoryHermesSessionRecordStore = InMemoryHermesSessionRecordStore(),
                             sessionIDs: [String] = ["catrobot-s1", "catrobot-s2"]) -> HermesConversationService {
        let resolved = connection
        let ids = ProbeSequenced(sessionIDs)
        return HermesConversationService(connection: { resolved }, transport: server, records: records, clock: SteppingHermesClock(),
                                         timing: HermesConversationTiming(pollInterval: .seconds(1), turnDeadline: .seconds(10), submitRetryDelay: .seconds(1)),
                                         makeSessionID: { ids.next() }, makeIdempotencyKey: { UUID() })
    }

    func testDeadlineWhileSubmissionIsHeld() async throws {
        try await checkHeldDeadline("submit")
    }

    func testDeadlineWhilePollIsHeld() async throws {
        try await checkHeldDeadline("poll")
    }

    func testDeadlineWhileStopIsHeld() async throws {
        try await checkHeldDeadline("stop")
    }

    private func checkHeldDeadline(_ phase: String) async throws {
        let clock = ManualTurnClock()
        let records = InMemoryHermesSessionRecordStore()
        let accepted = hermesAccepted("old-run")
        let completed = hermesRun("old-run", "completed", output: "too late")
        let cancelled = hermesRun("old-run", "cancelled")
        let stop: FakeHermesServer.Reply = switch phase {
        case "stop": .gated(phase, cancelled)
        case "poll": hermesRun("old-run", "stopping")
        default: cancelled
        }
        let server = FakeHermesServer(
            runs: [phase == "submit" ? .gated(phase, accepted) : accepted, hermesAccepted("new-run")],
            polls: ["old-run": [phase == "poll" ? .gated(phase, completed) : hermesRun("old-run", "waiting_for_approval")],
                    "new-run": [hermesRun("new-run", "completed", output: "new reply")]],
            stops: ["old-run": [stop]])
        let resolved = connection
        let service = HermesConversationService(connection: { resolved }, transport: server, records: records,
                                                clock: clock, timing: .init(turnDeadline: .seconds(10)),
                                                makeSessionID: { "catrobot-s1" })
        let finished = expectation(description: "deadline delivered with \(phase) still suspended")
        let stream = try await service.streamReply(to: "old turn")
        let reader = Task {
            defer { finished.fulfill() }
            return try await probeCollect(stream)
        }
        await server.waitUntilBlocked(phase)
        let wasHeld = await server.isBlocked(phase)
        XCTAssertTrue(wasHeld)
        await clock.advance(10)
        await fulfillment(of: [finished], timeout: 0.5)
        if phase == "poll" { await server.waitForRequest { $0.url.path == "/v1/runs/old-run/stop" } }
        let stillHeld = await server.isBlocked(phase)
        XCTAssertTrue(stillHeld)
        let beforeRelease = await records.record
        XCTAssertEqual(beforeRelease?.hasUncertainSubmission, phase == "submit")
        XCTAssertEqual(beforeRelease?.unsettledRunIDs, phase == "submit" ? [] : ["old-run"])
        // Release even when the timed assertion fails. A pre-release also covers a late gate arrival.
        await server.release(phase)
        do {
            let output = try await boundedValue(of: reader)
            XCTFail("expired turn returned \(output)")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .replyTimedOut)
        }
        await records.waitUntil { $0?.unsettledRunIDs.isEmpty == true && $0?.hasUncertainSubmission == false }
        let turns = await service.recentTurns()
        XCTAssertTrue(turns.isEmpty)
        let settled = await records.record
        XCTAssertTrue(settled?.unsettledRunIDs.isEmpty == true)
        XCTAssertFalse(settled?.hasUncertainSubmission ?? true)
        let nextStream = try await service.streamReply(to: "new turn")
        let next = try await boundedValue(of: Task { try await probeCollect(nextStream) })
        XCTAssertEqual(next, ["new reply"])
    }

    func testLateAcceptanceDoesNotClearAnotherTurnsPendingSubmission() async throws {
        try await checkLateAcceptanceDuringNewSubmission(reset: false)
    }

    func testLateAcceptanceAfterResetKeepsOnlyRunCleanupOwnership() async throws {
        try await checkLateAcceptanceDuringNewSubmission(reset: true)
    }

    func testLateAcceptanceAfterChangingOriginStopsOnlyAtTheOriginalOrigin() async throws {
        let other = HermesConnection(endpoint: URL(string: "https://other.test")!,
                                     credential: HermesCredential(apiKey: "other-key"))
        try await checkLateAcceptanceDuringNewSubmission(reset: false, newOrigin: other)
    }

    private func checkLateAcceptanceDuringNewSubmission(reset: Bool, newOrigin: HermesConnection? = nil) async throws {
        let clock = ManualTurnClock()
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(
            runs: [.gated("old-submit", hermesAccepted("old-run")), .gated("new-submit", hermesAccepted("new-run"))],
            polls: ["new-run": [hermesRun("new-run", "completed", output: "new reply")]],
            stops: ["old-run": [.gated("old-stop", hermesRun("old-run", "cancelled"))]])
        let connections = ProbeSequenced([connection, newOrigin ?? connection])
        let ids = ProbeSequenced(["catrobot-s1", "catrobot-s2"])
        let service = HermesConversationService(connection: { connections.next() }, transport: server, records: records,
                                                clock: clock, timing: .init(turnDeadline: .seconds(10)),
                                                makeSessionID: { ids.next() })
        let stream = try await service.streamReply(to: "old turn")
        let finished = expectation(description: "old turn expires before accepting")
        let reader = Task {
            defer { finished.fulfill() }
            return try await probeCollect(stream)
        }
        await server.waitUntilBlocked("old-submit")
        await clock.advance(10)
        await fulfillment(of: [finished], timeout: 0.5)
        if reset { await service.reset() }
        var next: Task<[String], Error>?
        do {
            let stream = try await service.streamReply(to: "new turn")
            next = Task { try await probeCollect(stream) }
            await server.waitUntilBlocked("new-submit")
            let newHeld = await server.isBlocked("new-submit")
            let oldHeld = await server.isBlocked("old-submit")
            XCTAssertTrue(newHeld && oldHeld)
        } catch {
            XCTFail("new turn could not start while the old submission was held: \(error)")
        }
        await server.release("old-submit")
        await server.waitUntilBlocked("old-stop")
        let oldStopHeld = await server.isBlocked("old-stop")
        XCTAssertTrue(oldStopHeld)
        let pending = await records.record
        let replacedSession = reset || newOrigin != nil
        XCTAssertEqual(pending?.origin, newOrigin?.origin ?? connection.origin)
        XCTAssertEqual(pending?.sessionID, replacedSession ? "catrobot-s2" : "catrobot-s1")
        XCTAssertEqual(pending?.hasTurns, !replacedSession)
        XCTAssertEqual(pending?.hasUncertainSubmission, true)
        XCTAssertEqual(pending?.unsettledRunIDs, newOrigin == nil ? ["old-run"] : [])
        let stops = await server.stops
        XCTAssertEqual(stops.map(\.url.host), [connection.endpoint.host])
        await server.release("old-stop")
        await server.release("new-submit")
        do {
            let output = try await boundedValue(of: reader)
            XCTFail("expired turn returned \(output)")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .replyTimedOut)
        }
        if let next {
            let output = try await boundedValue(of: next)
            XCTAssertEqual(output, ["new reply"])
        }
        await records.waitUntil { $0?.unsettledRunIDs.isEmpty == true && $0?.hasUncertainSubmission == false }
        let paths = await server.requests.map(\.url.path)
        XCTAssertFalse(paths.contains("/v1/runs/old-run"))
        let turns = await service.recentTurns()
        XCTAssertEqual(turns.map(\.response), ["new reply"])
        let settled = await records.record
        XCTAssertEqual(settled?.unsettledRunIDs, [])
        XCTAssertEqual(settled?.hasUncertainSubmission, false)
    }

    func testDeadlineCancelsACooperativeSubmitAndKeepsTheLostAcceptanceUncertain() async throws {
        let clock = ManualTurnClock()
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [.cooperativelyGated("submit"), hermesAccepted("new-run")],
                                      polls: ["new-run": [hermesRun("new-run", "completed", output: "new reply")]])
        let resolved = connection
        let service = HermesConversationService(connection: { resolved }, transport: server, records: records,
                                                clock: clock, timing: .init(turnDeadline: .seconds(10)),
                                                makeSessionID: { "catrobot-s1" })
        let stream = try await service.streamReply(to: "old turn")
        let finished = expectation(description: "cooperative submit expires")
        let reader = Task {
            defer { finished.fulfill() }
            return try await probeCollect(stream)
        }
        await server.waitUntilBlocked("submit")
        let held = await server.isBlocked("submit")
        XCTAssertTrue(held)
        await clock.advance(10)
        await fulfillment(of: [finished], timeout: 0.5)
        for _ in 0..<100 {
            if await server.cancelledGates.contains("submit") { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let cancelled = await server.cancelledGates.contains("submit")
        await server.release("submit")
        XCTAssertTrue(cancelled)
        do {
            let output = try await boundedValue(of: reader)
            XCTFail("expired turn returned \(output)")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .replyTimedOut)
        }
        let nextStream = try await service.streamReply(to: "new turn")
        let next = try await boundedValue(of: Task { try await probeCollect(nextStream) })
        XCTAssertEqual(next, ["new reply"])
        let record = await records.record
        XCTAssertEqual(record?.hasUncertainSubmission, true)
        XCTAssertEqual(record?.unsettledRunIDs, [])
        let postCount = await server.runPosts.count
        XCTAssertEqual(postCount, 2, "an expired uncertain submission must never be retried")
    }

    private func boundedValue(of reader: Task<[String], Error>) async throws -> [String] {
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            reader.cancel()
        }
        defer { watchdog.cancel() }
        return try await reader.value
    }

    func testPrepareReadsAfterAnInFlightCompletionAlreadyRepresentedInHistory() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin,
                                                                         sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(runs: [hermesAccepted("run-repeat")],
                                      polls: ["run-repeat": [.gated("poll", hermesRun("run-repeat", "completed", output: "same reply"))]],
                                      history: [.gated("history", .json(200, #"""
            {"session_id":"catrobot-old","data":[
              {"role":"user","content":"same prompt"},{"role":"assistant","content":"same reply"},
              {"role":"user","content":"middle prompt"},{"role":"assistant","content":"middle reply"},
              {"role":"user","content":"same prompt"},{"role":"assistant","content":"same reply"}
            ]}
            """#))])
        let service = makeService(server, records: records)
        let stream = try await service.streamReply(to: "same prompt")
        await server.waitUntilBlocked("poll")
        let restore = Task { try await service.prepareMemory() }
        // The poll response is explicitly held while preparation has a chance to issue its GET.
        try await Task.sleep(for: .milliseconds(100))
        await server.release("poll")
        let replies = try await probeCollect(stream)
        XCTAssertEqual(replies, ["same reply"])
        await server.waitUntilBlocked("history")
        let requests = await server.requests
        XCTAssertEqual(requests.map { $0.url.path }, ["/v1/runs", "/v1/runs/run-repeat", "/api/sessions/catrobot-old/messages"])
        let submittedBody = try XCTUnwrap(requests.first?.body)
        let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: submittedBody) as? [String: String])
        XCTAssertEqual(submitted["session_id"], "catrobot-old")
        XCTAssertEqual(submitted["input"], "same prompt")
        await service.recordExternalTurn(prompt: "same prompt", response: "same reply")
        await server.release("history")
        try await restore.value
        let repeated = ConversationMemoryTurn(prompt: "same prompt", response: "same reply")
        let middle = ConversationMemoryTurn(prompt: "middle prompt", response: "middle reply")
        let turns = await service.recentTurns()
        XCTAssertEqual(turns, [repeated, middle, repeated, repeated])
    }

    func testPrepareKeepsEqualTextFromANewRunSubmittedAfterTheHistorySnapshot() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin,
                                                                         sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(runs: [hermesAccepted("run-new")],
                                      polls: ["run-new": [hermesRun("run-new", "completed", output: "same reply")]],
                                      history: [.gated("history", .json(200, #"""
            {"session_id":"catrobot-old","data":[
              {"role":"user","content":"same prompt"},{"role":"assistant","content":"same reply"}]}
            """#))])
        let service = makeService(server, records: records)
        let restore = Task { try await service.prepareMemory() }
        await server.waitUntilBlocked("history")
        let newRun = Task { try await probeCollect(try await service.streamReply(to: "same prompt")) }
        try await Task.sleep(for: .milliseconds(100))
        let whileReading = await server.requests.map { $0.url.path }
        XCTAssertEqual(whileReading, ["/api/sessions/catrobot-old/messages"])
        await server.release("history")
        try await restore.value
        let output = try await newRun.value
        XCTAssertEqual(output, ["same reply"])
        let requests = await server.requests.map { $0.url.path }
        XCTAssertEqual(requests, ["/api/sessions/catrobot-old/messages", "/v1/runs", "/v1/runs/run-new"])
        let turns = await service.recentTurns()
        let repeated = ConversationMemoryTurn(prompt: "same prompt", response: "same reply")
        XCTAssertEqual(turns, [repeated, repeated])
    }

    func testTransientPrepareFailureKeepsTheWholeCacheInOrder() async throws {
        try await checkWholeCacheAfterHistory(.transportFailure, keepsPrevious: true)
    }

    func testSuccessfulEmptyPrepareReplacesOldCacheAndKeepsTheConcurrentAppend() async throws {
        try await checkWholeCacheAfterHistory(.json(200, #"{"session_id":"catrobot-old","data":[]}"#),
                                             keepsPrevious: false)
    }

    private func checkWholeCacheAfterHistory(_ reply: FakeHermesServer.Reply, keepsPrevious: Bool) async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin,
                                                                         sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(runs: [hermesAccepted("run-cached")],
                                      polls: ["run-cached": [hermesRun("run-cached", "completed", output: "cached")]],
                                      history: [.gated("history", reply)])
        let service = makeService(server, records: records)
        let preexisting = ConversationMemoryTurn(prompt: "before", response: "cached")
        let concurrent = ConversationMemoryTurn(prompt: "during", response: "appended")
        let replies = try await probeCollect(try await service.streamReply(to: preexisting.prompt))
        XCTAssertEqual(replies, [preexisting.response])
        let beforeRead = await service.recentTurns()
        XCTAssertEqual(beforeRead, [preexisting])
        let restore = Task { try await service.prepareMemory() }
        await server.waitUntilBlocked("history")
        await service.recordExternalTurn(prompt: concurrent.prompt, response: concurrent.response)
        await server.release("history")
        try await restore.value
        let turns = await service.recentTurns()
        XCTAssertEqual(turns, keepsPrevious ? [preexisting, concurrent] : [concurrent])
    }

    func testFirstPrepareAndRepeatedReadsKeepDistinctLocalEvents() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin,
                                                                         sessionID: "catrobot-old", hasTurns: true))
        let nonempty = FakeHermesServer.Reply.json(200, #"""
            {"session_id":"catrobot-old","data":[
              {"id":1,"role":"user","content":"repeat"},{"id":2,"role":"assistant","content":"answer"},
              {"id":3,"role":"user","content":"server"},{"id":4,"role":"assistant","content":"middle"},
              {"id":5,"role":"user","content":"repeat"},{"id":6,"role":"assistant","content":"answer"}
            ]}
            """#)
        let empty = FakeHermesServer.Reply.json(200, #"{"session_id":"catrobot-old","data":[]}"#)
        let server = FakeHermesServer(history: [.gated("nonempty", nonempty), .gated("empty", empty),
                                               nonempty, nonempty, empty])
        let service = makeService(server, records: records)
        let repeatTurn = ConversationMemoryTurn(prompt: "repeat", response: "answer")
        let localMiddle = ConversationMemoryTurn(prompt: "local", response: "middle")
        let serverMiddle = ConversationMemoryTurn(prompt: "server", response: "middle")
        let duringEmpty = ConversationMemoryTurn(prompt: "empty", response: "append")
        await service.recordExternalTurn(prompt: repeatTurn.prompt, response: repeatTurn.response)
        await service.recordExternalTurn(prompt: localMiddle.prompt, response: localMiddle.response)
        let first = Task { try await service.prepareMemory() }
        await server.waitUntilBlocked("nonempty")
        await service.recordExternalTurn(prompt: repeatTurn.prompt, response: repeatTurn.response)
        await server.release("nonempty")
        try await first.value
        let afterFirst = await service.recentTurns()
        let local = [repeatTurn, localMiddle, repeatTurn]
        let restored = [repeatTurn, serverMiddle, repeatTurn]
        XCTAssertEqual(afterFirst, restored + local)

        let second = Task { try await service.retryMemoryOperation() }
        await server.waitUntilBlocked("empty")
        await service.recordExternalTurn(prompt: duringEmpty.prompt, response: duringEmpty.response)
        await server.release("empty")
        try await second.value
        let afterEmpty = await service.recentTurns()
        XCTAssertEqual(afterEmpty, local + [duringEmpty])

        for expected in [restored + local + [duringEmpty], restored + local + [duringEmpty], local + [duringEmpty]] {
            try await service.retryMemoryOperation()
            let actual = await service.recentTurns()
            XCTAssertEqual(actual, expected)
        }
        let requests = await server.requests.map { $0.url.path }
        XCTAssertEqual(requests, Array(repeating: "/api/sessions/catrobot-old/messages", count: 5))
    }

    func testReturnToOriginalOriginDiscardsItsOldLocalEventsAndPendingHistory() async throws {
        let other = HermesConnection(endpoint: URL(string: "https://other.test")!,
                                     credential: HermesCredential(apiKey: "synthetic-other"))
        let connections = ProbeSequenced([connection, connection, other, connection, connection])
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin,
                                                                         sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(history: [.gated("stale", .json(200, #"""
            {"session_id":"stale-tip","data":[
              {"role":"user","content":"stale"},{"role":"assistant","content":"stale"}]}
            """#))])
        let service = HermesConversationService(connection: { connections.next() }, transport: server, records: records,
                                                clock: SteppingHermesClock(), makeSessionID: { "catrobot-new" })
        await service.recordExternalTurn(prompt: "first A", response: "local")
        let old = Task { try await service.prepareMemory() }
        await server.waitUntilBlocked("stale")
        await service.recordExternalTurn(prompt: "B", response: "local")
        let inB = await service.recentTurns()
        XCTAssertEqual(inB, [.init(prompt: "B", response: "local")])
        await service.recordExternalTurn(prompt: "second A", response: "local")
        try await service.prepareMemory()
        await server.release("stale")
        try await old.value
        let inA = await service.recentTurns()
        XCTAssertEqual(inA, [.init(prompt: "second A", response: "local")])
        let record = await records.record
        XCTAssertEqual(record?.origin, connection.origin)
        XCTAssertEqual(record?.sessionID, "catrobot-new")
    }

    func testPendingPrepareCannotMixTurnsAcrossResetOrOriginSwitch() async throws {
        for switchOrigin in [false, true] {
            let other = HermesConnection(endpoint: URL(string: "https://other.test")!,
                                         credential: HermesCredential(apiKey: "synthetic-other"))
            let connections = ProbeSequenced([connection, switchOrigin ? other : connection])
            let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin,
                                                                             sessionID: "catrobot-old", hasTurns: true))
            let server = FakeHermesServer(history: [.gated("history", .json(200, #"""
                {"session_id":"catrobot-stale-tip","data":[
                  {"role":"user","content":"stale"},{"role":"assistant","content":"stale"}]}
                """#))])
            let service = HermesConversationService(connection: { connections.next() }, transport: server, records: records,
                                                    clock: SteppingHermesClock(), makeSessionID: { "catrobot-new" })
            let restore = Task { try await service.prepareMemory() }
            await server.waitUntilBlocked("history")
            let blocked = await server.isBlocked("history")
            XCTAssertTrue(blocked)
            if !switchOrigin { await service.reset() }
            let expected = ConversationMemoryTurn(prompt: "replacement", response: "keep only this")
            await service.recordExternalTurn(prompt: expected.prompt, response: expected.response)
            await server.release("history")
            try await restore.value
            let actual = await service.recentTurns()
            let record = await records.record
            XCTAssertEqual(actual, [expected])
            XCTAssertEqual(record?.sessionID, "catrobot-new")
            XCTAssertEqual(record?.origin, switchOrigin ? other.origin : connection.origin)
        }
    }

    func testDelayedSameTipHistorySuccessKeepsAConcurrentAppend() async throws {
        try await checkDelayedHistory(.json(200, #"{"session_id":"catrobot-old","data":[{"role":"user","content":"old prompt"},{"role":"assistant","content":"old reply"}]}"#),
                                      expected: ["old reply", "concurrent reply"])
    }

    func testDelayedSameTipHistoryFailureKeepsAConcurrentAppend() async throws {
        try await checkDelayedHistory(.transportFailure, expected: ["concurrent reply"])
    }

    private func checkDelayedHistory(_ reply: FakeHermesServer.Reply, expected: [String]) async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin,
                                                                         sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(history: [.gated("history", reply)])
        let service = makeService(server, records: records)
        let restore = Task { try await service.prepareMemory() }
        await server.waitUntilBlocked("history")
        let held = await server.isBlocked("history")
        XCTAssertTrue(held)
        await service.recordExternalTurn(prompt: "concurrent prompt", response: "concurrent reply")
        await server.release("history")
        try await restore.value
        let turns = await service.recentTurns()
        XCTAssertEqual(turns.map(\.response), expected)
        let record = await records.record
        XCTAssertEqual(record?.sessionID, "catrobot-old")
    }

    func testTypedNotFoundSettlesAnActiveRunWithoutPollingAgainOrStopping() async throws {
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [hermesAccepted("lost")],
                                      polls: ["lost": [.json(404, #"{"error":{"code":"run_not_found"}}"#),
                                                       hermesRun("lost", "completed", output: "unexpected")]])
        let service = makeService(server, records: records)
        do {
            let output = try await probeCollect(try await service.streamReply(to: "prompt"))
            XCTFail("missing run returned \(output)")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed)
        }
        let paths = await server.requests.map(\.url.path)
        XCTAssertEqual(paths, ["/v1/runs", "/v1/runs/lost"])
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, [])
    }

    func testUnclassifiedPoll404RetriesWithTheRunStillRecorded() async throws {
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [hermesAccepted("run")],
                                      polls: ["run": [.json(404, #"{"detail":"unknown"}"#),
                                                      .gated("retry", hermesRun("run", "completed", output: "survived"))]])
        let service = makeService(server, records: records)
        let stream = try await service.streamReply(to: "prompt")
        let reader = Task { try await probeCollect(stream) }
        await server.waitUntilBlocked("retry")
        let held = await server.isBlocked("retry")
        let pending = await records.record
        await server.release("retry")
        XCTAssertTrue(held)
        XCTAssertEqual(pending?.unsettledRunIDs, ["run"])
        let output = try await boundedValue(of: reader)
        XCTAssertEqual(output, ["survived"])
        let settled = await records.record
        XCTAssertEqual(settled?.unsettledRunIDs, [])
    }

    func testLateReplyAfterReturningToAnOriginCannotTouchTheNewConversation() async throws {
        let other = HermesConnection(endpoint: URL(string: "https://other.test")!,
                                     credential: HermesCredential(apiKey: "other-key"))
        let connections = ProbeSequenced([connection, other, connection])
        let ids = ProbeSequenced(["catrobot-a", "catrobot-b", "catrobot-a-new"])
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [hermesAccepted("run-a")],
                                      polls: ["run-a": [.gated("poll-a", hermesRun("run-a", "completed", output: "old"))]])
        let service = HermesConversationService(connection: { connections.next() }, transport: server,
                                                records: records, clock: SteppingHermesClock(),
                                                makeSessionID: { ids.next() })
        let stream = try await service.streamReply(to: "old turn")
        let reader = Task { try await probeCollect(stream) }
        await server.waitUntilBlocked("poll-a")
        _ = try await service.transcript()
        _ = try await service.transcript()
        await server.release("poll-a")
        do {
            let reply = try await reader.value
            XCTAssertTrue(reply.isEmpty, "a superseded reply must not be published")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .cancelled)
        }
        let state = await service.memoryState()
        XCTAssertEqual(state, .unprepared)
        let record = await records.record
        XCTAssertEqual(record?.sessionID, "catrobot-a-new")
        XCTAssertEqual(record?.hasTurns, false)
    }

    func testReplyWaitsForPreparationOfTipAdoptedByTranscript() async throws {
        let current = connection
        let lookups = RaceConnection(current)
        let clock = RaceTurnClock()
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: current.origin,
                                                                         sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(runs: [.gated("post", hermesAccepted("run-new"))],
                                      polls: ["run-new": [hermesRun("run-new", "completed", output: "reply")]],
                                      history: [
            .gated("old", .json(200, #"{"session_id":"stale-tip","data":[]}"#)),
            .json(200, #"{"session_id":"current-tip","data":[{"role":"user","content":"settings"}]}"#),
            .gated("current", .json(200, #"""
            {"session_id":"current-tip","data":[
              {"role":"user","content":"latest"},{"role":"assistant","content":"restored"}]}
            """#))
        ])
        let service = HermesConversationService(connection: { await lookups.resolve() }, transport: server,
                                                records: records, clock: clock)
        let prepare = Task { try await service.prepareMemory() }
        let oldHeld = await raceEventually { await server.isBlocked("old") }
        XCTAssertTrue(oldHeld)
        let transcript = try? await service.transcript()
        XCTAssertEqual(transcript?.map(\.text), ["settings"])

        let reply = Task { try await probeCollect(try await service.streamReply(to: "new input")) }
        let queued = await raceEventually { await lookups.count == 3 }
        XCTAssertTrue(queued)
        await server.release("old")
        let progressed = await raceEventually {
            if await server.isBlocked("current") { return true }
            return await server.isBlocked("post")
        }
        XCTAssertTrue(progressed, "neither the latest history nor submission reached the transport")
        let before = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(before, ["GET /api/sessions/catrobot-old/messages", "GET /api/sessions/catrobot-old/messages",
                                "GET /api/sessions/current-tip/messages"])

        await server.release("current")
        let posted = await raceEventually { await server.isBlocked("post") }
        XCTAssertTrue(posted)
        let cache = await service.recentTurns()
        XCTAssertEqual(cache, [.init(prompt: "latest", response: "restored")])
        let posts = await server.runPosts
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.url.absoluteString, "https://hermes.test:8443/v1/runs")
        XCTAssertEqual(posts.first?.jsonBody?["session_id"], "current-tip")
        XCTAssertEqual(posts.first?.jsonBody?["input"], "new input")
        if !posted { await clock.advanceToDeadline(); reply.cancel(); prepare.cancel() }
        await server.release("post")
        let outcome = await reply.result
        _ = await prepare.result
        XCTAssertEqual(try outcome.get(), ["reply"])
        let after = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(after, before + ["POST /v1/runs", "GET /v1/runs/run-new"])
    }

    func testRacedReplyDoesNotSubmitAfterReset() async {
        await checkTipRaceTermination(.reset)
    }

    func testRacedReplyDoesNotSubmitToAReplacementOrigin() async {
        await checkTipRaceTermination(.changedOrigin)
    }

    func testRacedReplyDoesNotSubmitWhenLatestHistoryFails() async {
        await checkTipRaceTermination(.failure)
    }

    func testRacedReplyExpiresWhileLatestHistoryIsHeld() async {
        await checkTipRaceTermination(.expired)
    }

    func testCancelledRacedReplyDoesNotCancelSharedPreparation() async {
        await checkTipRaceTermination(.cancelledReply)
    }

    func testCancelledRacedPreparationDoesNotReleaseAReplyToSubmit() async {
        await checkTipRaceTermination(.cancelledPreparation)
    }

    func testTipMotionDuringThePreSubmissionSavePreventsPostingTheStaleTip() async {
        await checkTipRaceTermination(.movesBeforePost)
    }

    func testRepeatedTipMotionExhaustsThePreparationRetryWithoutPosting() async {
        await checkTipRaceTermination(.movesAgain)
    }

    private enum TipRaceTermination {
        case reset, changedOrigin, failure, expired, cancelledReply, cancelledPreparation, movesBeforePost, movesAgain
    }

    private func checkTipRaceTermination(_ termination: TipRaceTermination) async {
        let current = connection
        let lookups = RaceConnection(current)
        let clock = RaceTurnClock()
        let records = HeldSubmissionRecordStore(HermesSessionRecord(origin: current.origin,
                                                                    sessionID: "catrobot-old", hasTurns: true),
                                                holdSubmission: termination == .movesBeforePost)
        let latest = FakeHermesServer.Reply.json(200, #"""
            {"session_id":"current-tip","data":[
              {"role":"user","content":"latest"},{"role":"assistant","content":"restored"}]}
            """#)
        let server = FakeHermesServer(runs: [.json(400, "{}")], history: [
            .gated("old", .json(200, #"{"session_id":"stale-tip","data":[]}"#)),
            .json(200, #"{"session_id":"current-tip","data":[]}"#),
            .gated("current", termination == .failure ? .transportFailure : latest),
            .json(200, #"{"session_id":"later-tip","data":[{"role":"user","content":"later"}]}"#)
        ])
        let service = HermesConversationService(connection: { await lookups.resolve() }, transport: server,
                                                records: records, clock: clock, makeSessionID: { "replacement" })
        let prepare = Task { try await service.prepareMemory() }
        let oldHeld = await raceEventually { await server.isBlocked("old") }
        XCTAssertTrue(oldHeld)
        _ = try? await service.transcript()
        let settled = RaceReplyResult()
        let reply = Task {
            do {
                let result = try await probeCollect(try await service.streamReply(to: "new input"))
                await settled.set(.success(result))
            } catch {
                await settled.set(.failure(error))
            }
        }
        // Wait for the reply's preparation timer. The old GET is still held at this point.
        let waiting = await raceEventually { await clock.deadlineSleeps == 1 }
        XCTAssertTrue(waiting)
        if termination == .expired { await clock.advance(89) }
        await server.release("old")
        let latestHeld = await raceEventually { await server.isBlocked("current") }
        XCTAssertTrue(latestHeld)
        let before = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(before, ["GET /api/sessions/catrobot-old/messages", "GET /api/sessions/catrobot-old/messages",
                                "GET /api/sessions/current-tip/messages"])

        let sharedPreparation = termination == .cancelledReply ? Task { try await service.prepareMemory() } : nil
        if sharedPreparation != nil {
            let joined = await raceEventually { await lookups.count == 4 }
            XCTAssertTrue(joined)
        }

        switch termination {
        case .reset:
            await service.reset()
        case .changedOrigin:
            let other = HermesConnection(endpoint: URL(string: "https://other.test/")!,
                                         credential: HermesCredential(apiKey: "synthetic-other"))
            await lookups.replace(with: other)
            _ = try? await service.transcript()
        case .expired:
            await clock.advance(1)
        case .cancelledReply:
            reply.cancel()
        case .cancelledPreparation:
            prepare.cancel()
        case .movesBeforePost:
            await server.release("current")
            let saving = await raceEventually { await records.isHoldingSubmission }
            XCTAssertTrue(saving)
            let laterRead = Task { try await service.transcript() }
            let moved = await raceEventually { await service.memoryState() == .unprepared }
            XCTAssertTrue(moved)
            await records.releaseSubmission()
            let later = try? await laterRead.value
            XCTAssertEqual(later?.map(\.text), ["later"])
        case .movesAgain:
            let later = try? await service.transcript()
            XCTAssertEqual(later?.map(\.text), ["later"])
        case .failure:
            break
        }

        if [.reset, .changedOrigin, .expired, .cancelledReply].contains(termination) {
            let finishedWhileHistoryHeld = await raceEventually { await settled.outcome != nil }
            XCTAssertTrue(finishedWhileHistoryHeld)
        }
        await server.release("current")
        await records.releaseSubmission()
        let finished = await raceEventually { await settled.outcome != nil }
        XCTAssertTrue(finished)
        if !finished { reply.cancel(); await clock.advanceToDeadline() }
        let preparation = await prepare.result
        if let sharedPreparation {
            switch await sharedPreparation.result {
            case .success: break
            case .failure(let error): XCTFail("shared preparation failed: \(error)")
            }
        }
        let outcome = await settled.outcome
        switch (termination, outcome) {
        case (.reset, .failure(let error)), (.changedOrigin, .failure(let error)):
            XCTAssertEqual(error as? ConversationServiceError, .cancelled)
        case (.expired, .failure(let error)):
            XCTAssertEqual(error as? ConversationServiceError, .replyTimedOut)
        case (.cancelledReply, .failure(let error)):
            XCTAssertTrue(error is CancellationError)
            let restored = await service.recentTurns()
            XCTAssertEqual(restored, [.init(prompt: "latest", response: "restored")])
        case (.failure, .failure(let error)), (.cancelledPreparation, .failure(let error)),
             (.movesBeforePost, .failure(let error)), (.movesAgain, .failure(let error)):
            XCTAssertEqual(error as? ConversationMemoryError, .unavailable)
            let fresh = await Task { try await service.streamReply(to: "must not submit") }.result
            switch fresh {
            case .failure(let error): XCTAssertEqual(error as? ConversationMemoryError, .unavailable)
            case .success: XCTFail("fresh reply bypassed required preparation")
            }
            if termination == .cancelledPreparation {
                switch preparation {
                case .failure(let error): XCTAssertTrue(error is CancellationError)
                case .success: XCTFail("cancelled preparation returned success")
                }
            }
        default:
            XCTFail("unexpected reply outcome \(String(describing: outcome))")
        }
        let requests = await server.requests.map { "\($0.method) \($0.url.path)" }
        let moved = termination == .movesBeforePost || termination == .movesAgain
        XCTAssertEqual(requests, moved ? before + ["GET /api/sessions/current-tip/messages"] : before)
        let posts = await server.runPosts
        XCTAssertTrue(posts.isEmpty)
    }

    func testLateHistoryCannotReplaceTheTipAdoptedWhileItWasPending() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old",
                                                                         hasTurns: true))
        let server = FakeHermesServer(history: [
            .gated("old-history", .json(200, #"{"session_id":"catrobot-old-tip","data":[{"role":"user","content":"old"}]}"#)),
            .json(200, #"{"session_id":"catrobot-new-tip","data":[{"role":"user","content":"new"}]}"#)
        ])
        let service = makeService(server, records: records)
        let old = Task { try await service.transcript() }
        await server.waitUntilBlocked("old-history")
        let current = try await service.transcript()
        await server.release("old-history")

        let stale = try await old.value
        let record = await records.record
        XCTAssertEqual(current.map(\.text), ["new"])
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(record?.sessionID, "catrobot-new-tip")
    }

    func testCompactionWhileSubmissionIsPendingPreservesTheReplyAndNextTip() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old"))
        let server = FakeHermesServer(runs: [.gated("post", hermesAccepted("run-a")), hermesAccepted("run-b")],
                                      polls: ["run-a": [hermesRun("run-a", "completed", output: "first")],
                                              "run-b": [hermesRun("run-b", "completed", output: "second")]],
                                      history: [.json(200, #"{"session_id":"catrobot-tip","data":[]}"#)])
        let service = makeService(server, records: records)
        let stream = try await service.streamReply(to: "first turn")
        await server.waitUntilBlocked("post")
        _ = try await service.transcript()
        await server.release("post")

        let result = await Task { try await probeCollect(stream) }.result
        switch result {
        case .success(let reply): XCTAssertEqual(reply, ["first"])
        case .failure(let error): XCTFail("compaction discarded the active reply: \(error)")
        }
        let record = await records.record
        XCTAssertEqual(record?.sessionID, "catrobot-tip")
        XCTAssertEqual(record?.hasTurns, true)
        XCTAssertEqual(record?.hasUncertainSubmission, false)
        XCTAssertEqual(record?.unsettledRunIDs, [])

        let next = try await probeCollect(try await service.streamReply(to: "second turn"))
        XCTAssertEqual(next, ["second"])
        let sessions = await server.runPosts.compactMap { $0.jsonBody?["session_id"] }
        XCTAssertEqual(sessions, ["catrobot-old", "catrobot-tip"])
    }

    func testCleanupTimeoutLetsSubmissionProceedBeforeLateRefusal() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old",
                                                                         unsettledRunIDs: ["pending"]))
        let server = FakeHermesServer(runs: [hermesAccepted("run-new"), hermesAccepted("run-next")],
                                      polls: ["run-new": [hermesRun("run-new", "completed", output: "new")],
                                              "run-next": [hermesRun("run-next", "completed", output: "next")]],
                                      stops: ["pending": [.gated("cleanup", .json(401, "{}"))]])
        let current = connection
        let service = HermesConversationService(connection: { current }, transport: server, records: records,
                                                clock: SteppingHermesClock(),
                                                timing: HermesConversationTiming(turnDeadline: .milliseconds(400)))
        let stream = try await service.streamReply(to: "new turn")
        let reader = Task { try await probeCollect(stream) }
        await server.waitUntilBlocked("cleanup")
        await server.waitForRequest { $0.url.path == "/v1/runs" }
        let posts = await server.runPosts
        XCTAssertEqual(posts.count, 1, "submission must proceed while cleanup still ignores cancellation")
        if !posts.isEmpty {
            let reply = try await reader.value
            XCTAssertEqual(reply, ["new"])
            // The same stuck request must not spawn more cleanup on a later turn.
            let next = try await service.streamReply(to: "another turn")
            let nextReply = try await probeCollect(next)
            XCTAssertEqual(nextReply, ["next"])
        }
        let paths = await server.requests.map(\.url.path)
        XCTAssertEqual(paths.filter { $0.contains("/pending") }, ["/v1/runs/pending/stop"])
        await server.release("cleanup")
        _ = await reader.result
        for _ in 0..<400 {
            if await service.availability() == .hermesUnauthorized { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let availability = await service.availability()
        let record = await records.record
        XCTAssertEqual(availability, .hermesUnauthorized)
        XCTAssertEqual(record?.unsettledRunIDs, ["pending"])
    }

    func testCleanupReservesTimeForTheNewConversationToSubmit() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old",
                                                                         unsettledRunIDs: ["pending"]))
        let clock = SteppingHermesClock()
        let server = FakeHermesServer(runs: [hermesAccepted("run-new")],
                                      polls: ["run-new": [hermesRun("run-new", "completed", output: "new")]])
        let current = connection
        let service = HermesConversationService(connection: { current }, transport: SlowCleanup(clock: clock, server: server),
                                                records: records, clock: clock,
                                                timing: HermesConversationTiming(turnDeadline: .seconds(10)),
                                                makeSessionID: { "catrobot-new" })
        await service.reset()
        let replies = try await probeCollect(try await service.streamReply(to: "new turn"))
        XCTAssertEqual(replies, ["new"])
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["pending"])
        let posts = await server.runPosts
        XCTAssertEqual(posts.first?.jsonBody?["session_id"], "catrobot-new")
    }

    func testPostRefusalIsVisibleWhileTheRecordSaveIsPending() async throws {
        let store = RefusalSaveGate(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old"))
        let server = FakeHermesServer(runs: [.json(401, "{}")],
                                      capabilities: [.json(200, "{}")])
        let current = connection
        let service = HermesConversationService(connection: { current }, transport: server, records: store,
                                                clock: SteppingHermesClock())
        let stream = try await service.streamReply(to: "test turn")
        let consumer = Task { try await probeCollect(stream) }
        await store.waitForRefusalSave()
        let blocked = await store.isBlocked
        let availability = await service.availability()
        await service.recheckAvailability()
        await store.release()
        XCTAssertTrue(blocked, "readiness is observed during the pending save")
        XCTAssertEqual(availability, .hermesUnauthorized)
        guard case .failure(let error) = await consumer.result else { return XCTFail("the turn must be refused") }
        XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        let rechecked = await service.availability()
        XCTAssertEqual(rechecked, .available, "finishing the save must not undo the successful manual recheck")
        let paths = await server.requests.map(\.url.path)
        XCTAssertEqual(paths, ["/v1/runs", "/v1/capabilities"])
    }

    /// 文字入力の置き換え・声の割り込みの直後: 取り消したターンの worker が要求の応答待ちでも、次のターンは busy で拒否されない。
    func testANewTurnRightAfterACancelledOneIsNotRefusedAsBusy() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-1"), hermesAccepted("run-2")],
                                      polls: ["run-1": [.gated("poll", hermesRun("run-1", "completed", output: "古い"))],
                                              "run-2": [hermesRun("run-2", "completed", output: "新しい")]])
        let service = makeService(server)
        let stream = try await service.streamReply(to: "古い質問")
        let consumer = Task { try await probeCollect(stream) }
        await server.waitUntilBlocked("poll")
        consumer.cancel()
        _ = try? await consumer.value
        let release = Task { try? await Task.sleep(for: .milliseconds(200)); await server.release("poll") }
        do {
            let outputs = try await probeCollect(try await service.streamReply(to: "新しい質問"))
            XCTAssertEqual(outputs, ["新しい"])
        } catch {
            XCTFail("next turn failed: \(error)")
        }
        _ = await release.value
    }

    /// installed Hermes 自身の表示は display_kind != "hidden"（api_server_openai_routes.py:1592）。それ以外の kind の行も消さない。
    func testOnlyRowsHermesHidesAreLeftOutOfTheTranscript() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(history: [.json(200, #"""
            {"object":"list","session_id":"catrobot-old","data":[
              {"role":"user","content":"こんにちは","display_kind":"message"},
              {"role":"assistant","content":"やあ","display_kind":"message"},
              {"role":"assistant","content":"","display_kind":"hidden"}
            ]}
            """#)])
        let transcript = try await makeService(server, records: records).transcript()
        XCTAssertEqual(transcript.map(\.text), ["こんにちは", "やあ"])
    }

    /// 履歴の応答の session_id（compaction の tip）が path に使えない値なら、記録の session を差し替えない。
    func testAnUnusableTipFromHistoryDoesNotReplaceTheSession() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")], polls: ["run-1": [hermesRun("run-1", "completed", output: "うん")]],
                                      history: [.json(200, #"{"object":"list","session_id":"../escape","data":[]}"#)])
        let service = makeService(server, records: records)
        try await service.prepareMemory()
        let saved = await records.record
        XCTAssertEqual(saved?.sessionID, "catrobot-old")
    }

    /// 次のターンは取り消したターンの worker の終了を待つ。その worker は送信中の 1 本を終えたら後始末を続けない。
    func testCancellationDuringCleanupStopsAfterTheRequestInFlight() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old",
                                                                         hasTurns: true, unsettledRunIDs: ["run-a", "run-b"]))
        let server = FakeHermesServer(runs: [hermesAccepted("run-never")],
                                      stops: ["run-a": [.gated("stop-a", .json(200, #"{"run_id":"run-a","status":"stopping"}"#))]])
        let service = makeService(server, records: records)
        let stream = try await service.streamReply(to: "ねえ")
        let consumer = Task { try await probeCollect(stream) }
        await server.waitUntilBlocked("stop-a")
        consumer.cancel()
        _ = try? await consumer.value
        await server.release("stop-a")
        try await Task.sleep(for: .milliseconds(200))
        let calls = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(calls, ["POST /v1/runs/run-a/stop"], "no further cleanup and no submission once the turn is cancelled")
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["run-a", "run-b"], "runs not confirmed ended stay recorded")
    }
}

private func probeCollect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var values: [String] = []
    for try await value in stream { values.append(value) }
    return values
}

private final class ProbeSequenced<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]
    init(_ values: [Value]) { self.values = values }
    func next() -> Value { lock.withLock { values.count > 1 ? values.removeFirst() : values[0] } }
}


private struct SlowCleanup: HermesTransport {
    let clock: SteppingHermesClock
    let server: FakeHermesServer

    func send(_ request: HermesHTTPRequest) async throws -> HermesHTTPResponse {
        if request.url.path.contains("/pending") {
            try await clock.sleep(for: .seconds(min(10, request.timeout)))
            throw HermesClientError.transport("synthetic timeout")
        }
        return try await server.send(request)
    }
}

private actor RefusalSaveGate: HermesSessionRecordStore {
    let initial: HermesSessionRecord
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    init(_ initial: HermesSessionRecord) { self.initial = initial }
    func load() -> HermesSessionRecord? { initial }
    var isBlocked: Bool { gate != nil }
    func save(_ record: HermesSessionRecord?) async {
        guard !released, record?.hasUncertainSubmission == false else { return }
        await withCheckedContinuation { gate = $0 }
    }
    func waitForRefusalSave() async {
        for _ in 0..<400 where !isBlocked { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}


private actor ManualTurnClock: HermesClock {
    private var current = Date(timeIntervalSince1970: 10_000)

    func now() -> Date { current }

    func advance(_ seconds: TimeInterval) { current += seconds }

    func sleep(for duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        try await sleepUntilTurnDeadline(current.addingTimeInterval(seconds))
    }

    func sleepUntilTurnDeadline(_ deadline: Date) async throws {
        while current < deadline { try await Task.sleep(for: .milliseconds(1)) }
    }
}


private func raceEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private actor RaceConnection {
    private var connection: HermesConnection
    private(set) var count = 0

    init(_ connection: HermesConnection) { self.connection = connection }

    func replace(with replacement: HermesConnection) { connection = replacement }

    func resolve() -> HermesConnection {
        count += 1
        return connection
    }
}

private actor RaceTurnClock: HermesClock {
    private(set) var deadlineSleeps = 0
    private var current = Date(timeIntervalSince1970: 10_000)

    func now() -> Date { current }
    func advanceToDeadline() { advance(90) }
    func advance(_ seconds: TimeInterval) { current += seconds }
    func sleep(for duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        try await sleepUntilTurnDeadline(current.addingTimeInterval(seconds))
    }
    func sleepUntilTurnDeadline(_ deadline: Date) async throws {
        deadlineSleeps += 1
        while current < deadline {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}


private actor RaceReplyResult {
    private(set) var outcome: Result<[String], Error>?
    func set(_ outcome: Result<[String], Error>) { self.outcome = outcome }
}

private actor HeldSubmissionRecordStore: HermesSessionRecordStore {
    private var record: HermesSessionRecord?
    private var holdSubmission: Bool
    private var submission: CheckedContinuation<Void, Never>?

    init(_ record: HermesSessionRecord, holdSubmission: Bool) {
        self.record = record
        self.holdSubmission = holdSubmission
    }

    func load() -> HermesSessionRecord? { record }
    func save(_ record: HermesSessionRecord?) async {
        if holdSubmission, record?.hasUncertainSubmission == true {
            await withCheckedContinuation { submission = $0 }
        }
        self.record = record
    }

    var isHoldingSubmission: Bool { submission != nil }

    func releaseSubmission() {
        holdSubmission = false
        submission?.resume()
        submission = nil
    }
}
