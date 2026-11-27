import SwiftUI
import UIKit
import XCTest
@testable import CatRobot

/// 設定「声と待機時間」の呼びかけの欄。声で入力した言葉は入力欄に入るだけで、保存を押すまで使わない。
@MainActor
final class WakePhraseSettingsTests: XCTestCase {
    @MainActor private struct Fixture {
        let log: ConversationTestCallLog
        let recognizer: FakeSpeechRecognizer
        let recorder: WakePhraseRecorder
        let voice: SpeechVoiceSettings
        let defaults: UserDefaults
        let defaultsName: String
        let host: UIViewController
        let window: UIWindow
        var view: UIView { host.view }
    }

    /// 設定を「声と待機時間」で開く。標準の文字サイズなので、左にカテゴリ、右にその中身が並ぶ。後片付けは release(_:)。
    private func openSettings() async throws -> Fixture {
        await enableAccessibilityRuntime()
        let log = ConversationTestCallLog()
        let recognizer = FakeSpeechRecognizer(log: log)
        let recorder = WakePhraseRecorder(recognizer: recognizer, audioSession: FakeConversationAudioSession(log: log),
                                          permission: FakeMicrophonePermission(allowed: true, gate: nil, log: log))
        let defaultsName = "wake-phrase-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let voice = SpeechVoiceSettings(defaults: defaults)
        let view = ConversationSettingsView(voiceSettings: voice, idleSettings: ConversationIdleSettings(defaults: defaults),
                                            wakePhraseRecorder: recorder, onDone: {})
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        let fixture = Fixture(log: log, recognizer: recognizer, recorder: recorder, voice: voice, defaults: defaults,
                              defaultsName: defaultsName, host: host, window: window)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        do {
            try await waitForAccessibilityTree(in: host.view)
        } catch {
            release(fixture)
            throw error
        }
        return fixture
    }

    private func release(_ fixture: Fixture) {
        releaseWindow(fixture.window)
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsName)
    }

    private func activate(_ identifier: ConversationSettingsIdentifier, in fixture: Fixture,
                          file: StaticString = #filePath, line: UInt = #line) async throws {
        try await activateAccessibilityElement(in: fixture.view, identifier: identifier.rawValue,
                                               scrollingIn: self.detailScrollView(in: fixture.view), file: file, line: line)
    }

    /// 使えるようにした後、画面に反映されて押せるようになるまで待ってから押す（押せないまま押すと何も起きない）。
    private func startVoiceEntry(in fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        fixture.recorder.setAvailable(true)
        let identifier = ConversationSettingsIdentifier.wakePhraseRecordButton.rawValue
        let enabled = try await waitUntil(settling: fixture.view) {
            guard let button = self.accessibilityElement(in: fixture.view, identifier: identifier) else { return false }
            return !button.accessibilityTraits.contains(.notEnabled)
        }
        XCTAssertTrue(enabled, "声で入力のボタンが押せるようにならない", file: file, line: line)
        guard enabled else { throw VoiceEntryDidNotStart() }
        try await activate(.wakePhraseRecordButton, in: fixture, file: file, line: line)
        // 押せていなければ認識器の開始を待ち続けてしまうので、聞き取りが始まったことを先に確かめる。
        let started = try await waitUntil(settling: fixture.view) { fixture.recorder.isRecording }
        XCTAssertTrue(started, "声で入力を押しても聞き取りが始まらない", file: file, line: line)
        guard started else { throw VoiceEntryDidNotStart() }
        await fixture.recognizer.waitUntilStarted(1)
    }

    private struct VoiceEntryDidNotStart: Error {}

    func testVoiceEntryIsAtTheTrailingEdgeOfTheFieldAndCanStopRecording() async throws {
        let f = try await openSettings()
        defer { release(f) }
        let field = try XCTUnwrap(accessibilityElement(in: f.view, identifier: ConversationSettingsIdentifier.wakePhraseField.rawValue))
        let mic = try XCTUnwrap(accessibilityElement(in: f.view, identifier: ConversationSettingsIdentifier.wakePhraseRecordButton.rawValue))
        let fieldFrame = try accessibilityFrame(of: field, in: f.view)
        let micFrame = try accessibilityFrame(of: mic, in: f.view)
        XCTAssertEqual(fieldFrame.midY, micFrame.midY, accuracy: 2)
        XCTAssertLessThanOrEqual(fieldFrame.maxX, micFrame.minX + 1)
        XCTAssertGreaterThanOrEqual(micFrame.width, 44)
        XCTAssertGreaterThanOrEqual(micFrame.height, 44)
        XCTAssertNotNil(accessibilityElement(in: f.view, label: "声で入力"))

        try await startVoiceEntry(in: f)
        let showsStop = try await waitUntil(settling: f.view) {
            self.accessibilityElement(in: f.view, label: "音声入力を停止") != nil
        }
        XCTAssertTrue(showsStop)
        try await activate(.wakePhraseRecordButton, in: f)
        let stopped = try await waitUntil(settling: f.view) { !f.recorder.isRecording }
        XCTAssertTrue(stopped)
        XCTAssertNotNil(accessibilityElement(in: f.view, label: "声で入力"))
    }

    func testVoiceEntryFillsTheFieldAndIsSavedOnlyAfterConfirmation() async throws {
        let f = try await openSettings()
        defer { release(f) }
        XCTAssertEqual(f.voice.wakePhrase, "キャロット")

        let unavailable = try await reachableAccessibilityElement(in: f.view, identifier: ConversationSettingsIdentifier.wakePhraseRecordButton.rawValue,
                                                                  scrollingIn: self.detailScrollView(in: f.view))
        XCTAssertTrue(try XCTUnwrap(unavailable).element.accessibilityTraits.contains(.notEnabled),
                      "会話がマイクを手放すまで声では入力できない")

        try await startVoiceEntry(in: f)
        await f.recognizer.emit(.finalized("ミケ"))
        let finished = try await waitUntil(settling: f.view) { f.recorder.state == .idle && !f.recorder.isRecording }
        XCTAssertTrue(finished)
        XCTAssertEqual(f.voice.wakePhrase, "キャロット", "声で入力しただけでは保存しない")

        // 音声入力をやり直して失敗しても、入力欄に残った言葉を保存できる。
        try await startVoiceEntry(in: f)
        await f.recognizer.waitUntilStarted(2)
        await f.recognizer.fail(.speechCaptureFailed)
        let failed = try await waitUntil(settling: f.view) { f.recorder.state == .failed(.unavailable) }
        XCTAssertTrue(failed)

        try await activate(.wakePhraseSaveButton, in: f)
        let saved = try await waitUntil(settling: f.view) { f.voice.wakePhrase == "ミケ" }
        XCTAssertTrue(saved, "確かめて保存した言葉を次の発話から使う")
        XCTAssertEqual(SpeechVoiceSettings(defaults: f.defaults).wakePhrase, "ミケ")
        let confirmed = try await waitUntil(settling: f.view) {
            self.accessibilityElement(in: f.view, label: "保存しました。この後の発話から使います。") != nil
        }
        XCTAssertTrue(confirmed)
    }

    func testLeavingTheCategoryWhileListeningStopsOnlyTheVoiceEntry() async throws {
        let f = try await openSettings()
        defer { release(f) }
        try await startVoiceEntry(in: f)

        try await activateAccessibilityElement(in: f.view, identifier: SettingsCategory.about.accessibilityIdentifier)
        let stopped = try await waitUntil(settling: f.view) { !f.recorder.isRecording }
        XCTAssertTrue(stopped, "別のカテゴリへ移ったら声の入力を止める")
        let running = await f.recognizer.isRunning
        XCTAssertFalse(running)
        XCTAssertEqual(f.recorder.state, .idle, "止めただけで失敗は出さない")
        XCTAssertEqual(f.log.values.last, .deactivateAudio)
        XCTAssertEqual(f.voice.wakePhrase, "キャロット")
    }
}
