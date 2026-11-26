import Foundation

/// Hermes の run に重ねる instructions（ephemeral system prompt）。Hermes の transcript には入らないので、毎回同じ文を送る。
/// 聞き返しの文脈は transcript に残る user 入力で運ぶ（`HermesClarificationReply`）。
enum HermesConversationInstructions {
    static let persona = """
    あなたはロボットの猫「Cat Robot」です。iPhone から届いた利用者の発話に、日本語で自然に答えます。返事はそのまま音声で読み上げられます。
    通常は聞きやすい一文か二文で簡潔に答え、詳しく求められた時だけ広げます。
    絵文字・Markdown・箇条書き・URL・コードは使いません。自分を人間だと偽りません。
    首を動かす・表情を変える・カメラで見るといった体の操作は、今の接続ではできません。できたとは言いません。
    訂正された情報を優先し、利用者の好みと自分の好みを混同しません。
    直前の会話を添えた JSON では、original は以前の利用者の発言、question は猫が実際に言った聞き返し、utterance は今の利用者の発話です。今の発話が聞き返しへの答えか、新しい話題かを文意で判断します。
    猫宛てだと肯定されたら元の発言に答え、否定されたら短く受け止めて元の発言には答えません。
    返答生成へ届いた別の話題には、その新しい話題として答えます。
    """
}

/// User-message format stored in Hermes history. Keep the prefix stable across app versions.
struct HermesClarificationReply: Codable {
    let id: UUID
    let original: String
    let question: String
    let utterance: String

    private static let prefix = "[CatRobot conversation v1]\n"
    private static let escape = "\u{2060}"

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self.prefix + String(decoding: try encoder.encode(self), as: UTF8.self)
    }

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
              exchange.question == ClarificationContext.question,
              !exchange.original.isEmpty, !exchange.utterance.isEmpty else {
            return [.init(speaker: .user, text: text)]
        }
        let current = HermesTranscriptEntry(speaker: .user, text: exchange.utterance)
        // Two attempts may both have arrived when the first acknowledgement or history read was lost.
        guard seen.insert(exchange.id).inserted else { return [current] }
        return [.init(speaker: .user, text: exchange.original), .init(speaker: .cat, text: exchange.question), current]
    }
}
