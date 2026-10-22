# Cat Robot v2 要件定義書 — Claude 対話＋2 軸首制御（iPhone 完結構成）

| 項目 | 内容 |
|---|---|
| 版 | 1.0（2026-10-11） |
| 状態 | 要件確定（ユーザー承認済み）。実装計画は別文書 |
| 対象 | iOS アプリ（本リポジトリ）、XIAO ESP32C3 ファームウェア、BLE 通信仕様 |
| ハードウェア基準 | Fusion 360 ドキュメント **Cat robot rebuild v302**（2026-10-11 にライブ実測。`~/workspace/Fusion/docs` 配下の 8 月設計書は参考扱いで、値は転記していない） |
| 作成経緯 | 本リポジトリの Gemma 版 MVP を器として、ほぼ全面的に再構築する |

本書の数値は次の 3 種類に区別する。

- **実測**: Fusion の現行モデルからスクリプトで取得した値。
- **公式**: 製造者・Apple・Anthropic の公開文書に基づく値（§13 に出典）。
- **推定／仮定**: 本書で宣言した仮定。実装前または受入時に測り直す（§10）。

---

## 1. 背景と目的

### 1.1 製品像

猫型の卓上ロボット。頭部に iPhone 16 Pro を Qi2 で保持し、iPhone の画面が猫の顔、iPhone 上のアプリが猫の脳になる。利用者が話しかけると、アプリが聞き取り、Claude が返答を生成し、端末内の音声合成で話す。返答に合わせて首（ヨー・ピッチの 2 軸）が頷く・横に振る・かしげるなどの動きをし、画面の表情も変わる。

### 1.2 目的

1. Claude の会話品質で、家庭に置ける「生きている感じ」のする猫を実現する。
2. 自宅サーバもクラウドサーバも運用せず、iPhone とロボット本体だけで完結させる。
3. ロボット本体と iPhone を 1 セットとして家族・知人へ配布（TestFlight）できる状態にする。

### 1.3 成功基準

| # | 基準 | 判定方法 |
|---|---|---|
| S1 | 呼びかけから 2.5 秒以内に話し始める（通常のネットワーク環境、Opus 5.5、effort low） | §10 の遅延計測 |
| S2 | 返答の内容に合った首の動きと表情が、発話と同期して出る | 受入レビュー（§10） |
| S3 | 1 日（朝〜就寝）電源を入れたまま、再起動なしで動き続ける | 24 時間連続試験 |
| S4 | 配布先が、アプリをインストールして 10 分以内に自分のロボットと会話できる | 新規セットアップ試験 |
| S5 | 1 家庭あたりの Claude 利用料が月額の目安（§8.6）に収まる | Claude Console の利用量 |

---

## 2. スコープ

### 2.1 含むもの

- iOS アプリ（SwiftUI、iOS 27 以上）: 会話、Claude 連携、首制御、表情、顔追尾、記憶、設定、オンボーディング、キャリブレーション。
- XIAO ESP32C3 ファームウェア: BLE 受信、サーボ駆動、可動域・速度の強制、ウォッチドッグ、キャリブレーション値の保存。
- BLE 通信仕様（GATT サービス、コマンド集合、状態通知）。
- App Attest を使った配布構成（API キーを配布物に含めない）。
- 受入試験の項目。

### 2.2 含まないもの

- LiveKit Agents、Python ワーカー、自前サーバ、プロキシ。
- App Store 公開、課金、アカウント機能、クラウド同期。
- ロボット本体の機構・外装の改修（本書はハードウェアを所与とする）。
- 日本語以外の対応（文字列はローカライズ可能な構造にはするが、資産は日本語のみ）。
- 既存の Gemma 4 E2B（LiteRT-LM）経路。本版で撤去する。

---

## 3. 確定事項と制約

### 3.1 構成の決定（A1）

| 決定 | 内容 | 根拠 |
|---|---|---|
| D1 | 会話エンジンは Apple Foundation Models フレームワークの `LanguageModelSession` に、Anthropic 公式 Swift パッケージ **ClaudeForFoundationModels** を差して使う | 公式。iPhone 単体で Claude を呼べ、ストリーミング・`@Generable`・端末側 `Tool` 呼び出しが揃う |
| D2 | 認証は **App Attest**（`AuthMode.appAttest(clientID:)`）。開発時の Simulator だけ `.apiKey` | 公式。アプリに鍵を埋め込まず、プロキシも不要 |
| D3 | LiveKit Agents は不採用 | 公式リポジトリの説明どおり「サーバ上で動く参加者」を作る Python/Node 用で、iPhone 上では動かない |
| D4 | 音声認識は Apple SpeechAnalyzer、読み上げは Supertonic 3（いずれも端末内、既存資産） | Anthropic は開発者向けの音声 API を提供しておらず、Claude API は文字のみ |
| D5 | 曖昧な発話の宛先判定と、オフライン時の短い返答は Apple の端末内モデル（`SystemLanguageModel`） | 同じ `LanguageModelSession` API なので差し替えコストが小さい |
| D6 | iPhone ↔ ロボットは BLE。ロボット側は XIAO ESP32C3 | Wi-Fi 設定が不要で各家庭の初期設定が簡単 |
| D7 | 既定モデルは Claude Opus 5.5。設定で Sonnet 5.5 / Haiku 5.5 に変更可。変更は次の会話セッションから反映 | ユーザー決定。プロンプトキャッシュはモデル単位なので会話途中では切り替えない |
| D8 | 対応言語は日本語のみ | ユーザー決定 |
| D9 | 顔は新デザイン。黒い外装と物理的な耳に合わせ、画面には目・鼻・口・ひげを描く | ユーザー決定 |
| D10 | 既存リポジトリを使うが、中身はほぼ作り直す | ユーザー決定 |

### 3.2 プラットフォーム制約

| 項目 | 値 | 区分 |
|---|---|---|
| iOS 最低バージョン | **27.0**（`LanguageModel` プロトコルは iOS 27.0 で正式提供。β フラグなし） | 公式 |
| Xcode | 27 以上 | 公式 |
| 端末 | iPhone 16 Pro を基準端末とする。Apple Intelligence 非対応端末では D5 の端末内モデルが使えないため §6.2 の代替経路を使う | 公式＋§11 R1 |
| ClaudeForFoundationModels | 0.2.x 系（最新 0.2.3 = 2026-10-07、直近 3 週で 3 リリース、Apache-2.0）。Anthropic の文書は本パッケージを β と位置づけ、API 変更の可能性を明記している。バージョンは固定して依存する | 公式 |
| App Attest | 物理端末のみ（Simulator と Secure Enclave 非搭載機では不可）。トークンは 1 時間有効・自動更新・ワークスペース単位で、Messages API 呼び出しだけを許可する。統合の作成には組織の admin / owner 権限が必要 | 公式 |
| Bundle ID / Team | `com.kamby.CatRobot` / `VUB4VP6453`（既存プロジェクト設定） | 実測（pbxproj） |

### 3.3 Claude 側の運用前提

- 利用料は App Attest 統合を登録したワークスペースに課金される。配布先の利用もすべて作者の負担になる（§8.6）。
- App Attest 統合は Claude Console の「App integrations」で Team ID と Bundle ID を登録して作る。開発用 Bundle ID を分ける場合は同じ統合に追加登録する（最大 32 件）。
- 統合の取り消しは恒久的。取り消すと既存トークンも失効する。

---

## 4. ハードウェア前提（Cat robot rebuild v302 のライブ実測）

### 4.1 可動部

| 項目 | 値 | 区分 |
|---|---|---|
| ヨー可動域 | **−60° … +60°**（as-built ジョイント `J_YAW` のリミット） | 実測 |
| ピッチ可動域 | **−30° … +30°**（as-built ジョイント `J_PITCH` のリミット。8 月設計の「上 15°／下 20°」から変更されている） | 実測 |
| ヨー軸 | 鉛直。X = 0、Y = −29.7 mm | 実測 |
| ピッチ軸 | 水平。ヨー軸上の高さ Z = 200.0 mm を通る | 実測 |
| 駆動 | **両軸ともサーボ出力軸がジョイント軸と一致（直結 1:1、減速なし）** | 実測（出力ギアの円筒面軸がジョイント軸上） |
| サーボ | DSSERVO DS3218 相当の標準サイズサーボ（MG996 互換外形、25T スプライン、PWM）×2 | 実測（6 ソリッド構成の STEP が配置済み。CAD の部品名に MG996 互換の記載） |
| サーボ定格 | ストールトルク 18 kg·cm（1.77 N·m）@5.0 V。販売者掲載値は 18〜20 kg·cm で揺れる。ストール電流は公開資料で確認できなかったため T-H1 で実測する | 公称（販売者掲載） |
| 軸受 | 608 ×4（ヨー上下、ピッチ左右） | 実測 |
| 現在の表示姿勢 | ヨー +24.7°、ピッチ −4.6° に回した状態で保存されている。ジョイント値は 0 と表示されるため、本書のリミットは **正面正対を 0°** として解釈する | 実測 |

### 4.2 質量とトルク（推定）

ライブ体積に材料密度（PLA/PETG 1.27 g/cm³、鋼 7.85 g/cm³）を掛け、購入部品は公称質量（iPhone 16 Pro 199 g、DS3218 60 g、Qi2 パック 35 g、608 軸受 12 g）に置き換えて算出した。CAD の質量プロパティ（頭部 1,161 g）は Qi2 パックと軸受が鋼扱いになっているため採用しない。

| 項目 | 値 | 区分 |
|---|---|---|
| 頭部可動部（ピッチで動く部分）の質量 | 約 523 g | 推定 |
| 頭部重心のピッチ軸からの距離 | 28.2 mm | 推定 |
| ピッチ軸まわりの静的重力トルク（最悪姿勢） | 約 0.145 N·m ＝ DS3218 ストールの約 8% | 推定 |
| ヨーで動く部分の質量 | 約 680 g（頭部 523 g ＋ ヨー組立 160 g） | 推定 |

受入時に実機で保持電流と温度を測る（§10 T-H3）。印刷部品はインフィル次第で軽くなるので、上記は安全側の値である。

### 4.3 電装・電源（ユーザー確認済み＋実測）

| 項目 | 値 | 区分 |
|---|---|---|
| 入力 | DC ジャック、**19 V** AC アダプタ | ユーザー |
| 系統 1 | 19 V → **5.0 V** 降圧（基板 60 × 51 mm）→ サーボ 2 系統と XIAO（5V ピン給電）を **共用** | ユーザー＋実測 |
| 系統 2 | 19 V → Qi2 充電モジュール（U1E 基板 32 × 20 mm、φ60 × 8 mm パック）→ iPhone | ユーザー＋実測 |
| 配電 | ユニバーサル基板 60 × 40 mm: サーボコネクタ J4/J5、ヒューズ F1〜F3、470 µF 電解コンデンサ、J1〜J3 ヘッダ | 実測 |
| 制御 | Seeed **XIAO ESP32C3**（Wi-Fi/BLE 5.0、外付けアンテナ）、170 穴ブレッドボード上に 5V/GND/制御端子とプルダウン抵抗 | ユーザー＋実測 |
| ヒューズ F1〜F3 の定格 | CAD には形状がなく読めない。実物で確認する（§12 O4） | 実物確認 |

共用 5 V レールのため、サーボの起動電流で XIAO がブラウンアウトする可能性がある。§7.6 で対策を要件化する。

### 4.4 iPhone とカメラ

| 項目 | 値 | 区分 |
|---|---|---|
| 端末 | iPhone 16 Pro（149.6 × 71.5 × 8.25 mm）、横向きに保持、画面は前方を向く | 実測 |
| 前面カメラの露出 | 画面全面（長辺 8 mm × 短辺 8.5 mm の格子）から法線方向 25 mm 以内に外装材料なし。両短辺端のカメラ想定位置 6 点（端から 7.5 mm、短辺方向 −8 / 0 / +8 mm）から **上下左右 ±50° の視野、80 mm 先まで** 頭部・首・胴体の外装と駆動部品 16 体に非干渉 | 実測 |
| Dynamic Island の位置 | 横向きのため画面の左右どちらかの端。どちらの端が上になる向きでも視野は開けている（上記実測） | 実測 |

### 4.5 外装

| 項目 | 値 | 区分 |
|---|---|---|
| 実機の外装色 | **黒**（CAD の外観は「PLA White」だが、実機は黒で印刷） | ユーザー |
| 耳 | 頭頂カバー `CE08_HEAD_LID` に含まれる **物理パーツ**（先端 Z = 287.4 mm） | 実測 |
| 全高 | 287.4 mm | 実測 |
| ベース footprint | 119.8 × 152.5 mm | 実測 |

---

## 5. システム構成

### 5.1 全体像

```
┌──────────────── iPhone 16 Pro（頭部、Qi2 給電）────────────────┐
│  Cat Robot アプリ                                               │
│  ┌ 音声 ┐  ┌ 会話 ┐  ┌ Claude ┐  ┌ 動き ┐  ┌ 顔 ┐  ┌ 視覚 ┐  │
│  │STT   │→│宛先  │→│Session │→│調停  │→│表情│  │追尾  │  │
│  │TTS   │←│記憶  │←│Tools   │  │軌道  │  └────┘  │見る  │  │
│  └──────┘  └──────┘  └───┬────┘  └──┬───┘          └──────┘  │
│                           │          │ BLE Central               │
└───────────────────────────┼──────────┼───────────────────────────┘
                 HTTPS      │          │ BLE（GATT）
                 App Attest │          │
            ┌───────────────▼┐    ┌────▼──────────────────────────┐
            │ Claude API     │    │ XIAO ESP32C3 ファームウェア    │
            │ (api.anthropic │    │ BLE Peripheral → 制限 → PWM   │
            │  .com)         │    │ DS3218 ヨー / DS3218 ピッチ    │
            └────────────────┘    └───────────────────────────────┘
```

サーバは Claude API 以外に存在しない。ロボット側はアプリからの指示がなければ中立で脱力する（§7.4）。

### 5.2 アプリのモジュール

| モジュール | 責務 | 既存コードの扱い |
|---|---|---|
| Speech | マイク取り込み、SpeechAnalyzer による日本語認識、発話区切り（無音 1.2 秒・最長 20 秒）、Supertonic 読み上げ（文単位先読み） | 流用（`AppleSpeechRecognizer`、`UtteranceSegmenter`、`Supertonic*`、`ReplyPlaybackCoordinator`） |
| Addressee | 呼び名・会話中ウィンドウ・曖昧時の聞き返し | 流用（`AddresseePolicy`、`EngagementWindow`、`FoundationModelAddressClassifier`） |
| Conversation | `LanguageModelSession` の生成・保持・再生成、ストリーミング、エラー写像 | 作り直し（`GemmaConversationService` を `ClaudeConversationService` に置換） |
| Tools | 首・表情・見る・覚える の `Tool` 実装 | 新規 |
| Motion | 動作の調停（ツール＞追尾＞待機）、軌道生成、BLE への送信 | 新規 |
| RobotLink | BLE スキャン・接続・再接続・コマンド送信・状態受信・キャリブレーション | 新規 |
| Vision | 前面カメラのキャプチャ、顔検出、「見る」用フレーム取得 | 新規 |
| Face | 顔の描画、表情プリセット、状態連動、字幕 | 作り直し（`CatFaceView` を置換） |
| Memory | 会話要約、長期メモ、保存・削除 | 作り直し（Gemma 依存の `GemmaConversationMemory` を汎用化） |
| Settings | モデル、声、動きの強さ、記憶、接続、おやすみ時刻 | 拡張（`VoiceSettingsView` を設定画面に統合） |
| Lifecycle | ロボットモード、画面常時点灯、おやすみ、復帰、割り込み | 拡張（`ConversationViewModel`、`ConversationScreenWakeLock`） |

撤去: `Gemma*`、`LiteRTGemmaRuntime`、LiteRT-LM パッケージ依存、Gemma 用スクリプト。ONNX Runtime は Supertonic が使うため残す。

### 5.3 Claude セッションの構成

- `ClaudeLanguageModel(name:auth:userProfileID:fixedEffort:fallbacks:serverTools:baseURL:timeout:)` を 1 会話につき 1 つ生成し、`LanguageModelSession(model:tools:instructions:)` に渡す。
- `instructions` は次の順に組み立て、前方を不変に保つ（キャッシュ効率のため）: ① 人格・話し方・安全方針（固定） ② ツールの使い方（固定） ③ 長期メモ（変更時のみ更新） ④ セッション固有情報（現在時刻の粒度は「時間帯」までに留める）。
- ツールは `tools:` 配列で渡す（端末側で実行）。サーバ側ツール（Web 検索など）は初版では使わない。
- 画像は Foundation Models の添付（画像）セグメントとしてツール結果に含める。Opus 5.5 / Sonnet 5.5 / Haiku 5.5 の定数はいずれも画像入力に対応している（パッケージの capability 宣言で確認済み）。
- `fixedEffort` の既定は `.low`（会話の遅延優先）。設定で `.medium` を選べる。
- `fallbacks` は使わない（`.models([])`。2026-10-11 の実装計画で `.serverDefault` から変更）。`fallbacks` は安全方針上の拒否応答が出たときだけ API が代替モデルで続きを生成する仕組みで、障害・レート制限の代替ではない（それは §6.2 の端末内モデル切り替えが担う）。Haiku 5.5 にはサーバ側の代替が無く、`fallbacks` に既定を指定しても拒否応答はそのまま、モデルの一覧を指定すると 400 になる（公式: Anthropic のモデル移行ガイド「Migrating to Claude Haiku 5.5」Safeguards 節）。パッケージ `ClaudeFallbacks` の注記も非対応モデルへの `fallbacks` 指定を API が拒否するとしている。設定で選べる 3 モデルの構成を揃えるため、どのモデルでも `fallbacks` を付けない。拒否応答は `LanguageModelError.refusal` として既存の文言で短く伝える。
- `timeout` は 30 秒（パッケージ既定は 60 秒）。超過時は端末内モデルへの切り替え（§6.2）を試みる。
- 文脈超過（`LanguageModelError.contextSizeExceeded`）は要約してセッションを作り直す（既存方式）。

---

## 6. 機能要件（アプリ）

要件 ID は `FR-領域-番号`。「必須」は初版で満たす。「推奨」は初版で満たせない場合、理由を記録して次版に送れる。

### 6.1 会話

| ID | 要件 | 優先度 |
|---|---|---|
| FR-CONV-1 | 会話画面が前面にある間、端末内で連続して聞き取り、発話の終わりを無音 1.2 秒で確定する（既存値を初期値とし、設定可能な定数に置く） | 必須 |
| FR-CONV-2 | 呼び名（ねこ、猫ちゃん、Cat Robot、キャットロボット）または会話中ウィンドウ内の発話は分類なしで受け付ける。それ以外は宛先判定にかける | 必須 |
| FR-CONV-3 | 宛先判定は Apple の端末内モデルで行う。端末内モデルが利用不可（Apple Intelligence 非対応・未準備）の場合は Claude Haiku 5.5 のステートレス呼び出しで代替する | 必須 |
| FR-CONV-4 | 曖昧な発話には「今の、ぼくに言った？」と一度だけ聞き返す（既存仕様を踏襲、15 秒で破棄） | 必須 |
| FR-CONV-5 | 返答はストリーミングで字幕に反映し、一文が確定した時点で読み上げを始める（既存の文単位先読み方式） | 必須 |
| FR-CONV-6 | 読み上げ中は聞き取りを止め、終わったら自動で再開する。割り込み（バージイン）は初版では非対応と明記する | 必須 |
| FR-CONV-7 | マイクや認識が使えないときは文字入力で会話できる | 必須 |
| FR-CONV-8 | 返答は既定で 1〜2 文。利用者が詳しく求めたときだけ長くする（instructions で指示） | 必須 |
| FR-CONV-9 | 返答文のうち読み上げる前に、ツール呼び出し由来の動きと表情を開始する（§6.3） | 必須 |

### 6.2 Claude 連携とモデル

| ID | 要件 | 優先度 |
|---|---|---|
| FR-LLM-1 | 返答生成は ClaudeForFoundationModels 経由の Claude で行う。既定モデルは Opus 5.5 | 必須 |
| FR-LLM-2 | 設定画面でモデルを Opus 5.5 / Sonnet 5.5 / Haiku 5.5 から選べる。選択は **次に会話セッションを作るとき** に反映し、進行中のセッションでは切り替えない。即時に切り替えたい場合は「新しい会話を始める」操作でセッションを作り直す（長期メモは保持） | 必須 |
| FR-LLM-3 | 認証は App Attest。起動時に `authenticateIfNeeded()` を呼び、失敗を会話開始前に画面で示す。Simulator と開発ビルドだけ環境変数由来の API キーを使い、鍵をソースやリソースに含めない | 必須 |
| FR-LLM-4 | 返答本文をまだ出していないターンで、通信到達不能（ネットワーク断・タイムアウト・レート制限）または汎用の生成失敗（HTTP 5xx を含む）が起きたときは、その会話ターンを Apple の端末内モデルで生成する。公開 API で識別できる認証失敗・拒否応答・ガードレール違反・文脈超過・入力過長・取り消しは対象外。制約: ClaudeForFoundationModels 0.2.3 は HTTP 5xx を含む API エラーの種別を公開 API に出さないため、一部の設定・権限・不正要求のエラー（HTTP 400/403/404）も汎用の生成失敗として代替の対象に含まれる。切り替えた場合は冒頭で「今はいつものように話せないから、簡単に答えるね」の趣旨を短く告げる（原因は断定しない。レート制限も含むため「電波が弱い」とは言わない）。端末内モデルも使えない端末では、会話不可を表示して待機動作だけ続ける | 必須 |
| FR-LLM-5 | 端末内モデルへの切り替え中も同じ `Tool` 群を渡し、首と表情は動く | 推奨 |
| FR-LLM-6 | ネットワークが戻ったら次のターンから Claude に戻す。戻すときは直前の端末内モデルでのやり取りを文字として引き継ぐ | 必須 |
| FR-LLM-7 | effort は既定 low。設定で medium を選べる | 推奨 |
| FR-LLM-8 | 拒否応答（`refusal`）や代替モデルへの切り替えが起きたことを診断ログに残す（本文は残さない）。記録するのは正規化したエラー種別・切り替えの事象・連続回数などの構造化情報に限り、API エラーの message や応答本文の抜粋（`localizedDescription` を含む）は `privacy: .private` でも残さない | 必須 |

### 6.3 首の動き

**ツール（Claude が呼ぶ）**

| ID | 要件 | 優先度 |
|---|---|---|
| FR-MOV-1 | `move_head` ツールを提供する。引数: `gesture`（nod / shake / tilt / look_up / look_down / look_at_user / center）、`intensity`（small / medium / large）、`repeats`（1〜3、既定 1）。戻り値は実行結果の短い文字列 | 必須 |
| FR-MOV-2 | 1 ターンに複数のツール呼び出しがあっても順に実行し、合計時間が 4 秒を超える分は切り詰める | 必須 |
| FR-MOV-3 | 「かしげる」はロール軸がないため、ヨー 10〜15° ＋ ピッチ下 5〜8° の組み合わせで近似する | 必須 |
| FR-MOV-4 | 動きの振幅は intensity で変える。上限: 頷き ピッチ ±15°、横振り ヨー ±25°、見上げ／うつむき ピッチ ±20°。いずれも §7 の機械リミット内 | 必須 |
| FR-MOV-5 | ツール由来の動きは読み上げ開始と同時に始め、読み上げが先に終わっても動きは完了させる | 必須 |

**自動動作（Claude を介さない）**

| ID | 要件 | 優先度 |
|---|---|---|
| FR-MOV-6 | 待機中は 4〜10 秒おきにランダムな微小動作（ヨー ±3°、ピッチ ±2°、1〜2 秒かけて移動）を行う。設定でオフにできる | 必須 |
| FR-MOV-7 | 聞き取り中、発話が確定した瞬間に小さく頷く（ピッチ 5°、0.6 秒） | 必須 |
| FR-MOV-8 | 顔追尾: 前面カメラで検出した顔の水平位置に合わせてヨーを追従する。不感帯 ±4°、追従速度は設定速度の 50% 以下、追尾範囲 ヨー ±45°。ピッチの追従は ±10° に制限する | 必須 |
| FR-MOV-9 | 顔を 10 秒以上見失ったら、ゆっくり正面に戻る | 必須 |
| FR-MOV-10 | 複数人の顔がある場合は、画面中央に最も近い顔を対象にする | 推奨 |

**調停と制限**

| ID | 要件 | 優先度 |
|---|---|---|
| FR-MOV-11 | 優先順位は ツール由来 ＞ 顔追尾 ＞ 待機微動。上位の動作中は下位を止め、終了後に再開する | 必須 |
| FR-MOV-12 | アプリ側の自律動作の範囲は ヨー ±45°、ピッチ ±20° に抑える（ファームウェアの ±60° / ±30° より内側） | 必須 |
| FR-MOV-13 | 速度は「動きの強さ」設定（控えめ 0.5× / 標準 1× / 活発 1.5×）で変える。標準は ヨー 20°/s、ピッチ 12°/s（FW-LIM-2 の改訂で上限がヨー 180°/s・ピッチ 120°/s になったため、サブ計画 3/4 で見直す）。ファームウェア上限（§7.3）は超えない | 必須 |
| FR-MOV-14 | 接続が切れている間は動作要求を破棄し、ツールには「今は首が動かせない」を返す | 必須 |
| FR-MOV-15 | おやすみ中（§6.8）は一切動かさない | 必須 |

### 6.4 顔と表情

| ID | 要件 | 優先度 |
|---|---|---|
| FR-FACE-1 | 画面全体を黒背景とし、外装（黒）と一体に見せる。画面内に耳は描かない | 必須 |
| FR-FACE-2 | 描く要素は 目・鼻・口・ひげ。SwiftUI のベクター描画で、正規化座標のレイヤーに分けて個別にアニメーションできる | 必須 |
| FR-FACE-3 | 表情プリセットを用意する: neutral、happy、curious、thinking、listening、speaking、sleepy、surprised、sorry。各プリセットは目の形・まぶた・瞳の位置・口の形・ひげの角度で定義する | 必須 |
| FR-FACE-4 | `express` ツールを提供する。引数: `expression`（上記プリセット名）、`hold_seconds`（1〜10、既定 3）。保持後は状態連動の表情に戻る | 必須 |
| FR-FACE-5 | 状態連動: 聞き取り中は listening、考え中は thinking、発話中は speaking（口の開閉は音声の文単位イベントに同期）、待機中は neutral にまばたきを加える | 必須 |
| FR-FACE-6 | 瞳は顔追尾の対象方向にわずかに寄せる（首より先に目が動く） | 推奨 |
| FR-FACE-7 | 字幕は画面下部に 1〜2 行、Dynamic Island と重ならない位置に置く。VoiceOver・Dynamic Type・Reduce Motion への対応は既存水準を維持する | 必須 |
| FR-FACE-8 | デザイン指針: 黒猫の顔として破綻しないこと、目は発光する要素として最も明るく、鼻と口は低彩度、ひげは細い線。最終デザインは別途デザインレビューで確定し、本書はこの指針のみを定める | 必須 |

### 6.5 視覚

| ID | 要件 | 優先度 |
|---|---|---|
| FR-VIS-1 | 前面カメラを低解像度（640×480 以下）・低フレームレート（5 fps 以下）で取り込み、Vision フレームワークで顔の矩形を検出する。フレームは端末外に出さず、保存もしない | 必須 |
| FR-VIS-2 | `look` ツールを提供する。Claude が呼んだときだけ、直近の 1 フレームを長辺 1,024 px 以下に縮小し、ツールの戻り値に画像添付として含めて返す。パッケージはツール結果の画像を Claude の image ブロックに変換し、EXIF 等のメタデータを除去し、長辺 1,568 px・1.15 MP・5 MB の上限に収める。Claude は同じターンの中で画像を見て返答を続け、アプリはそれを読み上げる。常時送信はしない | 必須 |
| FR-VIS-3 | 画像を送る直前に表情を curious にし、字幕に「見ています」を出す（送信していることを可視化） | 必須 |
| FR-VIS-4 | カメラ権限が拒否された場合は顔追尾と `look` を無効にし、会話は継続する | 必須 |
| FR-VIS-5 | カメラは会話画面が前面にあるときだけ動かし、おやすみ中は止める | 必須 |

### 6.6 記憶

| ID | 要件 | 優先度 |
|---|---|---|
| FR-MEM-1 | 会話の記憶は 2 層: ① 会話要約（直近の文脈、セッション再生成時に引き継ぐ） ② 長期メモ（人物・好み・出来事・約束の短い事実） | 必須 |
| FR-MEM-2 | `remember` ツールを提供する。引数: `fact`（60 文字以内の事実）、`category`（person / preference / event / promise / other）。保存後に短い確認を返す | 必須 |
| FR-MEM-3 | 長期メモは最大 200 件・合計 4,000 トークン相当を上限とし、超えたら Claude に統合・要約させる | 必須 |
| FR-MEM-4 | 長期メモは次のセッションの instructions に注入する。注入文の形式を固定し、変更がない限りバイト単位で同一にする（キャッシュ保護） | 必須 |
| FR-MEM-5 | 保存先は既存の `Application Support/CatRobot/ConversationMemory/`（会話要約は既存の `current.json`、長期メモは新設の `facts.json`）。既存どおり完全ファイル保護を適用し、端末バックアップから除外する。iCloud 同期の対象にもしない | 必須 |
| FR-MEM-6 | 設定の「会話を忘れる」で要約と長期メモの両方を削除できる。削除の失敗時は再試行まで会話を再開しない（既存方針） | 必須 |
| FR-MEM-7 | 音声データ・生成途中の返答・宛先判定に使った発話・カメラ画像は保存しない | 必須 |

### 6.7 ロボット接続とキャリブレーション

| ID | 要件 | 優先度 |
|---|---|---|
| FR-LINK-1 | 初回は接続画面で近くのロボット（アドバタイズ名 `CatRobot-XXXX`）を一覧し、選んでペアリングする。以降は自動再接続する | 必須 |
| FR-LINK-2 | 接続中は 1 秒ごとにキープアライブを送る。切断を検出したら 2 秒間隔で再接続を試み、画面の状態表示を「首と未接続」にする | 必須 |
| FR-LINK-3 | キャリブレーション画面: ヨー・ピッチの中立オフセット（±20°、0.5° 刻み）と回転方向の反転をスライダーで調整し、その場で首が追従する。「保存」でロボット側に不揮発保存する | 必須 |
| FR-LINK-4 | キャリブレーション画面に「正面を向かせる」「上下左右の端まで動かす（リミット確認）」ボタンを置く | 必須 |
| FR-LINK-5 | ロボットのファームウェア版数と状態（接続、角度、トルク状態、エラー）を設定画面で確認できる | 推奨 |
| FR-LINK-6 | ロボットが見つからない・接続できない場合でも会話は続けられる（首だけ無効） | 必須 |

### 6.8 常駐動作（ロボットモード）

| ID | 要件 | 優先度 |
|---|---|---|
| FR-RUN-1 | 初回のオンボーディング完了後は、アプリを開くだけで BLE 接続と聞き取りが始まる | 必須 |
| FR-RUN-2 | 会話画面では画面を常時点灯にする（`isIdleTimerDisabled`）。Qi2 給電を前提とし、バッテリー残量が 20% を切ったら警告を字幕に出す | 必須 |
| FR-RUN-3 | 「おやすみ」（音声または設定）で、マイク・カメラ・首を止め、画面を最暗にして時計だけ表示する。「おはよう」または画面タップで復帰する | 必須 |
| FR-RUN-4 | バックグラウンド移行、オーディオ割り込み、経路変更では会話を止め、前面復帰時に自動で再開する（ロボットモードの例外として既存の「明示操作待ち」を上書きする）。ただし割り込みが電話など通話系の場合は通話終了後 3 秒待って再開する | 必須 |
| FR-RUN-5 | 熱状態（`ProcessInfo.thermalState`）が serious 以上になったらカメラを止め、待機微動を止め、字幕で知らせる。critical では会話も一時停止する | 必須 |
| FR-RUN-6 | iOS の制約によりバックグラウンドでは動作しない旨をオンボーディングで説明する | 必須 |

### 6.9 設定

| 項目 | 内容 |
|---|---|
| モデル | Opus 5.5（既定）/ Sonnet 5.5 / Haiku 5.5。反映タイミングの説明文を併記 |
| effort | low（既定）/ medium |
| 声 | Supertonic F1〜F5、M1〜M5（既存） |
| 動きの強さ | 控えめ / 標準 / 活発。待機微動 オン／オフ。顔追尾 オン／オフ |
| 記憶 | 長期メモの一覧表示と個別削除、「会話を忘れる」 |
| ロボット | 接続先の変更、キャリブレーション、ファームウェア情報 |
| おやすみ | 自動おやすみ・おはようの時刻（任意、既定は未設定） |
| 利用量 | 当日・当月の会話ターン数と概算トークン数、1 日の上限（既定 300 ターン、超過時は端末内モデルに切り替える） |
| 情報 | AI であること、送信されるデータ、ライセンス表示（Supertonic、ONNX Runtime、ClaudeForFoundationModels） |

### 6.10 オンボーディング

| ID | 要件 | 優先度 |
|---|---|---|
| FR-ONB-1 | 初回は ① AI であることと送信データの説明 ② マイク・音声認識 ③ カメラ ④ Bluetooth の順に権限を求め、各権限の用途を 1 文で示す | 必須 |
| FR-ONB-2 | App Attest の初回認証をオンボーディング中に行い、失敗時は原因（ネットワーク、非対応端末、統合の取り消し）に応じた案内を出す | 必須 |
| FR-ONB-3 | ロボットの接続とキャリブレーション（§6.7）をオンボーディングの最後に案内する。スキップ可能 | 必須 |
| FR-ONB-4 | 端末内モデルが使えない端末では、その影響（オフライン時に会話不可、宛先判定に Claude を使う）を説明する | 必須 |

### 6.11 エラーと復旧

| 状況 | 振る舞い |
|---|---|
| App Attest 失敗 | 会話開始を止め、再試行ボタンと原因別の案内。開発ビルドでは API キー経路に切り替え可能 |
| Claude のレート制限・5xx・その他の汎用の生成失敗 | 返答本文を出す前なら、そのターンを端末内モデルで生成（FR-LLM-4。0.2.3 では一部の 400/403/404 も含まれる）。代替対象の失敗が連続 3 回で「少し待って」と告げ、成功したら数え直す |
| 文脈超過 | 要約して新セッション。利用者には知らせない（短い間が空くだけ） |
| BLE 切断 | 首だけ無効化し会話継続。再接続後は中立から再開 |
| カメラ不可 | 追尾と `look` を無効化 |
| 音声認識資産の未準備 | 既存の準備画面を表示し、文字入力を案内 |
| 熱 | FR-RUN-5 |

---

## 7. 要件（ロボット側: XIAO ESP32C3 ファームウェア）

### 7.1 開発構成

| 項目 | 値 |
|---|---|
| ツールチェーン | PlatformIO 公式 `espressif32@8.0.0`（Arduino-ESP32 3.3.12）に確定（2026-10-23。手順は `firmware/README.md`） |
| ライブラリ | ESP32Servo 3.x（LEDC ベース、ESP32-C3 対応）、NimBLE-Arduino（BLE Peripheral）、Preferences（NVS 保存） |
| 自作範囲 | コマンド解釈、角度・速度の制限、軌道の補間、ウォッチドッグ、キャリブレーションの保存のみ |

### 7.2 ピン割当（実配線、2026-10-23 に配線図 E17 と実物で確認）

| 信号 | XIAO ESP32C3 ピン | 備考 |
|---|---|---|
| ヨーサーボ PWM | **D1（GPIO3）** | 200 Ω 直列と 47 kΩ プルダウン。ESP32-C3 のストラップピン GPIO2/8/9（D0/D8/D9）を避ける |
| ピッチサーボ PWM | **D3（GPIO5）** | 200 Ω 直列と 47 kΩ プルダウン |
| 5 V 入力 | 5V ピン | 降圧 5.0 V レールから |
| GND | GND | サーボ・降圧と共通 |
| 予備 | D4/D5（I²C）: 電流センサ（INA219 等）を後付けする場合に使う | 初版では未使用 |

実配線を正とし、ファームウェアの定数（`ServoDriver` の既定ピン 3・5）で合わせてある。O2 は解決済み。

### 7.3 動作制限（ファームウェアが強制）

| ID | 要件 |
|---|---|
| FW-LIM-1 | ヨー角は −60°〜+60°、ピッチ角は −30°〜+30°（キャリブレーション後の機械角）を超える指令を受けても **飽和** させる。拒否して止まらない |
| FW-LIM-2 | 速度上限の絶対値はヨー 180°/s、ピッチ 120°/s。アプリからの `SET_LIMITS` はこれより内側にしか設定できない。出荷既定はヨー 120°/s、ピッチ 100°/s。速度の下限は 5°/s、角度上限の下限は 5°（暫定、T-FW-2 で確定） |
| FW-LIM-3 | 静止から上限速度まで 0.2〜0.3 秒で達する S 字（加速度連続、ピーク加速度 ≤ 2V/0.2 s、加加速度 ≤ 4V/(0.2 s)²）とし、目標角への到達は 50 Hz で補間する |
| FW-LIM-4 | パルス幅は 500〜2,500 µs を上限とし、キャリブレーションの中立オフセットは ±20° まで |

### 7.4 ウォッチドッグと安全

| ID | 要件 |
|---|---|
| FW-SAFE-1 | 接続中にコマンドもキープアライブも 3 秒届かない場合、安全復帰速度（ヨー 90°/s、ピッチ 60°/s。Limits と無関係）で中立へ戻り（2 秒の期限つき）、到達または期限から 2 秒後にサーボを脱力（PWM 停止）する。PING などの保守要求では復帰を解除しない |
| FW-SAFE-2 | BLE 切断時は切断検出で待たずに FW-SAFE-1 の復帰を開始する |
| FW-SAFE-3 | 電源投入 500 ms 後に中立角を出力し、電源投入から 1.5 秒までに動作要求がなければ脱力して待つ。位置検出が無いため、起動時と休止からの復帰時に 1 回の合わせ動作は許容する |
| FW-SAFE-4 | `STOP` コマンドは補間を中断して即時に脱力する |
| FW-SAFE-5 | ブラウンアウトリセットを検出した場合はアドバタイズを再開し、状態通知に `brownout` フラグを立てる |

### 7.5 BLE GATT 仕様

アドバタイズ名 `CatRobot-XXXX`（XXXX は MAC 下位 2 バイト）。接続間隔 15〜30 ms を要求。初版はペアリング（Just Works ボンディング）を必須とし、ボンド済み端末が存在するときは電源投入後 60 秒間だけ新規ペアリングを受け付ける。

| 特性 | UUID（128 bit、ベース `C47B0000-6D1F-4B9E-9C9A-2A3B4C5D6E7F`） | 属性 | 内容 |
|---|---|---|---|
| Command | `C47B0001-…` | Write Without Response、≤20 B | §7.5.1 のコマンド |
| Status | `C47B0002-…` | Notify、5 Hz または変化時 | 指令角（ヨー・ピッチ、0.1° 単位 int16。補間中の指令角であって実測角ではない）、フラグ、電源電圧（本ハードでは 0）。詳細は §7.5.2 |
| Calibration | `C47B0003-…` | Read / Write | 中立オフセット（ヨー・ピッチ、0.1° int16）、反転フラグ、保存済みフラグ |
| Limits | `C47B0004-…` | Read / Write | 速度上限（ヨー・ピッチ、0.1°/s uint16）、角度上限（アプリ側さらに内側） |
| Info | `C47B0005-…` | Read | ファームウェア版、ハードウェア ID、プロトコル版（初版 1） |

#### 7.5.1 コマンド（リトルエンディアン、先頭 1 バイトが種別）

| 種別 | 名称 | ペイロード | 動作 |
|---|---|---|---|
| 0x01 | MOVE | yaw int16（0.1°）、pitch int16（0.1°）、speed uint8（上限に対する %、0 は 100 と同じ = 現在の速度上限） | 目標角へ制限付きで補間移動。≤50 Hz で連続受信可 |
| 0x02 | GESTURE | id uint8（1 nod / 2 shake / 3 tilt_l / 4 tilt_r / 5 look_up / 6 look_down）、amp uint8（0.1° 単位）、repeats uint8、speed uint8 | ファームウェア内蔵の定型動作。BLE の揺らぎに依存せず滑らかに動く |
| 0x03 | STOP | なし | 即時脱力 |
| 0x04 | CENTER | speed uint8 | 中立へ移動 |
| 0x05 | TORQUE | on uint8 | 0 で脱力、1 で保持 |
| 0x06 | SET_CAL | yaw_off int16、pitch_off int16、invert uint8（bit0 yaw、bit1 pitch） | 一時適用 |
| 0x07 | SAVE_CAL | req uint8（1〜255。0 は拒否） | NVS に保存。結果は Status の `save_seq` = req と SAVE_ERROR で伝える（§7.5.2） |
| 0x08 | SET_LIMITS | yaw_v uint16、pitch_v uint16、yaw_a int16、pitch_a int16 | FW-LIM-2 の内側で更新 |
| 0x09 | PING | seq uint8 | キープアライブ。Status に seq を返す |

アプリは追尾と待機微動には MOVE を、頷き・横振りには GESTURE を使う。GESTURE 中に MOVE が届いたら GESTURE 完了後に反映する。

#### 7.5.2 プロトコル版 1（確定、2026-10-23）

バイト列の正本は設計書 `docs/superpowers/specs/2026-10-23-xiao-firmware-ble-design.md` §4.6。要点:

- サービス UUID `C47B0000-6D1F-4B9E-9C9A-2A3B4C5D6E7F`。Info 以外の特性は暗号化リンク（Just Works ボンディング）でのみ読み書き・通知できる。アドバタイズ名 `CatRobot-XXXX`（本機は `CatRobot-5E8E`）
- Status（12 B）: yaw int16、pitch int16（0.1°、指令角）、flags uint16（bit0 LINK、bit1 TORQUE、bit2 MOVING、bit3 BROWNOUT、bit4 SATURATED、bit5 CAL_DIRTY、bit6 GESTURE、bit7 REJECTED、bit8 RETURNING、bit9 PAIR_OPEN、bit10 SAVE_ERROR）、ping seq uint8、state uint8（0 BOOT、1 BOOT_CENTER、2 IDLE、3 ACTIVE、4 RETURNING、5 RELAX_WAIT）、voltage uint16（0 固定）、rejected uint8、save_seq uint8。通知は 200 ms ごと、seq・フラグ・状態・save_seq の変化時は次の tick
- Calibration（6 B）: yaw_off int16、pitch_off int16、invert uint8（bit0 ヨー、bit1 ピッチ）、saved uint8。Limits（8 B）: yaw_v uint16、pitch_v uint16（0.1°/s）、yaw_a int16、pitch_a int16（0.1°）。Info（8 B）: proto、fw major/minor/patch、hw id（1 = E17）、caps、予約 2 B
- コマンド長は固定: MOVE 6、GESTURE 5、STOP 1、CENTER 2、TORQUE 2、SET_CAL 6、SAVE_CAL 2、SET_LIMITS 9、PING 2。長さ不一致・未知種別・GESTURE id 範囲外・TORQUE 0/1 以外・SET_LIMITS の負の角度上限・SAVE_CAL の req 0 は拒否（REJECTED）。それ以外の範囲外は飽和（SATURATED）
- 校正の保存: SET_CAL で値を送り、直前の `save_seq` と異なる req で SAVE_CAL、`save_seq` = req の Status を待つ（1 秒で同じ req を再送、冪等）。SAVE_ERROR = 0 なら成功、Calibration を Read して照合する
- GESTURE の実装は極値を経由する静止→静止の S 字移動の列（設計書 §4.4）。`speed` は保持時間を 100/speed 倍にし、移動区間は速度上限を speed% に縮める

### 7.6 電源に関する要件

| ID | 要件 |
|---|---|
| FW-PWR-1 | 2 サーボを同時に静止から動かし始めないよう、ピッチ側の開始を 50 ms 以上ずらす（実装は 3 tick = 60 ms。突入電流の分散） |
| FW-PWR-2 | 起動後 500 ms はサーボへ出力しない（降圧の立ち上がりと XIAO の起動を待つ） |
| FW-PWR-3 | 共用 5 V レールのサーボコネクタ直近に 1,000 µF 以上の電解コンデンサを追加することを推奨する（現状 470 µF）。ブラウンアウトが実機で観測された場合は必須に格上げする |
| FW-PWR-4 | サーボ信号線のプルダウン（既存）を維持し、XIAO リセット中にサーボが暴れないようにする |

---

## 8. 非機能要件

### 8.1 性能

| ID | 要件 | 計測 |
|---|---|---|
| NFR-PERF-1 | 発話終了 → 最初の字幕: 中央値 1.5 秒以下（Opus 5.5、effort low、Wi-Fi） | OSLog signpost（既存の `ConversationLatency`） |
| NFR-PERF-2 | 発話終了 → 読み上げ開始: 中央値 2.5 秒以下 | 同上 |
| NFR-PERF-3 | ツール呼び出し → 首が動き始めるまで 300 ms 以下 | BLE 送信時刻と Status 通知で計測 |
| NFR-PERF-4 | 顔追尾の遅れ: 顔の移動から首の追従開始まで 500 ms 以下 | 動画で確認 |
| NFR-PERF-5 | 顔検出の CPU 使用率が 5 fps で 10% 以下（iPhone 16 Pro） | Instruments |

### 8.2 信頼性

| ID | 要件 |
|---|---|
| NFR-REL-1 | 24 時間の連続稼働でクラッシュ・メモリ増加・音声経路の不整合がない |
| NFR-REL-2 | BLE 再接続は 5 秒以内（通常）。再接続後のキャリブレーションは不要 |
| NFR-REL-3 | Claude 側の障害時も会話機能全体が停止しない（FR-LLM-4） |

### 8.3 発熱と電力

| ID | 要件 |
|---|---|
| NFR-THERM-1 | Qi2 給電下で 1 時間会話を続けても `thermalState` が serious に達しない。達する場合はカメラのフレームレートを下げるか追尾を止める設計にする |
| NFR-THERM-2 | 給電なしでも 2 時間は会話できる（停電時の猶予） |

### 8.4 プライバシー

| ID | 要件 |
|---|---|
| NFR-PRIV-1 | 端末外に出るデータは、受け付けた発話の文字、会話要約と長期メモ（instructions として）、`look` 時の 1 枚の画像のみ。音声・カメラ映像の常時送信・保存はしない |
| NFR-PRIV-2 | 送信先は Anthropic の Claude API のみ。アナリティクス・クラッシュ収集 SaaS は使わない |
| NFR-PRIV-3 | 初回に AI であること、送信データ、課金が作者負担であることを表示する |
| NFR-PRIV-4 | 録音・画像を保存しない設計をテストで保証する（ファイル列挙テスト） |

### 8.5 セキュリティ

| ID | 要件 |
|---|---|
| NFR-SEC-1 | API キーをリポジトリ・配布物・ログに含めない。配布ビルドは App Attest のみ |
| NFR-SEC-2 | App Attest のクライアント ID は配布物に含めてよい（鍵ではない）。統合の取り消し手順を運用文書に残す |
| NFR-SEC-3 | BLE はボンディング必須。ボンド済み端末がある場合、新規ペアリングは電源投入後 60 秒に限る |
| NFR-SEC-4 | ファームウェア更新は USB-C 経由のみ（OTA は初版で非対応） |

### 8.6 コスト

| 項目 | 値 | 区分 |
|---|---|---|
| 単価（100 万トークンあたり、入力／出力／キャッシュ読み取り） | Opus 5.5: $4 / $20 / $0.20。Sonnet 5.5: $2 / $10 / $0.20。Haiku 5.5: $0.10 / $0.50 / $0.01（プロンプト 100K トークン以下） | 公式（2026-10-06 時点） |
| 1 ターンの想定 | 固定部 約 3,000 トークン（ほぼキャッシュ読み取り）、入力 約 100、出力 約 80 | 推定 |
| Opus 5.5 の 1 ターン | 約 $0.003 | 推定 |
| 月額の目安（1 家庭） | 1 日 50 ターンで約 $4、300 ターンで約 $25 | 推定 |

要件: ① instructions の前方を不変に保ちキャッシュを効かせる（FR-MEM-4）。② 1 日のターン上限（既定 300、設定可）を超えたら端末内モデルに切り替える。③ Claude Console のワークスペースに月間の支出上限を設定する（運用）。④ 設定画面に当月の概算を表示する。

### 8.7 アクセシビリティ

既存水準（VoiceOver、Dynamic Type、Reduce Motion、Reduce Transparency、文字入力代替）を維持する。首の動きは Reduce Motion の対象外だが、「動きの強さ: 控えめ」で抑えられることを説明する。

### 8.8 保守性とテスト容易性

| ID | 要件 |
|---|---|
| NFR-MAINT-1 | 会話エンジン・ロボット接続・カメラはプロトコル境界で分離し、Simulator ではフェイクで動く（既存の `ConversationDependencies` 方式を踏襲） |
| NFR-MAINT-2 | ファームウェアはシリアル経由で同じコマンドを受け付け、BLE なしで単体試験できる |
| NFR-MAINT-3 | Xcode プロジェクトは `scripts/generate_project.rb` で生成し、手編集しない（既存運用） |
| NFR-MAINT-4 | 依存パッケージは版を固定する（ClaudeForFoundationModels 0.2.x、ONNX Runtime、BLE ラッパーを使う場合は AsyncBluetooth 6.x） |

---

## 9. データ

| データ | 保存場所 | 保持 | 削除 |
|---|---|---|---|
| 会話要約 | `ConversationMemory/current.json`（既存） | セッションをまたいで保持 | 「会話を忘れる」 |
| 長期メモ | `ConversationMemory/facts.json`（新設） | 上限まで保持、超過時は統合 | 個別削除／「会話を忘れる」 |
| 設定 | `UserDefaults` | 永続 | アプリ削除 |
| ロボット接続情報 | `UserDefaults`（ペリフェラル識別子） | 永続 | 接続先の変更 |
| キャリブレーション | ロボット側 NVS | 永続 | キャリブレーション画面 |
| 診断ログ | OSLog（本文を含まない） | OS 既定 | OS 既定 |
| 音声・画像 | 保存しない | — | — |

---

## 10. 受入基準と検証計画

### 10.1 実機試験（配布前に必須）

| ID | 試験 | 合格条件 |
|---|---|---|
| T-DEV-1 | **Apple Intelligence 非対応の iPhone**（iOS 27）で Claude 経由の会話 | 会話が成立する。Apple のラボ回答（§13）どおりに動くことを 1 台で確認する。失敗した場合は配布先の端末要件を「Apple Intelligence 対応機」に変更する |
| T-DEV-2 | 同端末で宛先判定が Claude 代替経路で動く | 曖昧発話の聞き返しが出る |
| T-AUTH-1 | TestFlight ビルドで App Attest 認証 | 鍵なしで会話できる。Console に利用量が記録される |
| T-AUTH-2 | 統合を一時的に取り消したときの挙動 | 原因別の案内が出る（取り消しは恒久のため、検証用の別統合で行う） |
| T-LAT-1 | 遅延計測 50 ターン | NFR-PERF-1/2 を満たす |
| T-MOV-1 | ツール由来の 7 動作 × 3 強度 | 期待どおりの振幅・方向。リミットに当たらない |
| T-MOV-2 | 顔追尾 | 左右 ±40° に動く人物を追う。見失い後 10 秒で正面に戻る |
| T-MOV-3 | 調停 | 追尾中にツール動作が割り込み、終了後に追尾が再開する |
| T-LINK-1 | BLE 切断（距離・アプリ終了） | 切断検出から 5 秒以内に脱力（復帰 2 秒 + 待機 2 秒）。再接続 5 秒以内。電源断はファームウェアが能動復帰できないため対象外 |
| T-LINK-2 | キャリブレーション | オフセット保存後、電源を入れ直しても中立が維持される |
| T-CAM-1 | **前面カメラの露出（実機）** | 組み立てた頭部で、カメラ映像の四隅に外装が映り込まない（CAD 上は ±50° まで非干渉） |
| T-RUN-1 | 24 時間連続稼働 | NFR-REL-1 |
| T-RUN-2 | 熱 | NFR-THERM-1 |
| T-H1 | サーボ保持電流と温度（ピッチ ±30° の端で 10 分保持） | ケース温度 55 ℃以下、5 V レールの電圧降下 0.3 V 以下 |
| T-H2 | 50 回の往復（ヨー ±60°、ピッチ ±30°）後の緩み | ネジ・ホーンの緩みなし |
| T-H3 | 推定質量の確認 | 頭部可動部を実測し、§4.2 の推定（523 g）との差が ±15% 以内。超える場合は速度上限を見直す |
| T-PRIV-1 | ファイル列挙 | 音声・画像ファイルが存在しない |
| T-COST-1 | 1 日の上限 | 上限超過で端末内モデルに切り替わる |

### 10.2 自動テスト

- 既存のドメイン層テスト（宛先判定、発話区切り、文単位再生）は維持する。
- 新規: 動作調停の状態機械、BLE コマンドのエンコード／デコード、ツール引数の検証、記憶の注入文がバイト単位で安定していること、モデル切替がセッション境界でのみ反映されること。
- ファームウェア: シリアル経由のコマンド試験（NFR-MAINT-2）とリミット飽和の単体試験。

---

## 11. リスクと対策

| ID | リスク | 影響 | 対策 |
|---|---|---|---|
| R1 | Apple Intelligence 非対応端末でサーバ側モデル経由の `LanguageModelSession` が動かない | 配布先の端末要件が厳しくなる | Apple のラボ回答では動くとされる（§13）。T-DEV-1 で先に確認し、結果を README の動作要件に反映 |
| R2 | ClaudeForFoundationModels が 0.x で API 変更 | ビルド破損 | 版を固定。更新は変更履歴を読んでから。会話エンジンはプロトコル境界で隔離 |
| R3 | 配布先の iPhone が iOS 27 未満 | 利用不可 | 事前に端末と OS を確認してから配布 |
| R4 | 共用 5 V レールでのブラウンアウト | XIAO 再起動、首の脱力 | FW-PWR-1〜4、T-H1 で観測 |
| R5 | 首の動きが発話とずれて不自然 | 体験の質 | ツール呼び出しを読み上げ開始に同期（FR-MOV-5）。受入レビューで調整 |
| R6 | 利用料の想定超過 | 作者の負担 | §8.6 の上限と Console の支出上限 |
| R7 | カメラ常時動作による発熱 | 熱で機能停止 | 低解像度・5 fps、thermalState 連動（FR-RUN-5） |
| R8 | BLE の混信・距離 | 首が動かない | 会話は継続（FR-LINK-6）。ロボットと iPhone は同一筐体なので距離問題は小さい |
| R9 | 端末内モデルの品質差 | オフライン時の返答が単調 | 「いつものように話せない」と告げる（FR-LLM-4）。短い返答に限定 |

---

## 12. 未決事項

本書の承認時点で残る未決は次の 4 点のみ。いずれも実装着手を妨げない。

| # | 事項 | 決め方 |
|---|---|---|
| O1 | 顔の最終デザイン（形状・配色） | FR-FACE-8 の指針でモックを作り、実機の黒外装に載せてレビュー |
| O2 | 既存配線のピン番号 | 解決済み（2026-10-23）: ヨー D1（GPIO3）、ピッチ D3（GPIO5）。§7.2 に反映 |
| O3 | 自動おやすみの既定時刻 | 初版は未設定（手動のみ）。利用してから決める |
| O4 | ヒューズ F1〜F3 の定格と 5 V レールの実配線 | 配線図 E17（2026-10-23）: F1 4 A（19 V 入力）、F3 1 A（XIAO 5 V、1N4007 経由）。F2 は E17 に無く、470 µF も描かれていない（実物は未確認） |

---

## 13. 参考資料（一次情報）

| 資料 | 用途 |
|---|---|
| Fusion 360「Cat robot rebuild v302」ライブ実測（2026-10-11、`~/workspace/Fusion/tools/fmcp.py` 経由） | §4 の全数値 |
| Anthropic「Apple Foundation Models」 https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models | パッケージ要件、App Attest、ツール、制限 |
| anthropics/ClaudeForFoundationModels https://github.com/anthropics/ClaudeForFoundationModels （0.2.3、2026-10-07） | 初期化引数、`AuthMode`、モデル定数、フォールバック |
| Apple「LanguageModel」「LanguageModelSession」「Tool」「LanguageModelExecutor」Foundation Models ドキュメント | iOS 27 の提供状況、ツールの契約 |
| Apple WWDC26 ラボ「Machine Learning & AI Group Lab」 https://developer.apple.com/videos/play/wwdc2026/8016/ | 「Apple Intelligence 非対応端末でも、LanguageModel プロトコル経由ならフレームワークを使える」旨の発言（R1 の根拠） |
| Apple WWDC26 セッション 339「Bring an LLM provider to the Foundation Models framework」 | 第三者プロバイダの位置づけ、App Attest の推奨 |
| Apple「Adding server-side intelligence with Private Cloud Compute」 | PCC は Apple Intelligence 対応機限定（本書は PCC を使わない） |
| livekit/agents README https://github.com/livekit/agents | サーバ上で動く Python/Node フレームワークであること（D3 の根拠） |
| DS3218 公称仕様（販売者掲載値。製造者の一次資料は 2026-10-11 時点で入手できず） | サーボ定格（ストール電流は未掲載） |
| Seeed「XIAO ESP32C3 Bluetooth Usage」 https://wiki.seeedstudio.com/XIAO_ESP32C3_Bluetooth_Usage/ | BLE 対応と Arduino 例 |
| ESP32Servo（Arduino Library、3.2.0） | LEDC によるサーボ駆動 |
| manolofdez/AsyncBluetooth（最新 6.2.2） | iOS 側 BLE ラッパー候補 |
| Anthropic 料金表（claude-api スキル、2026-10-06 時点） | §8.6 |

---

## 付録 A. ツール定義（案）

```swift
// move_head
struct MoveHeadTool: Tool {
    let name = "move_head"
    let description = "猫の首を動かす。頷く(nod)・横に振る(shake)・かしげる(tilt)・見上げる(look_up)・うつむく(look_down)・相手を見る(look_at_user)・正面(center)。返答の感情や相づちに合わせて使う。"
    @Generable struct Arguments {
        @Guide(description: "nod, shake, tilt, look_up, look_down, look_at_user, center のいずれか") var gesture: String
        @Guide(description: "small, medium, large") var intensity: String
        @Guide(description: "繰り返し回数", .range(1...3)) var repeats: Int
    }
    func call(arguments: Arguments) async throws -> String
}

// express
struct ExpressTool: Tool {
    let name = "express"
    let description = "画面の表情を変える。neutral, happy, curious, thinking, listening, speaking, sleepy, surprised, sorry。"
    @Generable struct Arguments {
        var expression: String
        @Guide(description: "表情を保つ秒数", .range(1...10)) var holdSeconds: Int
    }
    func call(arguments: Arguments) async throws -> String
}

// look
struct LookTool: Tool {
    let name = "look"
    let description = "今カメラに映っているものを見る。利用者が『これ何』『見て』などと言ったとき、または状況を見る必要があるときだけ使う。"
    @Generable struct Arguments { @Guide(description: "何を見たいかの短いメモ") var purpose: String }
    // Output は「短い説明文＋画像添付」を含む PromptRepresentable。
    // パッケージはツール結果の添付画像を image ブロックとして送る（FR-VIS-2）。
    // 添付の具体型は iOS 27 SDK の Transcript.Segment.attachment に対応するものを使う。
    func call(arguments: Arguments) async throws -> Output
}

// remember
struct RememberTool: Tool {
    let name = "remember"
    let description = "利用者について今後も覚えておくべき事実を保存する。名前、好み、出来事、約束。"
    @Generable struct Arguments {
        @Guide(description: "60 文字以内の事実") var fact: String
        @Guide(description: "person, preference, event, promise, other") var category: String
    }
    func call(arguments: Arguments) async throws -> String
}
```

`Tool` の `Output` は `look` 以外は文字列とし、Claude が結果を踏まえて返答を続けられるようにする。引数の列挙は `@Guide` の説明で制約し、不正値はツール側で既定値に丸める。

## 付録 B. 動作プリセット（アプリ側の定義値）

| gesture | small | medium | large | 波形 |
|---|---|---|---|---|
| nod | ピッチ ±5° | ±10° | ±15° | 下→上→中立。時間はファームウェアの上限で決まる（ホスト試験の実測、既定上限・speed 100: small 0.84 秒、medium 1.06 秒、large 1.28 秒） |
| shake | ヨー ±8° | ±15° | ±25° | 左→右→中立。時間は上限で決まる（同実測: small 0.92 秒、medium 1.18 秒、large 1.46 秒） |
| tilt | ヨー 8° ＋ ピッチ −4° | 12° ＋ −6° | 15° ＋ −8° | 片側へ寄せて 1.5 秒保持（同実測、往復込み: large 2.22 秒） |
| look_up | ピッチ +8° | +14° | +20° | 上限の速さで移動、2 秒保持（同実測、往復込み: small 2.60 秒、large 2.84 秒） |
| look_down | ピッチ −8° | −14° | −20° | 同上 |
| look_at_user | 追尾対象へ | 同左 | 同左 | 追尾と同じ速度 |
| center | 中立へ | 同左 | 同左 | 1 秒 |

すべて FR-MOV-12 の範囲内。GESTURE コマンドのファームウェア内蔵動作も同じ振幅に従う（2026-10-23 に実装に合わせて時間を改訂）。

## 付録 C. 既存コードの流用マップ

| 既存ファイル／領域 | 扱い |
|---|---|
| `Conversation/Domain/*`（`AddresseePolicy`、`EngagementWindow`、`UtteranceSegmenter`、`ReplySentence*`、`SentenceSpeechSpeaking`） | 流用 |
| `Conversation/Services/AppleSpeechRecognizer.swift`、`SpeechAudioConverter.swift`、`SpeechAssetPreparer.swift`、`AppleAudioSessionController.swift` | 流用 |
| `Conversation/Services/Supertonic/*`、`Speech/*` | 流用 |
| `Conversation/Services/FoundationModelAddressClassifier.swift`、`FoundationModelAvailabilityService.swift`、`FoundationModelErrorMapper.swift` | 流用（端末内モデル経路） |
| `Conversation/Services/FoundationModelReplyService.swift` | `ClaudeLanguageModel` を受け取れるよう一般化し、端末内モデルとの切替に使う |
| `Conversation/Services/Gemma/*`、LiteRT-LM 依存 | 撤去 |
| `Conversation/Services/Memory/*` | 保存先・ファイル保護の仕組みは流用し、Gemma 固有の互換 ID を外す |
| `Conversation/Integration/ConversationViewModel.swift`、`ConversationDependencies.swift` | 動き・視覚・接続の依存を追加して拡張 |
| `Conversation/UI/CatFaceView.swift`、`CatFaceShapes.swift` | 置換（新デザイン） |
| `Conversation/UI/OnboardingView.swift` | 置換（権限追加、App Attest、ロボット接続） |
| `App/VoiceSettingsView.swift` | 設定画面へ統合 |
| `scripts/generate_project.rb` | パッケージ依存（ClaudeForFoundationModels 追加、LiteRT-LM 削除）、App Attest capability、カメラ・Bluetooth の usage description を追加 |
