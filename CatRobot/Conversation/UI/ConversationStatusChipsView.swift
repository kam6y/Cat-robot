import SwiftUI

/// 会話画面の左上に重ねる状態チップ。知らせる必要があるときだけ並べ、入りきらない大きい文字では縦に積む。
struct ConversationStatusChipsView: View {
    let chips: [ConversationStatusChip]

    var body: some View {
        if !chips.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chipViews }
                VStack(alignment: .leading, spacing: 8) { chipViews }
            }
        }
    }

    private var chipViews: some View {
        ForEach(chips, id: \.self) { ConversationStatusChipView(chip: $0) }
    }
}

/// 高さ32pt・14pt のカプセル。チップには表示している文言をそのまま VoiceOver のラベルとして付ける。
private struct ConversationStatusChipView: View {
    let chip: ConversationStatusChip
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var minHeight: CGFloat = 32

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: chip.systemImage)
                .foregroundStyle(chip.isWarning ? Color.orange : Color.secondary)
            Text(chip.title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: minHeight)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.title)
        .accessibilityIdentifier(chip.accessibilityIdentifier)
    }
}
