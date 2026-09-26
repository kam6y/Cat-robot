import Foundation
@testable import CatRobot

struct SupertonicLatencyFixture {
    let id: String
    let text: String
    let prompt: String
    static let all: [Self] = [
        .init(id: "greeting", text: "こんにちは。今日も一緒に遊ぼうね。", prompt: "猫ちゃん、二文で元気に挨拶して。"),
        .init(id: "five-short", text: "おはよう。元気だよ。外は晴れだね。散歩しよう。楽しみだね。", prompt: "猫ちゃん、朝の挨拶を短い五文で話して。"),
        .init(id: "long", text: "今日は窓のそばで日なたぼっこをしながら、ゆっくりお話ししようね。外から聞こえる鳥の声に耳を澄ますと、なんだか楽しい気持ちになるよ。お茶を飲んでひと休みしたら、また一緒に遊ぼうね。", prompt: "猫ちゃん、家でゆっくり過ごす提案を三文で話して。"),
        .init(id: "quoted-numbers", text: "「三時になったら会おうね」と伝えてね。円周率は3.14だよ。明日は二十五日だね。", prompt: "猫ちゃん、三時の約束と明日の予定を三文で話して。"),
        .init(id: "english", text: "iPhoneのBluetoothを確認してね。つながったら、好きな音楽を一緒に聴こう。音量は小さめにしようね。", prompt: "猫ちゃん、iPhoneとBluetoothという言葉を使って、音楽を聴く提案を三文で話して。"),
        .init(id: "fragment", text: "今日はゆっくり日なたぼっこをして一緒に過ごそうね", prompt: "猫ちゃん、寝る前の挨拶を短い二文で話して。")
    ]
}

struct FixedIntegrationReply: ReplyGenerating {
    let text: String
    var supportsStableReplyPrefix: Bool { true }
    func prewarm() async {}
    func reset() async {}
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield(text); $0.finish() }
    }
}
