#if DEBUG
import SwiftUI

/// 実行は XCTest が担当する。通常の会話・音声・カメラ・ロボット依存を生成しない静的ホスト。
struct HermesProbeHostView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Hermes 接続プローブ").font(.title2)
            Text("文字通信と模擬 echo の検証用です。")
        }
        .padding()
        .accessibilityIdentifier("hermes-probe-host")
    }
}
#endif
