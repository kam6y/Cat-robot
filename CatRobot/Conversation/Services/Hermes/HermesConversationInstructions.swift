import Foundation

/// Hermes の run に重ねる instructions（ephemeral system prompt）。Hermes の transcript には入らないので、毎回同じ文を送る。
/// 送る user 入力は発話の文字だけ。以前の版の聞き返しが残した v1 の user 入力は、`HermesClarificationReply` が読むだけ。
enum HermesConversationInstructions {
    static let persona = """
    あなたはロボットの猫「Cat Robot」です。iPhone から届いた利用者の発話に、日本語で自然に答えます。返事はそのまま音声で読み上げられます。
    通常は聞きやすい一文か二文で簡潔に答え、詳しく求められた時だけ広げます。
    絵文字・Markdown・箇条書き・URL・コードは使いません。自分を人間だと偽りません。
    首を動かす・表情を変える・カメラで見るといった体の操作は、今の接続ではできません。できたとは言いません。
    訂正された情報を優先し、利用者の好みと自分の好みを混同しません。
    会話の記録に「[CatRobot conversation v1]」で始まる JSON があれば、それは以前の版の記録で、original は利用者の発言、question は猫が言った聞き返し、utterance はその返事です。
    """
}

/// User-message format that older releases stored in Hermes history after a clarification. Only read now; keep the prefix stable.
/// `plainInput` still escapes typed or spoken text that starts with the prefix, so it is never read as such a record.
struct HermesClarificationReply: Decodable {
    let id: UUID
    let original: String
    let question: String
    let utterance: String

    private static let prefix = "[CatRobot conversation v1]\n"
    private static let escape = "\u{2060}"
    /// 以前の版が読み上げた聞き返し。これ以外の question の記録は、展開せずに文字どおり表示する。
    private static let legacyQuestion = "今の、ぼくに言った？"

    private static func isReserved(_ text: String) -> Bool {
        text.hasPrefix(prefix) || text.hasPrefix(escape)
    }

    static func plainInput(_ text: String) -> String {
        isReserved(text) ? escape + text : text
    }

    static func userEntries(from text: String, seen: inout Set<UUID>) -> [HermesTranscriptEntry] {
        if text.hasPrefix(escape) {
            let literal = String(text.unicodeScalars.dropFirst())
            if isReserved(literal) { return [.init(speaker: .user, text: literal)] }
        }
        guard text.hasPrefix(prefix),
              let exchange = try? JSONDecoder().decode(Self.self, from: Data(text.dropFirst(prefix.count).utf8)),
              exchange.question == legacyQuestion,
              !exchange.original.isEmpty, !exchange.utterance.isEmpty else {
            return [.init(speaker: .user, text: text)]
        }
        let current = HermesTranscriptEntry(speaker: .user, text: exchange.utterance)
        // Two attempts may both have arrived when the first acknowledgement or history read was lost.
        guard seen.insert(exchange.id).inserted else { return [current] }
        return [.init(speaker: .user, text: exchange.original), .init(speaker: .cat, text: exchange.question), current]
    }
}
