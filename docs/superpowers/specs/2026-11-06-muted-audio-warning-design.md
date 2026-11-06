# issue #26: 音量0の警告チップ

[issue #26](https://github.com/kam6y/Cat-robot/issues/26)。main `ce72201dca73c289de95085fa79f67bef7bf4b16` から `codex/issue-26-muted-audio-warning` を作成。

## 要求と範囲

ユーザーの最終指示は再生音量0のみ。いったん「音量0と消音モードの両方」と回答した後、消音モードでも現行アプリは声を再生することを確認し、消音モード対応は不要と訂正した。消音スイッチ、アプリの出力ミュートAPI、マイクのミュートを検出対象へ混ぜない。

実装判断: 会話画面の既存警告チップに `speaker.slash.fill` と「音量が0です」を追加し、再生音量が0の間だけ表示する。音量が正へ戻ると消す。会話状態に関わらず他の警告と併存し、既存の横並び/縦積み、大きい文字、VoiceOverを使う。音量変更では会話・録音・読み上げを停止/再開せず、音量もアプリから変更しない。

## 方法の比較と選択

- 既存のaudio event経路とchip表示を拡張する（採用）。追加dependency/monitorやpollingを増やさず、既存の通知所有・VM寿命を再利用できる。
- 独立したvolume monitorをApp/SwiftUIへ注入する。単独では短いが、第二の状態配信と寿命管理を増やすため今回の小変更には使わない。
- タイマーで音量を調べる方法は遅延と余分な定期処理を生むため使わない。

`AudioSessionControlling.outputVolume` をasync read-only getterとして公開し、変更イベントは値を持たない `outputVolumeChanged` にする。VMはconsumer開始時とイベント受信時に現在値を読み直す。Apple controllerのgetterは非隔離・同期でdriverを直読し、activate中のactor queueに音量の読み取りを並べない。protocolのasync getterはこの同期実装でも満たす。初回は既に0でも検出し、古いcallback値を持ち越さない。Apple側では現在使うsessionの `outputVolume` をKVOで観察する。アクティベーション後にも通知し、非active中や設定/背景からの復帰後の値を取り直す。音量のためだけにaudio sessionをactivateしない。非active中にOSがKVO通知を止める場合、その間の即時更新は保証せず、次のactivate成功後に現在値を反映する。

KVOは既存通知observerと同じ所有者で遅延生成・保持し、同じcontrollerへの複数購読で重複作成しない。observerからはevent hubだけを捕捉し、controller/VMへの循環参照を作らない。shutdown後の読み取り完了は表示を更新しない。既存の割り込み/route changeの動作は維持する。

## 根拠

[outputVolume](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume) は0〜1のユーザー設定値を読み取り、KVOで変化を観察できる。[playAndRecord](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playandrecord) は消音モードでも再生する。Apple公式文書とXcode27.2 SDKヘッダを照合した。実機はiOS27.2、アプリの最低iOS27を維持する。

## 確認

初期0、0から正、正から0、paused/sleeping/typedでの併存、activate後の再読取、複数購読/破棄、読み取り待ちshutdown、他チップとの配置とVoiceOverを確認する。実API・収録・ロボットの専用試験は通常unit suiteへ混ぜない。Codexが単一writer、agmsgのClaudeがペア担当。実装後はClaudeの実際の `/simplify` と独立レビューを並行し、双方の `receiving-code-review` と必要な修正を経て、全体テスト・通常署名実機更新・mainへのスカッシュ統合/pushまで行う。
