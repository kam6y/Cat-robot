import Foundation
import Observation

/// 設定の「呼びかけ」を声で入力するための、一回だけの聞き取り。会話と同じ認識器と音声の session を使う。
/// 設定のシートは会話の聞き取りと読み上げを止めてから開き、閉じるときはここがマイクを手放し終わってから
/// 会話の聞き取りに戻る（ConversationAppCoordinator）。使えるのはその間だけなので、会話とマイクを取り合わない。
@MainActor @Observable
final class WakePhraseRecorder {
    enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        /// 聞いている途中。値はそこまでの書き起こし（確定していない部分を含む）。
        case listening(String)
        case failed(Failure)
    }

    enum Failure: Equatable, Sendable {
        case microphoneDenied
        case notHeard
        case unavailable
    }

    /// 言い終わりが分からなくても、ここで聞き取りを止める。
    static let listeningLimit: Duration = .seconds(8)

    private(set) var state: State = .idle
    /// coordinator が決める。設定のシートを出し切っていて、閉じる途中でなく、場面が前面のときだけ true。
    private(set) var isAvailable = false
    /// 権限の確認か聞き取りの途中。画面の「やめる」と入力欄の無効化に使う。
    var isBusy: Bool {
        switch state {
        case .requestingPermission, .listening: true
        case .idle, .failed: false
        }
    }
    /// マイクを手放し終わっていない。閉じるときに待つかどうかの判断に使う。
    var isRecording: Bool { task != nil }

    @ObservationIgnored private let recognizer: any SpeechRecognizing
    @ObservationIgnored private let audioSession: any AudioSessionControlling
    @ObservationIgnored private let permission: any MicrophoneAuthorizing
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var task: Task<String?, Never>?

    init(
        recognizer: any SpeechRecognizing,
        audioSession: any AudioSessionControlling,
        permission: any MicrophoneAuthorizing,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in try? await Task.sleep(for: duration) }
    ) {
        self.recognizer = recognizer
        self.audioSession = audioSession
        self.permission = permission
        self.sleep = sleep
    }

    func setAvailable(_ available: Bool) {
        isAvailable = available
        if available {
            if case .failed = state { state = .idle }
        } else if state != .requestingPermission {
            // 権限の確認を出している間は場面が inactive になる。答えを待ち、その後で isAvailable を見直す。
            task?.cancel()
        }
    }

    /// 一回だけ聞き取り、書き起こしを返す。使えないとき・取り消したとき・失敗したときは nil（失敗は state に残す）。
    func record() async -> String? {
        guard isAvailable, task == nil else { return nil }
        let task = Task { await self.capture() }
        self.task = task
        return await task.value
    }

    /// 聞き取りを止め、認識器と音声の session を手放し終わるまで待つ。何度呼んでもよい。
    func cancel() async {
        guard let task else {
            if case .failed = state { state = .idle }
            return
        }
        task.cancel()
        _ = await task.value
    }

    private func capture() async -> String? {
        state = .requestingPermission
        guard await permission.requestAccess() else { return finish(.failed(.microphoneDenied)) }
        guard isAvailable, !Task.isCancelled else { return finish(.idle) }
        state = .listening("")
        do {
            try await audioSession.activate()
        } catch {
            await audioSession.deactivate()
            return finish(Task.isCancelled ? .idle : .failed(.unavailable))
        }
        let finalized: String?
        do {
            try await recognizer.prepare()
            try Task.checkCancellation()
            let events = try await recognizer.start()
            finalized = await collect(events)
        } catch {
            await recognizer.stop()
            await audioSession.deactivate()
            return finish(Task.isCancelled ? .idle : .failed(.unavailable))
        }
        await audioSession.deactivate()
        guard !Task.isCancelled else { return finish(.idle) }
        guard let finalized else { return finish(.failed(.unavailable)) }
        let heard = SpeechVoiceSettings.cleanedWakePhrase(finalized)
        guard !heard.isEmpty else { return finish(.failed(.notHeard)) }
        return finish(.idle, heard: heard)
    }

    /// 複数の認識結果を一つの呼びかけとして集め、言い終わり、無音、または制限時間で止める。
    /// stop で最後に確定した書き起こしまで読み、認識器の失敗時は nil を返す。
    private func collect(_ events: AsyncThrowingStream<SpeechRecognitionEvent, Error>) async -> String? {
        let (stops, stopSignal) = AsyncStream<Void>.makeStream()
        let reader = Task { () -> String? in
            var segmenter = UtteranceSegmenter()
            var silence: Task<Void, Never>?
            defer {
                silence?.cancel()
                stopSignal.yield()
            }
            do {
                for try await event in events {
                    let timestamp = ProcessInfo.processInfo.systemUptime
                    if let endpoint = event.audioTurnEnd {
                        if segmenter.hasAudioEndpointActivity, endpoint.isValid(at: timestamp) { stopSignal.yield() }
                        continue
                    }
                    let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    segmenter.receive(event, at: timestamp)
                    let finalized = segmenter.finalizedText
                    self.showHeard(finalized + (event.isFinal ? "" : text))
                    silence?.cancel()
                    if !finalized.isEmpty {
                        let delay = segmenter.silenceInterval
                        silence = Task {
                            try? await Task.sleep(for: .seconds(delay))
                            if !Task.isCancelled { stopSignal.yield() }
                        }
                    }
                }
                return segmenter.finalizedText
            } catch {
                return nil
            }
        }
        let limit = Self.listeningLimit
        let timer = Task { [sleep] in
            await sleep(limit)
            stopSignal.yield()
        }
        // 取り消されたときも、ここは待たずに抜ける（AsyncStream は task の取り消しで終わる）。
        for await _ in stops { break }
        timer.cancel()
        await recognizer.stop()
        let finals = await reader.value
        stopSignal.finish()
        return finals
    }

    private func showHeard(_ text: String) {
        guard case .listening = state else { return }
        state = .listening(text)
    }

    private func finish(_ next: State, heard: String? = nil) -> String? {
        state = next
        task = nil
        return heard
    }

}
