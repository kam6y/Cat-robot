import Observation
import SwiftUI

/// 設定「会話の履歴」の状態。履歴の正本は Hermes にあり、開くたびに読む（この iPhone には保存しない）。
@MainActor @Observable
final class ConversationHistoryModel {
    enum Phase: Equatable {
        case loading
        case loaded([HermesTranscriptEntry])
        case unconfigured
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    @ObservationIgnored private let reader: any ConversationTranscriptReading

    init(reader: any ConversationTranscriptReading) { self.reader = reader }

    func reload() async {
        phase = .loading
        do {
            phase = .loaded(try await reader.transcript())
        } catch ConversationServiceError.modelUnavailable(.hermesNotConfigured) {
            phase = .unconfigured
        } catch ConversationServiceError.modelUnavailable(.hermesUnauthorized) {
            phase = .failed("Hermes が API キーを受け付けませんでした。「Hermes 接続」でキーを確かめるか、Hermes 側を直してから会話の画面で「もう一度確認」を押してください。")
        } catch is ConversationMemoryError {
            phase = .failed("前の会話を Hermes から読み込めませんでした。会話の画面の「新しい会話を始める」で新しい会話へ移れます。")
        } catch {
            phase = .failed("履歴を読み込めませんでした。通信を確認して、もう一度読み込んでください。")
        }
    }
}

/// 設定「会話の履歴」の右列。今の会話の、あなたと猫のやり取りを古い順に出す。
struct ConversationHistoryPane: View {
    @State private var model: ConversationHistoryModel

    init(reader: any ConversationTranscriptReading) {
        _model = State(initialValue: ConversationHistoryModel(reader: reader))
    }

    var body: some View {
        Form {
            switch model.phase {
            case .loading:
                Section { ProgressView("読み込んでいます") }
            case .loaded(let entries) where entries.isEmpty:
                Section { Text("この会話の履歴はまだありません。") }
            case .loaded(let entries):
                Section {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.speaker == .user ? "あなた" : "猫")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(entry.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } footer: { historyNote }
            case .unconfigured:
                Section { Text("Hermes の接続先が設定されていません。「Hermes 接続」で設定すると履歴を読めます。") }
            case .failed(let message):
                Section {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Button("もう一度読み込む") { Task { await model.reload() } }
                        .accessibilityIdentifier(ConversationSettingsIdentifier.historyReloadButton.rawValue)
                }
            }
        }
        .task { await model.reload() }
    }

    private var historyNote: some View {
        Text("履歴は Hermes に保存されています。「新しい会話を始める」は新しい会話に切り替えるだけで、前の会話を Hermes から消しません。")
    }
}
