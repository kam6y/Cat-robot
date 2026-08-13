import SwiftUI

enum TypedInputLayout: Equatable {
    case standard
    case compactHorizontal

    static func preferred(for dynamicTypeSize: DynamicTypeSize) -> Self {
        dynamicTypeSize.isAccessibilitySize ? .compactHorizontal : .standard
    }
}

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
        inputContent
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain)
            .task {
                await Task.yield()
                isFocused = true
            }
    }

    @ViewBuilder
    private var inputContent: some View {
        switch TypedInputLayout.preferred(for: dynamicTypeSize) {
        case .standard:
            standardContent
        case .compactHorizontal:
            compactHorizontalContent
        }
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("文字入力", systemImage: "keyboard")
                    .font(.headline)

                Spacer(minLength: 8)
                dismissButton
            }

            HStack(alignment: .bottom, spacing: 10) {
                textField(lineLimit: 1...3)
                sendButton
            }
        }
    }

    private var compactHorizontalContent: some View {
        HStack(alignment: .center, spacing: 10) {
            textField(lineLimit: 1...1)
            sendButton
            dismissButton
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
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("文字入力を閉じる")
    }

    @ViewBuilder
    private var sendButton: some View {
        if usesGlass {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
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
