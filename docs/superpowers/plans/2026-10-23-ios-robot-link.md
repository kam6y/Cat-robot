# iOS RobotLink / Motion Implementation Plan（サブ計画 3 / 4）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iPhoneでロボットの接続と校正を行い、既存の会話の読み上げ開始に合わせて首を動かす。

**Architecture:** CoreBluetoothを値型のTransport境界に閉じ込め、RobotLinkが接続・送信・保存を所有する。MotionCoordinatorがターン、発話、動作予算、自動動作と手動操作を調停し、既存の会話エンジン・音声再生へ注入する。まず接続と校正を単体で使えるようにし、その後に会話同期を組み込む。

**Tech Stack:** iOS 27.0以上、Swift 6 strict concurrency、SwiftUI / Observation、CoreBluetooth、Foundation Models。既存依存のClaudeForFoundationModels 0.2.3とONNX Runtime 1.24.2を固定したまま使う。

**Spec:** `docs/superpowers/specs/2026-10-23-ios-robot-link-design.md`（2026-10-23、利用者承認済み）。通信はファームウェア設計§4.6と`firmware/`が正本。

## Global Constraints

- `feature/ios-robot-link`、`/Users/goodapple/.codex/worktrees/9b35/Cat_robot`で作業する。基点は`2f26772`、設計書コミットは`7ab49dc`。既存ワークスペースを再利用する。
- 新しいパッケージを追加しない。カメラ・顔の描き直し・express/look・おやすみ画面はサブ計画4。
- 首が使えなくても会話は続く。Composition生成だけではBluetoothの権限要求・スキャン・接続・動作を始めない。
- GATTは1台、プロトコル1、Status 12B / Calibration 6B / Limits 8B / Info 8B、全多バイトはlittle endian。
- 接続中はPING 1Hz、再接続は2秒間隔を目安に非重複。通常の再接続完了は5秒以内を目標にする。
- 未送信MOVEは最新1件。連続MOVEは最大20Hz、同じ列でspeed固定。RobotLink送信待ち期限は300ms。
- 自律目標はyaw±45°・pitch±20°、待機微動は±3°・±2°、4〜10秒おき・移動1〜2秒。
- 標準速度120/100°/s、控えめ60/50、活発180/120。変更は静止後。波形を変えず、GESTUREのspeedは100を基本とする。
- ツールは予約を即時に返し、最初の発話開始で解放する。4秒は追加予約の目安で、開始した1サイクルは完走する。
- 校正は専有・静止待ち。オフセット±20°・0.5°刻み。保存は同じreqを最大3回・1秒待ち、Read照合後だけ成功。全体やり直しは2回。
- ACTIVEで2秒連続静止したら低優先度のTORQUE 0を1回送る。新しい動作で古い停止を無効にする。PINGは継続する。
- フォアグラウンドだけで稼働する。backgroundは送信・PING・再接続を止めて切断し、先にSTOPを送らない。
- Swiftファイルを増減したコミットではgeneratorとcontract testを実行し、生成したxcodeprojも含める。pbxprojを手編集しない。
- 単体テストは実機・Bluetoothの権限・マイク・Claude APIを使わない。鍵を読んだりコピーしたりせず、テストは偽の認証を使う。
- 首が動く実機確認は利用者在席時だけ。ホスト試験のために書き込み・リセット・接続・モーター指令を自動実行しない。

## Review Focus

1. 設定を開くための再生取消と、利用者の停止・backgroundを混同しない。設定では波形完走、backgroundでは切断復帰になること（Task 9）。
2. 同じUUIDに再接続した後の旧特性・取消後の成功callbackで、前の待ちや送信が復活しないこと（Task 3/4）。
3. SET_CALだけ落ちた保存、req折り返し、旧成功通知で「保存済み」にしないこと（Task 5）。
4. Claudeの失敗時に予約が残り、端末内モデルの発話開始から解放されないこと（Task 8）。
5. 待機時のTORQUE 0がバックプレッシャーで遅れた間に新しいMOVEが始まり、その後で止めないこと（Task 7）。

---

## ファイルと依存関係

| 場所 | 責務 |
|---|---|
| `CatRobot/RobotLink/RobotProtocol.swift` | wire DTO、UUID、codec（Task 1） |
| `CatRobot/Motion/MotionTurnContext.swift` | 不変のターンIDと実行スコープ（Task 2） |
| `CatRobot/RobotLink/RobotTransport.swift` | BLEオブジェクトを出さないTransport契約とイベント（Task 3） |
| `CatRobot/RobotLink/RobotClock.swift` | 単調時刻・取消可能な待機（Task 3） |
| `CatRobot/RobotLink/RobotPreferences.swift` | 接続先・強さ・待機微動の保存（Task 3） |
| `CatRobot/RobotLink/RobotLink.swift` | 接続状態・PING・キュー・鮮度・Read（Task 3） |
| `CatRobot/RobotLink/CoreBluetoothRobotTransport.swift` | 遅延初期化するCBCentralManagerとdelegate（Task 4） |
| `CatRobot/RobotLink/RobotCalibrationSession.swift` | プレビュー・保存照合・entry snapshot（Task 5） |
| `CatRobot/RobotLink/RobotSettingsModel.swift` | UI用状態・操作・手動モード通知（Task 6） |
| `CatRobot/RobotLink/RobotConnectionView.swift` / `RobotCalibrationView.swift` | 確認済み画面案01をSwiftUIにする（Task 6） |
| `CatRobot/Motion/RobotMotionControlling.swift` | Motionの注入境界、Noop、request/result（Task 7） |
| `CatRobot/Motion/GestureTiming.swift` | 予算用の時間予測（Task 7） |
| `CatRobot/Motion/MotionCoordinator.swift` | 予約・直列実行・自動動作・停止・モード（Task 7） |
| `CatRobot/Conversation/Tools/MoveHeadTool.swift` | ツール引数と予約結果（Task 8） |
| `CatRobot/Conversation/Integration/MotionReplyGenerator.swift` | 最終reply streamの成功・失敗をMotionへ通知（Task 8） |
| 既存のComposition / AppCoordinator / Playback / Fallback | 上記を寿命と発話に結合（Task 8/9） |

Task 1→2→3→4→5→6→7→8→9→10の順を基本とする。Task 2はSDK境界の技術確認ゲート。FakeTransportでTask 3/5を、実機なしで実装する。

### 共通の検証手順

最初に利用可能なiOS 27 SimulatorのUDIDを`xcrun simctl list devices available`で選び、`ROBOT_SIMULATOR_UDID`へ設定する。固定の古いUDIDを流用しない。以後の`ios_test`は次のコマンドを意味する（各シェルで同じ値を設定する）。

```bash
ios_test() {
  xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot \
    -destination "platform=iOS Simulator,id=${ROBOT_SIMULATOR_UDID}" \
    -derivedDataPath /private/tmp/cat-ios-link/simulator \
    -clonedSourcePackagesDirPath /private/tmp/cat-ios-link/packages \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO "$@"
}
```

Swiftファイルを追加したテストは、generator実行後にREDを確認する。`ruby scripts/generate_project.rb`、`ruby scripts/test_generate_project.rb`の順で実行する。Supertonic資産は既存の検証済み資産を利用できる場合はコピーして、`python3 scripts/prepare_supertonic_assets.py --output CatRobot/LocalAssets/Supertonic --manifest CatRobot/Resources/supertonic-manifest.json`で検証する。未取得なら同スクリプトの固定revisionで取得する。開発キーはコピーしない。

コミットはtaskの明示したパスと再生成した`CatRobot.xcodeproj`だけを`git add -- <paths>`、`git diff --cached --check`して行う。他の作業の差分を含めない。以下の件数は新しいテストの下限を固定するものではなく、記載した観測可能な契約をすべて検証する。

### Task 1: プロトコル版1の値型とcodec

**Files:** Create `CatRobot/RobotLink/RobotProtocol.swift`、`CatRobotTests/RobotLink/RobotProtocolTests.swift`。Modify generated `CatRobot.xcodeproj`。

**Interfaces:**
- Produces: `RobotCharacteristic: CaseIterable, Sendable`（command/status/calibration/limits/info、`uuid: UUID`）。サービスUUIDも同ファイルに1つ定義する。
- `RobotCommand: Equatable, Sendable`のcaseは`move(yawDeci:Int16,pitchDeci:Int16,speed:UInt8)`、`gesture(id:UInt8,ampDeci:UInt8,repeats:UInt8,speed:UInt8)`、`stop`、`center(speed:UInt8)`、`torque(Bool)`、`setCalibration(RobotCalibrationValues)`、`saveCalibration(req:UInt8)`、`setLimits(RobotLimits)`、`ping(seq:UInt8)`。
- DTO: `RobotCalibrationValues(yawOffsetDeci:Int16,pitchOffsetDeci:Int16,invert:UInt8)`、`RobotCalibration(values:saved:)`、`RobotLimits(yawVelocityDeci:UInt16,pitchVelocityDeci:UInt16,yawAngleDeci:Int16,pitchAngleDeci:Int16)`、`RobotInfo(protocolVersion:major:minor:patch:hardwareID:capabilities:)`（各UInt8）。
- `RobotStatus`は`yawDeci/pitchDeci:Int16, flags:RobotStatusFlags, pingSeq:UInt8, state:RobotFirmwareState, voltageCenti:UInt16, rejectedCount:UInt8, saveSeq:UInt8`。flagsは設計書bit0〜10、stateは0〜5。
- `RobotProtocol.encode(_ command:RobotCommand) throws -> Data`、`decodeStatus(_:)` / `decodeCalibration(_:)` / `decodeLimits(_:)` / `decodeInfo(_:)`（いずれもDataから該当DTOへthrows）。`RobotProtocolError`はbadLength/invalidValue/unsupportedProtocol。

- [ ] **Step 1: 既存の基準を確認し、失敗するcodecテストを書く。** `ios_test`を一度全体で実行して基準を記録する。新規テストには全9コマンド、全4Read、短長、負角、SAVE req0、未知stateを含める。既存の`firmware/test/test_protocol`と`firmware/tools/catneck_proto.py`を正本として次を固定する。

```swift
func testMoveIsLittleEndian() throws {
    XCTAssertEqual(try RobotProtocol.encode(.move(yawDeci: 200, pitchDeci: -50, speed: 100)),
                   Data([0x01,0xC8,0,0xCE,0xFF,0x64]))
}
func testStatusSignedAnglesAndSaveSequence() throws {
    let s = try RobotProtocol.decodeStatus(Data([0x85,0xFF,0x2D,0,3,4,7,3,0,0,3,250]))
    XCTAssertEqual(s.yawDeci, -123); XCTAssertEqual(s.saveSeq, 250)
    XCTAssertTrue(s.flags.contains(.saveError))
}
```

- [ ] **Step 2: REDを確認。** Run: `ios_test -only-testing:CatRobotTests/RobotProtocolTests`。Expected: 未定義の型/関数で失敗。テスト対象未登録の空実行をRED扱いしない。
- [ ] **Step 3: codecを実装。** 固定長を先に検証し、明示的なbyte演算でLEを扱う。未整列メモリーloadを使わない。Infoのversionは1だけ、SAVE req0・負の角度上限は拒否する。reserved flagは保持して既知bitだけ解釈する。
- [ ] **Step 4: GREENを確認。** Step 2と同じRun。Expected: 0 failures、golden bytes一致。
- [ ] **Step 5: Commit。** 上記2ファイルと生成project、メッセージ`feat(robot): add protocol v1 codec`。

### Task 2: SDKを通る不変のターンスコープを検証

**Files:** Create `CatRobot/Motion/MotionTurnContext.swift`、`CatRobotTests/Motion/MotionTurnContextTests.swift`、`CatRobotTests/Motion/ToolProbeLanguageModel.swift`。Modify generated project。

**Interfaces:**
- `MotionTurnID: Hashable, Sendable`は`rawValue:UUID`と`init(rawValue:UUID = UUID())`。
- `MotionTurnContext`に`@TaskLocal static var current: MotionTurnID?`。Tool.call内で取得した値を、最初のawait前に固定して使う。
- Test-only `ToolProbeLanguageModel: LanguageModel` / `ToolProbeExecutor: LanguageModelExecutor`。executorはtoolCalling capabilityを宣言し、最後のprompt以降にtool outputがなければprobe tool call、あれば短いresponseを返す。過去ターンのtool outputで新しいターンのprobeを省略しない。URLSession/Claudeの認証経路を使わない。
- 同じtest fixtureに`makeToolProbeSession() -> (session:LanguageModelSession,probe:ToolContextProbe)`を置く。probeはactorで`recordedTurns() -> [MotionTurnID?]`を提供する。

- [ ] **Step 1: 実Frameworkを通すREDを書く。** `ContextProbeTool: Tool`がcall時のIDを記録し、1つの`LanguageModelSession`を2ターン再利用する。単にProbeTool.callを直接呼ぶテストだけにしない。

```swift
func testSessionToolReceivesEachCallingTurn() async throws {
    // ToolProbeLanguageModelとContextProbeToolで作ったsessionを同じまま使う。
    let (session, probe) = makeToolProbeSession()
    let a = MotionTurnID(), b = MotionTurnID()
    _ = try await MotionTurnContext.$current.withValue(a) { try await session.respond(to: "first") }
    _ = try await MotionTurnContext.$current.withValue(b) { try await session.respond(to: "second") }
    let recorded = await probe.recordedTurns()
    XCTAssertEqual(recorded, [a, b])
}
```

- [ ] **Step 2: RED確認。** Run: `ios_test -only-testing:CatRobotTests/MotionTurnContextTests`。Expected: 未実装でFAIL。cancel後の遅いprobeとscopeなしのcallも記録し、新IDへの取り違えがないことを検証する。
- [ ] **Step 3: scopeとoffline executorを実装。** 手元のSDKの`LanguageModelExecutor.respond(to:model:streamingInto:)`とchannelの`.toolCalls(action:.toolCall(id:name:action:.appendArguments(_:tokenCount:)))`、`.response(action:.appendText(_:tokenCount:))`を使う。型宣言はSDKを正本とし、private APIを使わない。
- [ ] **Step 4: GREENと技術ゲート。** Step 2と同じRun。SDKがTaskLocalを伝えなければskipやglobalな「現在のターン」で代用しない。このタスク内で明示のrequest-scope bridgeを確立し、同じ2ターン・取消・scope欠損テストを通す。必要な内部方式の変更は設計の許容範囲として記録する。合格するまでTask 8のツールを本結合しない。
- [ ] **Step 5: Commit。** 3ファイルとproject、`test(motion): verify tool turn scope through the SDK`。

### Task 3: FakeTransportでRobotLinkの接続・PING・送信を作る

**Files:** Create `CatRobot/RobotLink/{RobotTransport,RobotClock,RobotPreferences,RobotLink}.swift`、`CatRobotTests/RobotLink/{RobotTestDoubles,RobotLinkTests}.swift`。Modify project。

**Interfaces:**
- `@MainActor protocol RobotClock: AnyObject`は`var now:TimeInterval {get}`、`func sleep(until:TimeInterval) async throws`。`SystemRobotClock`は単調時刻。testの`ManualRobotClock.advance(by:) async`は期限に到達した待機だけを解放し、取消も扱う。
- `RobotDevice: Equatable, Sendable`は`id:UUID, name:String, rssi:Int?`。`@MainActor @Observable RobotPreferences`の`selectedDevice:RobotDevice?, strength:RobotMotionStrength, idleEnabled:Bool`をUserDefaultsへ保存する。既定はnil/standard/true。UUID・名前以外の接続状態を永続化しない。
- `RobotMotionStrength: String, CaseIterable, Sendable`はcalm/standard/active。`RobotBluetoothState`はunknown/resetting/unsupported/unauthorized/poweredOff/poweredOn。`RobotLinkFailure: Error, Equatable, Sendable`はbluetoothUnavailable(RobotBluetoothState)/disconnected/timedOut/cancelled/notReady/expired/protocolMismatch/invalidData/saveFailed/valueMismatchを使う。
- `@MainActor protocol RobotTransport: AnyObject`は`events:AsyncStream<RobotTransportEvent>`、`canSendWriteWithoutResponse:Bool`、`start()`、`retrieve(_ id:UUID)`、`scan()`、`stopScan()`、`connect(_ id:UUID, attempt:UUID)`、`disconnect(attempt:UUID)`、`read(_ characteristic:RobotCharacteristic, attempt:UUID)`、`setStatusNotify(_ enabled:Bool, attempt:UUID)`、`writeCommand(_ data:Data, attempt:UUID)`、`invalidate()`。
- Transportイベントは`bluetooth(state:)`、`discovered(RobotDevice)`、`gattReady(attempt:UUID)`、`disconnected(attempt:UUID,reason:RobotLinkFailure)`、`value(attempt:UUID,characteristic:RobotCharacteristic,data:Data)`、`notifyReady(attempt:UUID)`、`readyToWrite(attempt:UUID)`、`failed(attempt:UUID,reason:RobotLinkFailure)`。CBオブジェクトは含めない。
- `RobotLinkSnapshot: Equatable, Sendable`は`state:RobotLinkState, device:RobotDevice?, discoveredDevices:[RobotDevice], info:RobotInfo?, status:RobotStatus?, calibration:RobotCalibration?, limits:RobotLimits?, statusReceivedAt:TimeInterval?, motionAvailable:Bool`。stateにはunselected/unavailable/searching/connecting/preparing/connected/reconnecting/suspended/unsupportedを設ける。理由と選択先はassociated valueかsnapshotで保持する。
- `@MainActor protocol RobotLinkControlling: AnyObject`は`var snapshot:RobotLinkSnapshot {get}`、`updates()->AsyncStream<RobotLinkSnapshot>`、`start()`、`select(_ device:RobotDevice)`、`resume()`、`suspend()`、`setApplicationActive(_ active:Bool)`、`disconnectByUser()`、`send(_ command:RobotCommand, priority:RobotCommandPriority, token:UUID, expiresAt:TimeInterval) async throws`、`invalidate(_ token:UUID)`、`read(_ characteristic:RobotCharacteristic) async throws -> Data`。
- `RobotCommandPriority`はmanualStop/heartbeat/calibration/motion/idlePowerOffの順。`RobotLink.init(transport:any RobotTransport,clock:any RobotClock,preferences:RobotPreferences)`。sendの完了はTransportに渡した意味で、実機受理の意味ではない。
- Test-only `RobotLinkHarness`は`clock,transport,preferences,link`と`connectReady(status:RobotStatus=idleStatus) async`、`receiveStatus(_:)`、`drain() async`を提供する。FakeTransportはイベントを任意のattemptで発行でき、`commands:[RobotCommand]`、接続試行・Read履歴を記録する。

- [ ] **Step 1: 状態と送信のREDを書く。** 暗号化Status相当の値、Info1、NotifyReady、Cal/Limitsがそろう前はmotionAvailable=false。FWのBOOT/BOOT_CENTER/RETURNING/RELAX_WAITでも通常の動作を許可しない（暗号化後の明示STOPは別扱い）。次も個別testにする。

```swift
// testHeartbeatAndFreshness
await h.connectReady()
for _ in 0..<5 { h.receiveStatus(idleStatus); await h.clock.advance(by: 0.2) }
XCTAssertEqual(h.transport.commands.filter { if case .ping = $0 { true } else { false } }.count, 1)
await h.clock.advance(by: 1)
XCTAssertFalse(h.link.snapshot.motionAvailable) // 新しいStatusが途切れた
// testOldAttemptCannotReviveAfterReconnect
h.transport.emit(.value(attempt: oldAttempt, characteristic: .status, data: activeBytes))
XCTAssertEqual(h.link.snapshot.status, newAttemptStatus)
// testLatestMoveStopPriorityAndExpiry
XCTAssertEqual(h.transport.commands, [.stop, latestMove]) // 無効化・期限切れの送信なし
```

- [ ] **Step 2: RED確認。** Run: `ios_test -only-testing:CatRobotTests/RobotLinkTests`。Expected: 未実装でFAIL。2秒の再接続非重複、取消終端待ち、userDisconnectで再開しない、Bluetooth拒否/オフも含める。
- [ ] **Step 3: RobotLinkを実装。** GATT準備→Info→暗号化Status Read/Notify→Cal/Limitsの順に準備する。PINGは1Hz、Status欠落1秒で新規動作停止、Readと新しいseq応答を確認し2秒で回復しなければ切断。接続試行の通常期限5秒、取消終端が5秒来なければTransport.invalidateでmanagerを破棄して次へ。初回の権限・ペアリング待ちは最大30秒、setApplicationActive(false)中の利用者操作待ちは期限を進めない。初回の暗号化Status Readだけはこの30秒の期限を使い、準備後のReadは特性ごとに直列化して3秒で失敗したら接続世代を終える。旧Readを新Readとして消費しない。
- [ ] **Step 4: GREEN。** Step 2と同じRun。送信フロー制御待ち・token無効化・300ms期限・最新MOVE/プレビュー置換・STOP/PING優先・同UUID再接続を検証。新Statusは受信時刻を持ち、古いread値だけで復旧しない。OSLogは接続世代のローカルな番号、状態、理由分類と時刻だけにし、端末UUID/名前/bytesをログへ出さない。
- [ ] **Step 5: Commit。** 明示した6ファイルとproject、`feat(robot): add connection and command lifecycle`。

### Task 4: CoreBluetoothアダプタを結合する

**Files:** Create `CatRobot/RobotLink/CoreBluetoothRobotTransport.swift`、`CatRobotTests/RobotLink/CoreBluetoothRobotTransportTests.swift`。Modify `CatRobot/Resources/Info.plist`、`scripts/test_generate_project.rb`、project。

**Interfaces:** Consumes Task 3のRobotTransport。`@MainActor final class CoreBluetoothRobotTransport: NSObject, RobotTransport`。`init(makeCentral: @escaping @MainActor (any CBCentralManagerDelegate) throws -> CBCentralManager)`をテスト用に用意し、本番はmain queueのfactoryを使う。initではfactoryを呼ばない。

- [ ] **Step 1: REDを書く。** `testInitializationDoesNotCreateCentral`はfactoryが呼ばれたらthrowするspyで、構築直後のcallCount==0を確認する。`testBluetoothUsageDescription`はInfo.plistの日本語利用理由が空でないこと、background modesを追加していないことを確認する。
- [ ] **Step 2: RED確認。** Run: `ios_test -only-testing:CatRobotTests/CoreBluetoothRobotTransportTests`。Expected: 未実装/利用理由未追加でFAIL。Bluetooth機能自体は起動しない。
- [ ] **Step 3: アダプタ実装。** startまでCBCentralManagerを作らない。scanをサービスUUIDに限定し、peripheralを強参照、5特性と必要なpropertyを確認してgattReadyを出す。Status NotifyとReadを同じvalueイベントで渡してよい（CoreBluetoothは区別を返さない）。manager/peripheral/characteristicの現世代とidentityを確認し、取消終端前に同じperipheralを使い直さない。送信可能callbackでreadyToWriteを発行する。Swift6のdelegate適合はmain queueの事実を保って実装する。利用理由は「Cat Robotは、ロボットの首に接続して動かすためにBluetoothを使用します。」とする。
- [ ] **Step 4: GREENとビルド。** 上記test、`ruby scripts/test_generate_project.rb`、`xcodebuild build -project CatRobot.xcodeproj -scheme CatRobot -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/cat-ios-link/device CODE_SIGNING_ALLOWED=NO`。Expected: PASS / BUILD SUCCEEDED。実機を接続して試さない。
- [ ] **Step 5: Commit。** 上記パスとproject、`feat(robot): add lazy CoreBluetooth transport`。

### Task 5: 排他的な校正プレビューと保存照合

**Files:** Create `CatRobot/RobotLink/RobotCalibrationSession.swift`、`CatRobotTests/RobotLink/RobotCalibrationSessionTests.swift`。Modify project。

**Interfaces:** `@MainActor @Observable final class RobotCalibrationSession`。`init(link:any RobotLinkControlling,clock:any RobotClock)`、`begin() async throws`、`preview(_ values:RobotCalibrationValues)`、`save() async throws -> RobotCalibration`、`restoreEntry() async throws`、`moveToEdge(_ edge:RobotCalibrationEdge) async throws`、`center() async throws`、`stop() async`、`cancel()`。公開状態はentry:RobotCalibration?、draft:RobotCalibrationValues?、phase:RobotCalibrationPhase、hasNewChanges:Bool、canEdit:Bool。phaseはinactive/waitingForRest/editing/saving/restoring/failed(RobotLinkFailure)/closed。edgeはleft/right/up/down。

- [ ] **Step 1: REDを書く。** beginはmotionAvailableになり、Gesture/Moving/Returningを抜けて新Readが終わるまで操作不可。次の保存を固定する。

```swift
// testSaveConfirmsIntendedReadback
session.preview(values); let saving = Task { try await session.save() }; await h.drain()
XCTAssertEqual(sentSaveRequests, [1]) // 直前saveSeq=255。SET_CALの後
// saveSeq=1, SAVE_ERROR=0だけでは完了しない
XCTAssertTrue(session.phase == .saving)
// Readで意図値かつsaved=1を渡した後だけ成功
let confirmed = try await saving.value
XCTAssertEqual(confirmed, RobotCalibration(values: values, saved: true))
```

- [ ] **Step 2: RED確認。** Run: `ios_test -only-testing:CatRobotTests/RobotCalibrationSessionTests`。Expected: 未実装でFAIL。testPartialSetCalLossRestartsWithNewReq、testSameReqRetryThreeAttempts、testOldSuccessCannotCompleteNewSave、testOriginalDirtyEntryRemainsDirtyAfterRestoreも書く。
- [ ] **Step 3: 実装。** プレビューは100ms間隔で最新1件。entry取得後はdraftだけを変え、saveは固定値をSET_CAL→異なるreq→1秒待ち同req最大3送信→Read照合。値違いなら新reqで全体最大2回。保存中の編集・端移動を禁止し、PINGを妨げない。端移動はfresh Limitsの±値へspeed10で1方向ずつ、CENTERはspeed10、停止はmanualStop優先。保存失敗時はdraftを残す。
- [ ] **Step 4: GREEN。** 同じRun。NVS失敗、saved0、req255→1、切断、画面終了、10Hzプレビューの遅着、保存中の編集拒否を確認。restoreEntryはNVSに書かず、元のsavedフラグをReadの実値で表示する。
- [ ] **Step 5: Commit。** 2ファイルとproject、`feat(robot): confirm calibration persistence by readback`。

### Task 6: 接続・校正を手動で使える画面にする

**Files:** Create `CatRobot/RobotLink/{RobotSettingsModel,RobotConnectionView,RobotCalibrationView}.swift`、`CatRobotTests/RobotLink/{RobotSettingsModelTests,RobotPresentationTests}.swift`。Modify `CatRobot/App/{ConversationComposition,CatRobotApp,AppRootView,ConversationSettingsView}.swift`、project。

**Interfaces:**
- `RobotControlMode: Equatable, Sendable`はconversation/settings/calibration(UUID)/inactive/background。
- `@MainActor @Observable final class RobotSettingsModel`は`init(link:any RobotLinkControlling,preferences:RobotPreferences,clock:any RobotClock,onControlModeChanged:@escaping @MainActor @Sendable (RobotControlMode)->Void = {_ in})`。`settingsDidOpen()` / `settingsDidClose()`、`select(_:)`、`disconnect()`、`openCalibration() async`、`closeCalibration(_ decision:RobotCalibrationExit) async`を提供する。exitはsave/restore/cancelNavigation。`calibration:RobotCalibrationSession?`と接続一覧/表示文/失敗状態を公開する。
- `RobotConnectionView(model:RobotSettingsModel)`、`RobotCalibrationView(session:RobotCalibrationSession,onClose:...)`。initで接続しない。手動モード通知はviewの再描画待ちにせず、モデルの操作で同期的に出す。

- [ ] **Step 1: REDを書く。** `testCompositionDoesNotStartBluetooth`、`testOpeningCalibrationWaitsForRest`、`testUnsavedExitRestoresEntryWithoutPersisting`、`testDisconnectedCalibrationDoesNotReplayDraftOnReconnect`を用意する。

```swift
// testSettingsOwnershipPrecedesCalibrationPreview
model.settingsDidOpen()
XCTAssertEqual(modes.first, .settings)
await model.openCalibration()
XCTAssertFalse(session.canEdit) // ロボットはまだGesture中
XCTAssertTrue(h.transport.commands.allSatisfy { if case .setCalibration = $0 { false } else { true } })
```

- [ ] **Step 2: RED確認。** Run: `ios_test -only-testing:CatRobotTests/RobotSettingsModelTests -only-testing:CatRobotTests/RobotPresentationTests -only-testing:CatRobotTests/AppCompositionTests`。
- [ ] **Step 3: 画面と配線を実装。** 既存設定に「ロボット」を追加し、案01の接続・校正画面へNavigationStackで遷移する。offsetは±20・step0.5、反転2個、方向別ボタン、停止、Read確認つき保存を配置する。離脱時は保存/今回の変更を戻す/そのまま編集の選択肢。未接続・復帰待ち・保存失敗・未保存を文言で区別する。大きいDynamic Typeは1列にする。Compositionで同一link/modelを保持し、この段階のmode callbackは以後のTask 8で実Motionへ接続する。
- [ ] **Step 4: GREENと表示確認。** Step 2のRun。PreviewまたはSimulator上のFakeTransportの画面で横向き・最大文字・VoiceOverラベルを確認する。本物のBluetoothを起動するlive compositionでUI試験をしない。保存済み表示は成功Read後だけ。
- [ ] **Step 5: Commit。** 明示したパスとproject、`feat(robot): add connection and calibration settings`。ここで会話とは独立して手動の接続・校正を試せる状態になる。

### Task 7: Motionの予約・直列実行・自動動作

**Files:** Create `CatRobot/Motion/{RobotMotionControlling,GestureTiming,MotionCoordinator}.swift`、`CatRobotTests/Motion/{MotionTestDoubles,GestureTimingTests,MotionCoordinatorTests}.swift`。Modify project。

**Interfaces:**
- `RobotMotionRequest: Equatable, Sendable`は`gesture:RobotGesture, intensity:RobotIntensity, repeats:Int`。gestureはnod/shake/tilt/lookUp/lookDown/lookAtUser/center、intensityはsmall/medium/large。
- `MotionReservationResult`はreserved(cycles:Int)/unavailable/invalidArguments/budgetExceeded/invalidated。`MotionGenerationOutcome`はsuccess/failed。`MotionCancellationReason`はfallback/playbackCancelled/newConversation/userStop/linkLost/background。
- `@MainActor protocol RobotMotionControlling: AnyObject, Sendable`は`beginTurn(_ id:MotionTurnID)`、`reserve(_ request:RobotMotionRequest,for id:MotionTurnID)->MotionReservationResult`、`speechStarted(_ id:MotionTurnID)`、`speechFinished(_ id:MotionTurnID)`、`generationFinished(_ id:MotionTurnID,outcome:MotionGenerationOutcome)`、`cancelTurn(_ id:MotionTurnID,reason:MotionCancellationReason)`、`setControlMode(_ mode:RobotControlMode)`、`setConversationPhase(_ phase:ConversationPhase)`、`utteranceConfirmed()`、`stopAll(reason:MotionCancellationReason)`、`updateTrackingTarget(_ target:RobotTrackingTarget?)`。`NoopRobotMotionController`も提供し既存testで使う（状態を持たないnonisolated initを用意する）。
- `RobotTrackingTarget: Equatable, Sendable`は`yaw:Double,pitch:Double,validUntil:TimeInterval`。Motionは期限切れを使わず、自律上限で飽和する。期限を決める顔検出側はplan4の責務。現段階の本番入力はnil。
- `MotionCoordinator.init(link:any RobotLinkControlling,clock:any RobotClock,preferences:RobotPreferences,random:any RobotRandomSource)`。randomは`@MainActor`の`next(in:ClosedRange<Double>)->Double`。`GestureTiming.estimate(request:RobotMotionRequest,limits:RobotLimits,current:RobotStatus)->TimeInterval`は1サイクルの予測。
- Test-only `MotionHarness`はManualRobotClock、RobotPreferences、録音型の`RecordingRobotLink:RobotLinkControlling`とmotionをまとめ、`sentCommands`、`drain() async`、`completeCycle(after:TimeInterval) async`を提供する。実機の運動を再実装せず、テストが明示したStatus遷移だけを発行する。

- [ ] **Step 1: REDを書く。** 次の観測をFakeClockと録音型のlinkで固定する。

```swift
// testSpeechReleasesOnceAndKeepsRunningAfterSpeechEnds
motion.beginTurn(turn)
XCTAssertEqual(motion.reserve(nodLarge, for: turn), .reserved(cycles: 1))
XCTAssertTrue(sentCommands.isEmpty)
motion.speechStarted(turn); motion.speechStarted(turn); motion.speechFinished(turn)
await harness.drain()
XCTAssertEqual(startedGestureCount, 1)
// testBudgetCountsIndividualCycles
XCTAssertEqual(reservedCycles(for: nodLargeThree), 2)
XCTAssertEqual(reservedCycles(for: shakeLargeThree), 1)
XCTAssertEqual(reservedCycles(for: lookLargeThree), 1)
// testIdleTorqueCannotStopNewMoveAfterBackpressure
await clock.advance(by: 2); startNewMotion(); transportBecomesWritable()
XCTAssertFalse(sentAfterNewMotion.contains(.torque(false)))
```

- [ ] **Step 2: RED確認。** Run: `ios_test -only-testing:CatRobotTests/GestureTimingTests -only-testing:CatRobotTests/MotionCoordinatorTests`。新ターンで旧未開始分を捨てるが旧開始済み1サイクルは完走する、settingsで完走しcalibration中に予約不可、開始を1秒観測できない場合の残り破棄も含める。
- [ ] **Step 3: 実装。** 振幅表・左右交互tilt・scope欠損拒否・1サイクルずつの送信を仕様通りに実装する。時間予測はwaveformの基準/導関数ピークとV/A/Jの伸長、20ms量子化と60ms遅延から求める。goldenは標準・中立でnod large1.52s / shake large2.08s / look large4.06s（±1tick）。初回は1サイクルを許容し、次は寄せ時間も含む予測合計≤4秒だけを許容する。
- [ ] **Step 4: 自動動作とGREEN。** 同じRun。待機は4〜10秒、±3/±2、1.2〜1.6秒のC²目標列を20Hz以下で送る（実機の追従込み1〜2秒をTask 10で確認）。発話確定は0→−5→0のMOVE列、約0.6秒。実機未測定を自動テストのPASSで代替しない。通常自律範囲45/20、強さは静止後SET_LIMITS速度欄だけ更新してRead照合。ACTIVE2秒静止・保存/設定速度変更外でidlePowerOffを送り、新操作で失効。タイマーと送信ticketを別々に取消する。追尾はupdateTrackingTargetの境界だけで、本番はnil入力のためlookAtUserはCENTERになる。カメラを作らない。予約・発話開始・実行可能・送信・開始観測・完了の時刻とenum結果を記録し、発話からの実測値と前サイクル待ちを別々に確認できるようにする。本文と引数全文を記録しない。
- [ ] **Step 5: Commit。** 6ファイルとproject、`feat(motion): schedule bounded speech-synchronized movements`。

### Task 8: ツールと生成・発話を結ぶ

**Files:** Create `CatRobot/Conversation/Tools/MoveHeadTool.swift`、`CatRobot/Conversation/Integration/MotionReplyGenerator.swift`、`CatRobotTests/Motion/{MoveHeadToolTests,MotionReplyGeneratorTests,MotionPlaybackIntegrationTests}.swift`。Modify `CatRobot/Conversation/Tools/ConversationToolProvider.swift`、`CatRobot/Conversation/Services/Claude/{OnDeviceFallbackReplyGenerator,ConversationInstructions}.swift`、`CatRobot/Conversation/Integration/{ConversationDependencies,ReplyPlaybackCoordinator}.swift`、`CatRobot/App/ConversationComposition.swift`、`CatRobotTests/Conversation/Services/Claude/{ConversationInstructionsTests,OnDeviceFallbackReplyGeneratorTests}.swift`、`CatRobotTests/Conversation/Integration/{AppCompositionTests,ReplyPlaybackCoordinatorTests,SentenceReplyPlaybackTests}.swift`、project。

**Interfaces:**
- `MoveHeadTool.init(motion:any RobotMotionControlling)`。Generable Argumentsは`gesture:String,intensity:String,repeats:Int?`。nameは`move_head`。case変換は内部で一度行い、不正値を拒否、nil repeatsだけ1とする。
- 既存`RememberToolProvider`は残し、`RobotConversationToolProvider(motion:)`を追加する。既存`tools(memory:)`の契約は同じでrememberとmove_headを返す。
- `MotionReplyGenerator.init(base:any ReplyGenerating,motion:any RobotMotionControlling)`はReplyGeneratingに適合し、streamの呼び出し時に固定したMotionTurnIDで終了通知する。scopeなしは従来どおり生成だけ行う。
- `ConversationDependencies`に`motion:any RobotMotionControlling`を追加する。Noopの既定値の生成は非隔離initから安全に使える形にし、既存の依存構築を壊さない。`ReplyPlaybackCoordinator.init(reply:speaker:mode:motion:)`はNoop既定で拡張する。

- [ ] **Step 1: REDを書く。** `MoveHeadToolTests`で全7gesture×3intensity・不正値・repeats省略/0/4・scopeなしを確認する。`MotionPlaybackIntegrationTests`で既存ControlledReply/ControlledSpeakerと同じ方式を使い、voice/typed共通runが発話開始前に送らないこと、正常発話終了で完走することを確認する。

```swift
// testFallbackCannotReleaseFailedPrimaryReservations
primaryReserves(turn); primaryFailsBeforeVisibleText(); fallbackStartsSpeaking(turn)
XCTAssertTrue(sentMotionCommands.isEmpty)
// testCancelledOldToolCannotReserveForNextTurn
motion.beginTurn(newTurn)
XCTAssertEqual(motion.reserve(request, for: oldTurn), .invalidated)
// testToolReturnsReservationWithoutAwaitingSpeech
let result = try await tool.call(arguments: validArguments)
XCTAssertEqual(result, "頷く動作を1回予約しました")
XCTAssertTrue(sentMotionCommands.isEmpty)
```

- [ ] **Step 2: RED確認。** Run: `ios_test -only-testing:CatRobotTests/MoveHeadToolTests -only-testing:CatRobotTests/MotionReplyGeneratorTests -only-testing:CatRobotTests/MotionPlaybackIntegrationTests -only-testing:CatRobotTests/OnDeviceFallbackReplyGeneratorTests`。
- [ ] **Step 3: 予約とイベントを実装。** runの既存UUIDからMotionTurnIDを作り、workerのTaskLocal内でbeginTurn→生成/再生を開始する。最初のspeechStartedだけMotionへ渡し、取り消し・失敗を同じIDで通知する。MotionReplyGeneratorは最終streamの成功/失敗を伝える。Fallbackは端末内生成に入る前に同IDの予約をcancelTurn(.fallback)する。世代を失効させた後のsuccess通知で再活性化しない。Tool.callは予約の短い結果を返すだけで、発話やハード完了を待たない。
- [ ] **Step 4: GREENと既存回帰。** 同じRunに`ReplyPlaybackCoordinatorTests`、`SentenceReplyPlaybackTests`、`ClaudeSessionFactoryTests`、`ConversationInstructionsTests`、`ClaudeMemoryPersistenceTests`を追加。セッション工場は毎ターン呼ばれない、rememberの世代が保たれる、指示の固定前方に可変接続状態を入れないことを確認する。live Compositionは実Motion、RobotConversationToolProvider、元のFallbackをavailability用、MotionReplyGeneratorをreply用として同じインスタンスに結ぶ。
- [ ] **Step 5: Commit。** 明示したパスとproject、`feat(conversation): reserve head movements for speech start`。

### Task 9: 前面状態・設定専有・表示を統合する

**Files:** Modify `CatRobot/App/{ConversationAppCoordinator,AppRootView,ConversationComposition}.swift`、`CatRobot/Conversation/Integration/ConversationViewModel.swift`、`CatRobot/Conversation/UI/{ConversationViewState,ConversationView}.swift`、`CatRobot/RobotLink/RobotSettingsModel.swift`。Create `CatRobotTests/Motion/RobotLifecycleIntegrationTests.swift`、`CatRobotTests/RobotLink/RobotStatusPresentationTests.swift`。Modify `CatRobotTests/Conversation/Integration/{ConversationAutoResumeTests,VoiceSettingsIntegrationTests,ConversationNewSessionTests,ConversationRecoveryTests,ConversationViewModelTests}.swift`、project。

**Interfaces:** `ConversationAppCoordinator`にlink/motion/settingsModelの注入点を加える（既存testはNoop既定）。`ConversationViewModel`は`dependencies.motion`に会話phaseと発話確定を伝える。Rootは同じRobotLinkのsnapshotを表示用に投影し、会話状態・会話の可用性からBLE状態を独立させる。

- [ ] **Step 1: REDを書く。** 以下をFakeTransport/ControlledSpeakerと既存のAppCoordinatorの操作経路で再現する。

```swift
// testSettingsModeIsSetBeforePlaybackCancellation
coordinator.openVoiceSettings()
await coordinator.waitForOperations(); await motionHarness.drain()
XCTAssertTrue(isCurrentWaveStillRunning)
XCTAssertFalse(sentCommands.contains(.stop))
// testBackgroundUsesDisconnectInsteadOfStop
coordinator.scenePhaseDidChange(.background)
XCTAssertEqual(transportDisconnectCount, 1)
XCTAssertFalse(sentCommands.contains(.stop))
// testPermissionInactiveDoesNotTearDownHandshake
coordinator.scenePhaseDidChange(.inactive)
XCTAssertEqual(transportDisconnectCount, 0)
```

- [ ] **Step 2: RED確認。** Run: `ios_test -only-testing:CatRobotTests/RobotLifecycleIntegrationTests -only-testing:CatRobotTests/RobotStatusPresentationTests -only-testing:CatRobotTests/ConversationAutoResumeTests -only-testing:CatRobotTests/VoiceSettingsIntegrationTests`。
- [ ] **Step 3: 寿命と表示を結合。** 設定modeを再生取消より先に通知する。settings/inactiveの再生取消では新予約を捨て現在サイクルを完走、明示停止/新しい会話/合成失敗では現在分も停止、background/linkLostは送信しないで接続世代を終える。inactive/activeはlink.setApplicationActive(false/true)も通知し、権限待ちの期限だけを調整する。back/closeでcalibrationの保存・復元待ちを終えてから会話を再開する。最初の会話画面と前面復帰で保存済み接続先だけresumeし、未選択ならBluetoothを開始しない。
- [ ] **Step 4: GREENと表示回帰。** 上記Runに`ConversationRecoveryTests`、`ConversationNewSessionTests`、`ConversationViewModelTests`、`ConversationAccessibilityTests`を追加。接続状態だけを会話画面へ出し、Notifyごとの角度でVoiceOverを連発しない。利用不可でも会話を続ける、二度のactiveでタイマー/購読が重複しない、校正切断後は古いdraftを送らない、shutdownでworkerをjoinすることを確認する。
- [ ] **Step 5: Commit。** 明示したパスとproject、`feat(app): coordinate robot controls with scene and settings`。

### Task 10: 全回帰・文書・利用者在席の受入

**Files:** Modify `README.md`、`docs/superpowers/specs/2026-10-11-cat-robot-claude-neck-requirements.md`。Create `docs/validation/2026-10-23-ios-robot-link.md`。必要な最小の結合テストだけ追加し、projectを再生成する。

**Interfaces:** 変更なし。承認済み設計§10の要件差分を反映する。NFR-PERF-3の境界と、前サイクル完走待ち・発話からの実測値を区別する。

- [ ] **Step 1: 要件対応を確認。** Spec各節→Task対応を最後に再確認する。未検証の実機項目をFAIL/PASSではなく未実施と記録する。setup/接続/校正/ペアリング窓/保存失敗/切断/サーボ保持の利用手順をREADMEに記載する。
- [ ] **Step 2: 全ホスト検証。** `ruby scripts/generate_project.rb`、`ruby scripts/test_generate_project.rb`、`ios_test`（only-testingなし）、Task 4と同じgeneric iOS build、`git diff --check`。Expected: 全自動試験failures0、既存device-only skipは理由付き、BUILD SUCCEEDED、generatorの再実行で差分なし。実API・BLE・実機を起動しない。
- [ ] **Step 3: 新しいレビュー担当によるブランチ確認。** 実行方法に従い全差分をレビューし、Critical/Importantを解消して該当試験を再実行する。デバイス専用コードをホストのPASSだけで受入済みにしない。
- [ ] **Step 4: 利用者在席で実機を確認。** iPhone初回接続・既知再接続5秒以内、初回暗号化と60秒窓外拒否、校正保存と電源再投入、7動作×3強度、発話同期300ms目標、切断からFW復帰、再接続で予約非再生、cal専有、2秒静止時PWM停止、最大可動域を低速1方向ずつ確認する。BLE toolsとiPhoneを同時centralとして争わせない。利用者が不在ならこのStepは未実施として明示し、実機操作に進まない。
- [ ] **Step 5: Commitと引き渡し。** 検証記録には日付・ビルドSHA・条件・実測・未実施を残し、`docs: record iOS robot-link validation`で明示パスのみcommitする。新ブランチのマージ/pushは全体の検証結果を示して、当該ブランチの統合指示に従う。

## 自己点検（計画作成時）

| 設計の節 | 実装/検証するTask |
|---|---|
| 目的・範囲・方式・標準技術 | 1/4/6/10、Global Constraints |
| 構成と値型境界 | 1/2/3/4/7/8 |
| 起動・接続・再接続・世代・PING・フロー制御 | 3/4/9 |
| 予約・ターン・失敗・発話同期・4秒目安 | 2/7/8/9 |
| 振幅・強さ・自動動作・静止時停止 | 7/9/10 |
| 校正専有・プレビュー・保存・戻す・切断 | 5/6/9 |
| UI・既存アプリ・プライバシー・観測 | 6/8/9/10 |
| 要件差分・実機受入 | 10 |

全タスクの後続参照はInterfacesに定義した名称を使う。時間は単調時刻、wireはdeci整数、UIだけ度へ変換する。新規テストを「実装が呼ぶprivateメソッドを呼んだか」だけで固定せず、送ったbytes・公開状態・実行順序・失効した要求の不在で確認する。
