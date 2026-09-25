# Supertonic Voice Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 通常アプリでF1を初期値に全10声を保存・選択でき、英単語を読み補正し、実機で効果を確認した場合に一文先読みを採用する。

**Architecture:** 比較ブランチの固定済みSupertonicを通常アプリの音声サービスへ移植する。文の確定と生成の管理はReplyPlaybackCoordinator、合成・1文先読み・PCM再生は音声サービスに分離する。表示・記憶には原文、音声にだけ補正後の文字列を渡す。

**Tech Stack:** Swift / SwiftUI / XCTest、AVAudioEngine、ONNX Runtime 1.24.2、既存LiteRT-LM 0.17.1、Ruby xcodeproj 1.27.0、Python unittest。

**Spec:** `docs/superpowers/specs/2026-09-26-supertonic-voice-integration-design.md`（ユーザー承認済み、2026-09-26）。

## Global Constraints

- 作業場所: `/Users/goodapple/.codex/worktrees/supertonic-voice-integration/Cat_robot`。ブランチ: `feature/supertonic-voice-integration`。mainへはこの計画ではマージしない。
- 起点はmain `7e8c9b02b16cc8d756a32c6b4a3ec50cc120656c`。移植元は比較ブランチの固定コミット `68e9765`。
- Supertonicソース: `1e9799e964ea4c0dad7cde993b65c3c813a7b373`。
- モデル: `supertone-oss-archive/supertonic-3` / `aafc6e32416a594460b32413efc49d7fe4ce6d46`。
- ONNX Runtime: `1.24.2`。日本語、8 steps、CPU 2 threads、speed 1.05。Gemmaの設定は変更しない。
- 初期値F1、固定のF1〜F5・M1〜M5。UserDefaultsへ保存。表示・記憶は原文。辞書はiPhone→アイフォーン、Bluetooth→ブルートゥース。
- 再生中PCM＋次のPCMの最大2文分。ネイティブ合成1件。未処理原文最大2,000文字。既存のPCM有限値・8,000〜96,000Hz・60秒制限を維持する。
- 音声資産約401MBを同梱するがGitには入れない。固定revisionとSHA-256検証、MIT/OpenRAIL-Mの同梱を維持する。
- エンジン選択UI、オンラインTTS、音声クローン、Kitten/Kokoro、ユーザー編集辞書は追加しない。失敗時にApple音声へ無断で切り替えない。
- 製品コード変更は各タスクの失敗テスト確認後。タスク単位でコミットする。既存の不具合を検出したら原因を切り分け、変更に関係しない機能をまとめて書き直さない。

## Review Focus

1. 設定を開く操作と初回マイク権限・会話開始が競合しても、シート裏で遅れて認識が開始しない（Task 5）。
2. URL・コードが複数文にまたがっても、保護範囲の一部を辞書補正しない。未閉じバッククォートは残りを保護する（Tasks 2、3）。
3. キュー満杯中の生成失敗・停止で送受信の待機が残らず、文章の欠落にもならない（Tasks 3、4）。
4. 古い再生ストリームの終了通知が次の返答を停止せず、先読みの失敗は現在の再生を停止する（Task 4）。
5. 開発環境にローカル資産がない状態で製品ビルドが見かけ上成功せず、テストがスキップされた場合も実機成功へ算入しない（Tasks 1、6）。

## ファイル構成と実行環境

既存ファイルへの変更は責務を保つ。`CatRobot/Conversation/Services/Supertonic/`にエンジン・資産・PCM・音声サービス、`CatRobot/Conversation/Services/Speech/`に声設定・辞書、`CatRobot/Conversation/Domain/`に文の契約・バッファ・キューを置く。UIは`CatRobot/App/VoiceSettingsView.swift`で独立させる。比較用コードは`CatRobotTests/Device/`へ置き、製品の起動引数による隠れた方式切り替えは作らない。

全コマンドは作業場所を明示して実行する。以下はシミュレータ試験の共通形。タスクごとの`-only-testing`を追加する。初回に`xcrun simctl list devices available`で対象の存在を確認する。

```bash
GIT_LFS_SKIP_SMUDGE=1 xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=80F1BF36-5242-4067-A1D9-99399B852120' \
  -derivedDataPath /private/tmp/cat-supertonic-integration/simulator \
  -clonedSourcePackagesDirPath /private/tmp/cat-speech-comparison/packages \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

資産は移植元作業場所の`SpeechComparison/LocalAssets/Supertonic/`から新しい`CatRobot/LocalAssets/Supertonic/`へコピーし、マニフェストで検証する。モデルを再ダウンロードしない。生成されたxcodeprojは生成スクリプトと同時に更新する。ネイティブ変更前の基準は同じmainの既存全試験で確認し、以降は対象試験、最後に全試験を実行する。

---

### Task 1: 検証済み音声エンジンと同梱資産の移植

**Files:**
- Create: `CatRobot/Conversation/Services/Supertonic/{SupertonicEngine,SupertonicAssets,SupertonicSpeaker,PCMPlayer,SupertonicErrorMapper}.swift`
- Create: `CatRobot/Vendor/Supertonic/{Helper.swift,LICENSE,PROVENANCE.md}`、`CatRobot/Resources/supertonic-manifest.json`
- Create: `scripts/prepare_supertonic_assets.py`、`scripts/test_prepare_supertonic_assets.py`、`scripts/validate_supertonic_assets.py`
- Create: `CatRobotTests/Conversation/Services/{SupertonicAssetsTests,SupertonicSpeakerTests,SupertonicErrorMapperTests}.swift`
- Modify: `scripts/{generate_project.rb,test_generate_project.rb}`、`.gitignore`、`CatRobot.xcodeproj/project.pbxproj`、対応するPackage.resolved。

**Interfaces:** 比較コミットの`SupertonicEngine(root:manifest:)`、`prepare()`、`synthesize(text:voiceID:steps:) -> SpeechPCM`、`SpeechPCM.validate()`、`PCMPlaying.play(_:)`、`PCMPlaying.stop()`を維持する。新規`SupertonicErrorMapper.map(_ error: Error) -> ConversationServiceError`でmissingAssets/invalidAssets/unsupportedVoiceをspeechVoiceUnavailableへ、それ以外をspeechSynthesisFailedへ変換する。CancellationErrorは呼び出し側でcancelledとして扱う。

- [ ] 比較コミットの資産検証・PCM所有権テストを`@testable import CatRobot`へ移植する。比較の記録形式に依存するテストは持ち込まず、エンジン監査・停止待ち・不正PCMのケースを保持する。追加テスト:

```swift
func testCorruptAssetsAreUnavailableRatherThanSynthesisFailure() {
    XCTAssertEqual(SupertonicErrorMapper.map(SupertonicError.invalidAssets), .speechVoiceUnavailable)
}
```

- [ ] 対象テストを実行し、移植先型が存在しないことによる失敗を確認する。Ruby契約テストにはORT exactVersionと同梱フォルダの参照を要求する検査を追加し、現状で失敗することを確認する。
- [ ] `git show 68e9765:<移植元パス>`で上述のソース・テスト・マニフェスト・取得スクリプトを取得する。出典コミットと通常アプリ向けの変更をPROVENANCEへ記載。PCMやエンジンの処理をこの段階で最適化しない。
- [ ] generatorにORT 1.24.2をapp/testの必要なリンク先へ接続する。資産フォルダ参照は存在時だけ追加する条件にしない。ビルド前検証を追加し、manifestの各ファイルのサイズとSHA-256を検証する。検証CLIは`python3 scripts/validate_supertonic_assets.py --root CatRobot/LocalAssets/Supertonic --manifest CatRobot/Resources/supertonic-manifest.json`とする。ネットワークにはアクセスしない。
- [ ] 検証CLIのテストは一時フォルダへ小さいファイルと正しいmanifestを作り、正常、欠損、同サイズ改変、パストラバーサルで終了コードを検証する。製品の約401MBの資産を破壊して試さない。
- [ ] 資産コピー・検証後、Ruby契約、Python、移植Swift試験を実行する。通常アプリの音声注入はまだAppleのまま。コミット: `feat: add pinned Supertonic speech runtime`。

### Task 2: 声設定と音声専用の読み補正

**Files:**
- Create: `CatRobot/Conversation/Services/Speech/{SpeechVoicePreset,SpeechVoiceSettings,SpeechPronunciationNormalizer}.swift`
- Create: `CatRobotTests/Conversation/Services/{SpeechVoiceSettingsTests,SpeechPronunciationNormalizerTests}.swift`

**Interfaces:**

```swift
enum SpeechVoicePreset: String, CaseIterable, Codable, Sendable {
    case f1 = "F1", f2 = "F2", f3 = "F3", f4 = "F4", f5 = "F5"
    case m1 = "M1", m2 = "M2", m3 = "M3", m4 = "M4", m5 = "M5"
}
// @MainActor @Observable final class SpeechVoiceSettings
// init(defaults: UserDefaults); var selected: SpeechVoicePreset { get set }
// persistence key: speech.supertonic.voicePreset
// struct SpeechPronunciationNormalizer
// func normalize(_ original: String) -> String
```

- [ ] 不正値→F1、全10件、同じUserDefaults suiteで再生成して選択を復元するテストを書く。テスト専用suiteをUUIDで作り、deferで削除する。
- [ ] 辞書のテストを先に追加する。

```swift
func testOnlySpeechTextIsNormalized() {
    let original = "iPhoneケースとBluetoothを使う。"
    XCTAssertEqual(SpeechPronunciationNormalizer().normalize(original), "アイフォーンケースとブルートゥースを使う。")
    XCTAssertEqual(original, "iPhoneケースとBluetoothを使う。")
}
func testIdentifiersAndProtectedSpansRemainLiteral() {
    let input = "myiPhone iPhone16 _Bluetooth https://a.test/iPhone?q=Bluetooth a@Bluetooth.test `iPhone`"
    XCTAssertEqual(SpeechPronunciationNormalizer().normalize(input), input)
}
```

- [ ] 同じテストクラスへ大文字小文字、日本語隣接、iPhone 16 Pro、未知語、複数行コード、未閉じバッククォート、連続適用の冪等性を追加し、失敗を確認する。
- [ ] URL/メール/バッククォートの保護範囲を先に走査し、残りの範囲にだけ`(?i)(?<![A-Za-z0-9_])(iphone|bluetooth)(?![A-Za-z0-9_])`を適用する。保護範囲の判定と置換はString.IndexまたはNSRange/NSStringのいずれかに統一し、UTF-16と文字数を混ぜない。
- [ ] 状態保持やLLM呼び出しを持たない純粋な変換処理と、UserDefaults注入可能な設定を実装して対象試験を通す。コミット: `feat: persist Supertonic voices and normalize pronunciations`。

### Task 3: 複数文の確定と欠落しない受け渡し

**Files:**
- Create: `CatRobot/Conversation/Domain/{ReplySentenceStreamBuffer,SpeechSentenceChannel,SentenceSpeechSpeaking}.swift`
- Create: `CatRobotTests/Conversation/Domain/{ReplySentenceStreamBufferTests,SpeechSentenceChannelTests}.swift`
- Read/reuse: `CatRobot/Conversation/Domain/ReplySentenceBuffer.swift`

**Interfaces:**

```swift
struct SpeechSentence: Sendable, Equatable { let ordinal: Int; let original: String }
struct SentenceSpeechEvent: Sendable { let ordinal: Int; let event: SpeechEvent }
// struct ReplySentenceStreamBuffer
// mutating func receive(_ snapshot: String, final: Bool = false) throws -> [SpeechSentence]
// actor SpeechSentenceChannel
// init(capacity: Int = 2)
// func send(_ sentence: SpeechSentence) async throws
// func next() async throws -> SpeechSentence?
// func finish(throwing error: Error? = nil)
protocol SentenceSpeechSpeaking: SpeechSpeaking {
    func speakSentences(from channel: SpeechSentenceChannel, prefetch: Bool)
      async throws -> AsyncThrowingStream<SentenceSpeechEvent, Error>
}
```

- [ ] 文バッファの最初のテストを書く。

```swift
func testAllSentencesAndFinalFragmentAreEmittedOnce() throws {
    var buffer = ReplySentenceStreamBuffer()
    let first = try buffer.receive("一文目。二文目。終わり")
    let last = try buffer.receive("一文目。二文目。終わり", final: true)
    XCTAssertEqual((first + last).map(\.original).joined(), "一文目。二文目。終わり")
    XCTAssertEqual((first + last).map(\.ordinal), [0, 1, 2])
    XCTAssertTrue(try buffer.receive("一文目。二文目。終わり", final: true).isEmpty)
}
```

- [ ] 一文字ずつのsnapshot、3〜5文、既存引用/括弧/URL/小数、確定prefix変更、未確定末尾の変更、2,000文字超過を追加。バッククォート範囲は閉じるまで分割せず、複数文のコードも丸ごと保護できることを固定する。未閉じコードはfinalまで待つ。
- [ ] チャネルを満たした3件目sendの待機を観測するテストを書く。next後に送信が再開し全件が順番どおり届くこと、finish(error)/cancelで送信側・受信側が終了することを検証する。Task.sleepによる順序推測ではなく既存ConversationTestGate相当の明示ゲートを使う。
- [ ] 失敗を確認後、既存parserを再利用して複数文バッファを作る。原文の連結が元のsnapshotと一致する不変条件を持つ。空白・句読点だけを合成依頼にしない。ordinalは0始まりで一返答内単調増加。
- [ ] チャネルは継続をIDで管理し、一度だけresumeする。キャンセル前登録/登録直後キャンセルの両方を扱う。正常finishは既存キューを読み切ってnil、error/cancelはキューを捨て待機者全員へ同じ終了を伝える。受信者1件、生成側1件を契約とし、送信側自身がsend完了を待つ。
- [ ] 対象試験と既存ReplySentenceBufferTestsを通す。コミット: `feat: stream bounded reply sentences without dropping text`。

### Task 4: 一文先読みを所有する音声サービス

**Files:**
- Create: `CatRobot/Conversation/Services/Supertonic/SupertonicSentenceSpeaker.swift`
- Create: `CatRobotTests/Conversation/Services/{SupertonicSentenceSpeakerTests,ControlledPCMPlayer,ControlledPCMSynthesizer}.swift`
- Modify: `CatRobot/Conversation/Services/Supertonic/SupertonicSpeaker.swift`（共通所有権処理を必要な範囲だけ共有）。

**Interfaces:** `@MainActor final class SupertonicSentenceSpeaker: SentenceSpeechSpeaking`。注入は`player: any PCMPlaying`、`prepare: @Sendable () async throws -> Void`、`voice: @MainActor @Sendable () -> SpeechVoicePreset`、`synthesize: @Sendable (String, SpeechVoicePreset) async throws -> SpeechPCM`。通常speakは一要素のチャネルへ適合し、prepare/stopは既存SpeechSpeaking契約を守る。

- [ ] 単一文にも同じ音声専用補正が使われることを先に固定する（Task 1で移植したTestPCMPlayerを使用）。

```swift
@MainActor
func testSingleSentenceUsesSelectedVoiceAndSpeechOnlyCorrection() async throws {
    let speaker = SupertonicSentenceSpeaker(
        player: TestPCMPlayer(), prepare: {}, voice: { .f1 },
        synthesize: { text, voice in
            XCTAssertEqual(text, "アイフォーンを使う。")
            XCTAssertEqual(voice, .f1)
            return SpeechPCM(samples: [0, 0.1, 0], sampleRate: 24_000)
        })
    let events = try await speaker.speak("iPhoneを使う。")
    var finished = false
    for try await event in events { if event == .finished { finished = true } }
    XCTAssertTrue(finished)
}
```

- [ ] ControlledPCMPlayerは各playのPCM識別値を保存し、テストからstarted/finishedを送れるようにする。ControlledPCMSynthesizerは呼び出し回数・入力・同時実行数を保存し、各合成の終了をテストが解放できるようにする。
- [ ] 初回合成完了→最初の再生開始→次文合成開始の順番をゲートで検証する。1文目を再生中に2文目が完成しても3文目は始まらず、2文目再生開始後に3文目が始まるテストを失敗させる。
- [ ] 停止中の合成結果破棄、次文合成失敗による現在音声停止、旧streamの遅い終了、再生中の呼び出し拒否、辞書適用後の入力、1返答の声固定、原文範囲イベント非転用の失敗テストを追加する。
- [ ] 最初にvoiceを一度取得して返答全体で保持する。推論呼び出しに渡す直前にnormalizeを適用。prefetch=falseは文ごとの直列実行、trueは現在の再生開始後に次文の取得・合成を開始する。先読みtaskと再生taskを所有し、どちらかの失敗を他方の終了待ちで隠さず直ちに検知する。`async let`を捨てたままreturnしない。
- [ ] stopはoperation IDを無効化、PCMを停止、チャネル待機を解除、推論終了をjoin、保持PCMを解放する。Cancelledを合成失敗に上書きしない。既存PCMのfloat配列とAVAudioPCMBufferの二重保持も実機のメモリ測定へ含める。
- [ ] 全ゲートを明示的に解放してテストを完了させ、最大同時合成数1・最大保持文数2・再生順・late PCM不再生を検証する。コミット: `feat: prefetch one sentence during Supertonic playback`。

### Task 5: 通常アプリ・ライフサイクル・字幕への接続

**Files:**
- Create: `CatRobot/App/VoiceSettingsView.swift`
- Create: `CatRobot/Conversation/Integration/SentenceReplyPlayback.swift`
- Modify: `CatRobot/App/{AppRootView,CatRobotApp,ConversationAppCoordinator}.swift`
- Modify: `CatRobot/Conversation/Integration/{ConversationDependencies,ReplyPlaybackCoordinator,ConversationViewModel,OSReplyTraceSink}.swift`
- Modify: `CatRobot/Conversation/Domain/ReplyTrace.swift`
- Create: `CatRobotTests/Conversation/Integration/{SentenceReplyPlaybackTests,VoiceSettingsIntegrationTests}.swift`
- Modify: `CatRobotTests/Conversation/Integration/{AppCompositionTests,ReplyPlaybackIntegrationTests,ReplyTraceTests}.swift`

**Interfaces:** ReplyPlaybackModeへ`sentenceSerial`、`sentencePrefetch`を追加。SentenceReplyPlaybackは`run(prompt:trace:onUpdate:) async throws -> String`を持ち、既存coordinatorの所有taskから呼ばれる。`ConversationDependencies.live(voiceSettings: SpeechVoiceSettings, memoryStore: (any ConversationMemoryStore)? = nil)`を追加し、既存live呼び出しはデフォルト引数/オーバーロードで維持。`ConversationAppCoordinator`へ`showsVoiceSettings: Bool`、`openVoiceSettings()`、`closeVoiceSettings()`を追加する。

- [ ] 統合テストで、生成完了後も最後の再生中は聞き取りが再開しない、生成失敗が先読みと現在の再生を停止する、非stableサービスはfinalまで無音、字幕と保存返答にiPhone/Bluetooth原文が残ることを失敗させる。
- [ ] シート表示のテストでは初回権限待ち、通常listen、thinking、speaking、background移行と競合させる。openは停止join後にのみ表示、closeでは自動再開しない、memory reset/forget呼び出し0を確認する。テスト用UserDefaultsを注入し実ユーザーの声を変更しない。
- [ ] coordinatorがsentence mode時だけSentenceSpeechSpeakingを利用するように接続。生成producerはsentence bufferとawait sendを使い、consumerは各文イベントを処理する。failure経路はチャネル終了・speaker.stop・全child joinを一か所で所有する。非対応speakerには既存firstSentenceを使用し、テストで経路を明示する。
- [ ] 新旧記録の互換性を次の形で固定する。初期値のない新しい必須キーを増やさない。

```swift
func testOldTraceWithoutSentenceOrdinalStillDecodes() throws {
    let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","point":"speechStarted","at":1,"part":"first"}"#.utf8)
    let event = try JSONDecoder().decode(ReplyTraceEvent.self, from: data)
    XCTAssertNil(event.sentenceOrdinal)
    XCTAssertEqual(event.part, .first)
}
```

- [ ] ReplyTraceEventに`sentenceOrdinal: Int?`を追加し、旧JSONのdecode成功を維持する。`mark`に省略可能引数を加え、speechStartedの重複除去キーへordinalを含める。従来のfirst/remainder/fullは残す。通常ログは本文を含めない。UIへの発話開始は最初の実再生、返答終了は全体のdrain後とする。
- [ ] CatRobotAppで一つのSpeechVoiceSettingsを生成し、サービスとVoiceSettingsViewが共有する。シートはPickerに全10声、現在選択と「完了」を表示。既存会話操作と統一したアクセシビリティラベルを付ける。シートが開いている間は会話操作を開始できないようにする。
- [ ] 準備エラーをmapper経由で既存エラーUIへ返す。製品liveではSupertonicに変更するが、性能比較前のplayback modeはfirstSentenceのままにする。prepare時のGemma/TTSの不用意な並列化を避ける。
- [ ] 関連ライフサイクル・記憶・音声・UI試験を通す。コミット: `feat: use selectable Supertonic voices in the app`。

### Task 6: 実機で3方式を比較し通常設定を確定

**Files:**
- Create: `CatRobotTests/Device/{SupertonicIntegrationDeviceTests,SupertonicLatencyFixtures}.swift`
- Create: `scripts/{run_supertonic_integration_device_test.sh,summarize_supertonic_integration.py,test_summarize_supertonic_integration.py}`
- Create: `docs/validation/2026-09-26-supertonic-voice-integration.md`、`docs/validation/data/2026-09-26-supertonic-voice-integration/`
- Modify: `scripts/{generate_project.rb,test_generate_project.rb}`（専用実機scheme）、`README.md`、`ConversationDependencies.swift`（採用条件達成時だけ既定方式変更）。

**Interfaces:** 専用scheme `SupertonicIntegrationDeviceTests`。runner CLIは`<UDID> <stage>`、stageは`voices|fixed|gemma|lifecycle|offline`。出力JSONはrunID/sourceRevision/device/OS/mode/fixture/repetition/voice/thermalBefore/thermalAfter/cooldownSeconds/footprintSamples/events/outcomeを含む。eventsはmonotonic timestamp、point、sentenceOrdinal。Gemmaの生成文・補正入力は同意済みの試験文章のみ保存する。

- [ ] 集計のPythonテストで、文境界`次文started - 前文finished`の計算、欠落イベントを0秒にしない、失敗・skipを成功件数へ含めない、runID不一致を拒否するケースを実データ形の小さいJSONで失敗させてから集計器を実装する。
- [ ] 専用実機schemeは通常の単体試験から除外。runnerはrunID固有の結果パスを使用し、古い結果の混入を拒否する。スクリプト編集中に自身を起動したままにしない。buildとtestのログ・xcresult・JSONを保存する。
- [ ] fixedの6文章は、2文挨拶、5短文、3長文、引用と小数、iPhone/Bluetooth混在、句点なしの断片を用意する。全3方式×6文章×3回＝54試行。各反復で方式順を回転し、同じvoice F1・8 steps・文字列を使用する。文間を持たない文章は文間統計から除外する。
- [ ] gemmaは2〜5文を求める6プロンプト×2方式（firstSentence/sentencePrefetch）×3回＝36試行。元のGemma評価と同じ空の独立メモリ・通常設定を使い、利用者の保存済み記憶を上書きしない。文章差を記録し、fixedの性能結果と混ぜない。
- [ ] voicesは10声各1回の音声出力、通常画面で選択・保存・再起動の確認。lifecycleは生成中/再生中/先読み中の停止、background、音声割り込み、route change。各ケースの成功と未検証を個別に記録する。
- [ ] offlineは起動後にモデルロード前で待機し、利用者の通信OFF確認後に開始する。証明書確認で起動に失敗した試行は合成失敗と分ける。USBなし通常会話の確認は実機接続と内部テストが済んだ時点で依頼する。
- [ ] thermal serious/criticalでは試行を始めず冷却時間を記録する。段階間で条件を揃える。最初の再生通知、文間、合計、メモリ、発熱、失敗、欠落/重複を集計し、聴感確認も記録する。ソフトウェア時刻を音響計測と表記しない。
- [ ] 採用条件はfixedで文間中央値・p95改善、開始p95悪化100ms以内、欠落・重複・停止後再生0、聴感劣化なし、メモリ不足終了なし、先読み上限遵守、熱・冷却待ちの悪化なし。条件未達/未検証なら製品はfirstSentenceを維持し、原因と未完了事項を報告する。達成時だけsentencePrefetchへ既定値を変更し構成テストを更新する。
- [ ] 全Swift試験、Ruby契約、Python試験、署名付き実機buildを一度実行。新しい変更または失敗がなければ同じ全試験を繰り返さない。変更全体のレビュー後、結果・制約とセットでコミット: `perf: validate and select Supertonic sentence playback`。mainへ未マージの状態で報告する。

## 計画の照合結果と実行方法

設計の声選択・保存・原文維持はTasks 2/5、移植・資産・保守はTask 1、文確定とバックプレッシャーはTask 3、先読みと停止はTask 4、会話ライフサイクルはTask 5、実機・採用判定はTask 6に対応する。Review Focusの5項目は各タスク内に失敗テストまたは実機確認を割り当てた。

推奨はこのタスク内で主担当が順番に実装し、最後に独立したレビューを行う方式。文キュー・先読み・会話ライフサイクルの契約が密接に関係し、タスクごとの担当交代より同じ文脈を保持した実装が適している。2026-09-26に実装計画とこの実行方法の承認を受け、専用featureブランチで実装した。実機評価と採用判断は検証記録にまとめる。
