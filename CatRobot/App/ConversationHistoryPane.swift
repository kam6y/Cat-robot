import Observation
import SwiftUI

/// 「会話の履歴」の状態。履歴の正本は Hermes にあり、開くたびに読む（この iPhone には保存しない）。
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

/// 今の会話を時系列で表示し、開いたときは直近のやり取りを見せる。
struct ConversationHistoryPane: View {
    @State private var model: ConversationHistoryModel

    init(reader: any ConversationTranscriptReading) {
        _model = State(initialValue: ConversationHistoryModel(reader: reader))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("履歴を読み込み中")
            case .loaded(let entries) where entries.isEmpty:
                ContentUnavailableView("まだ会話がありません", systemImage: "bubble.left.and.bubble.right")
            case .loaded(let entries):
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(entries.indices, id: \.self) { index in
                            message(entries[index])
                                .accessibilityIdentifier("historyMessage.\(index)")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
            case .unconfigured:
                ContentUnavailableView("Hermes の接続が必要です", systemImage: "network",
                                       description: Text("設定の「Hermes 接続」で接続先と API キーを保存してください。"))
            case .failed(let message):
                ScrollView {
                    ContentUnavailableView {
                        Label("履歴を表示できません", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("もう一度読み込む") { Task { await model.reload() } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(ConversationSettingsIdentifier.historyReloadButton.rawValue)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.reload() }
    }

    private func message(_ entry: HermesTranscriptEntry) -> some View {
        let isUser = entry.speaker == .user
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(isUser ? "あなた" : "猫")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(isUser ? Color.accentColor.opacity(0.20) : Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityElement(children: .combine)
        .padding(isUser ? .leading : .trailing, 26)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
