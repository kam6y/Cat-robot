import SwiftUI

struct TypedInputView: View {
    @Binding var text: String
    let usesGlass: Bool
    let onSend: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    private var sendIsDisabled: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("文字入力", systemImage: "keyboard")
                    .font(.headline)

                Spacer(minLength: 8)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("文字入力を閉じる")
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("文字で話しかける", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .submitLabel(.send)
                    .focused($isFocused)
                    .onSubmit(send)
                    .accessibilityLabel("文字で話しかける")
                    .accessibilityHint("入力後、送信を押してください")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                sendButton
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .task {
            await Task.yield()
            isFocused = true
        }
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
        .disabled(sendIsDisabled)
        .accessibilityLabel("文字を送信")
        .accessibilityValue(sendIsDisabled ? "入力が必要です" : "送信できます")
    }

    private func send() {
        guard !sendIsDisabled else { return }
        isFocused = false
        onSend()
    }

    private func dismiss() {
        isFocused = false
        onDismiss()
    }
}
