import SwiftUI

enum TypedInputSendAvailability: Equatable {
    case busy
    case empty
    case ready

    init(text: String, isSubmissionAllowed: Bool) {
        if !isSubmissionAllowed {
            self = .busy
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .empty
        } else {
            self = .ready
        }
    }

    var isEnabled: Bool {
        self == .ready
    }

    var accessibilityValue: String {
        switch self {
        case .busy:
            "猫の返事が終わると送信できます"
        case .empty:
            "入力が必要です"
        case .ready:
            "送信できます"
        }
    }
}

struct TypedInputView: View {
    @Binding var text: String
    let usesGlass: Bool
    let isSubmissionAllowed: Bool
    let onSend: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var sendAvailability: TypedInputSendAvailability {
        TypedInputSendAvailability(
            text: text,
            isSubmissionAllowed: isSubmissionAllowed
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            dismissButton
            textField(lineLimit: dynamicTypeSize.isAccessibilitySize ? 1...1 : 1...3)
            sendButton
        }
        .padding(6)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .task {
            await Task.yield()
            isFocused = true
        }
    }

    private func textField(lineLimit: ClosedRange<Int>) -> some View {
        TextField("文字で話しかける", text: $text, axis: .vertical)
            .lineLimit(lineLimit)
            .submitLabel(.send)
            .focused($isFocused)
            .onSubmit(send)
            .accessibilityLabel("文字で話しかける")
            .accessibilityHint("入力後、送信を押してください")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("文字入力を閉じる")
    }

    @ViewBuilder
    private var sendButton: some View {
        if usesGlass {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private var button: some View {
        Button(action: send) {
            Label("送信", systemImage: "arrow.up")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!sendAvailability.isEnabled)
        .accessibilityLabel("文字を送信")
        .accessibilityValue(sendAvailability.accessibilityValue)
    }

    private func send() {
        guard sendAvailability.isEnabled else { return }
        isFocused = false
        onSend()
    }

    private func dismiss() {
        isFocused = false
        onDismiss()
    }
}
