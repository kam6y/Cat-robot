import Foundation
@testable import CatRobot

struct ReplyLatencyFixture: Sendable {
    let id: String
    let prompt: String
    let cohort: String
    static let normal: [Self] = [
        .init(id: "cat-sleep", prompt: "猫がよく眠る理由を二文で教えて。", cohort: "normal"),
        .init(id: "rain-play", prompt: "雨の日に家でできる遊びを二文で教えて。", cohort: "normal"),
        .init(id: "morning-walk", prompt: "朝の散歩のよいところを二文で教えて。", cohort: "normal"),
        .init(id: "reading", prompt: "本を読む楽しさを二文で教えて。", cohort: "normal"),
        .init(id: "nervous", prompt: "緊張しているときの過ごし方を二文で教えて。", cohort: "normal"),
        .init(id: "spring", prompt: "春の好きなところを二文で教えて。", cohort: "normal"),
        .init(id: "tidy", prompt: "机を片付けるコツを二文で教えて。", cohort: "normal"),
        .init(id: "sunset", prompt: "夕焼けがきれいな理由を二文で教えて。", cohort: "normal"),
        .init(id: "packing", prompt: "旅行の持ち物を準備するコツを二文で教えて。", cohort: "normal"),
        .init(id: "tea", prompt: "お茶を飲んで休むよさを二文で教えて。", cohort: "normal")
    ]
    static let controls: [Self] = [
        .init(id: "control-word", prompt: "はい、と一語で答えて。", cohort: "control"),
        .init(id: "control-one-sentence", prompt: "好きな季節を一文で教えて。", cohort: "control"),
        .init(id: "control-number", prompt: "3.14を含む一文で答えて。", cohort: "control"),
        .init(id: "control-url", prompt: "https://example.com/a?q=cat! の文字列を含む短い返答をして。", cohort: "control"),
        .init(id: "control-quote", prompt: "『こんにちは。』を引用してから一文続けて。", cohort: "control")
    ]
    static var initialMemory: ConversationMemorySnapshot {
        .init(schemaVersion: 1, memoryCompatibilityID: GemmaMemoryCompatibility.current,
              revision: 1, savedAt: Date(timeIntervalSince1970: 1_700_000_000), summary: "",
              turns: [.init(prompt: "こんにちは。", response: "こんにちは。")])
    }
}
