import Foundation

// 猫の顔の macOS レンダーハーネス。リポジトリのルートで scripts/render_face.sh から実行する。
//   face-render measure            採用画像を実測して正規化座標と色を表示
//   face-render measure --rendered 現在の描画を同じ計測にかける（採用画像との数値比較用）
//   face-render measure --sleeping sleeping の下書きと現在の描画を同じ計測にかける（弧の列ごとの縁と太さ、鼻・口・ひげ）
//   face-render check              幾何条件（XCTest と同じ判定）を検査し、失敗なら終了コード 1
//   face-render render --round N [--overwrite]
//                                  docs/design/face-expression-2026-10-26/renders/round-N/ へ画像を出力
//                                  （既にある round には --overwrite なしでは書かない）
//   face-render preview DIR [SCALE] 試し描き。作業用の DIR へ同じ画像を出す（round には書かない。SCALE は画面モックの倍率、既定 2）
//   face-render render-sleeping --round N [--overwrite]
//                                  docs/design/sleeping-2026-10-26/renders/round-N/ へ下書きとの比較画像を出力

let arguments = Array(CommandLine.arguments.dropFirst())
let root = FileManager.default.currentDirectoryPath

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

MainActor.assumeIsolated {
    do {
        switch arguments.first {
        case "measure" where arguments.dropFirst().first == "--sleeping":
            try Measurement.runSleeping(root: root)
        case "measure":
            try Measurement.run(root: root, rendered: arguments.dropFirst().first == "--rendered")
        case "check":
            let failures = GeometryCheck.run()
            if failures.isEmpty {
                print("check: OK (\(FaceExpression.allCases.count) presets x 4 mouth poses: points in 0...1, mouth opening order, mirror symmetry, "
                      + "happy eye size, sleeping closed eyes, gold arc and Zs (sleeping only), pupils and highlights visible, "
                      + "no unintended path intersections at line scale 1 and 1.35)")
            } else {
                failures.forEach { print("check: FAIL \($0)") }
                fail("check: \(failures.count) failure(s)")
            }
        case "preview":
            guard arguments.count >= 2, !arguments[1].contains("/renders/round-") else {
                fail("usage: face-render preview DIR [SCALE] (DIR must not be a round directory)")
            }
            let scale = arguments.count >= 3 ? CGFloat(Double(arguments[2]) ?? 2) : 2
            let written = try FaceRender.preview(directory: arguments[1], root: root, screenScale: scale)
            print("preview: wrote \(written.count) files to \(arguments[1])")
        case "render", "render-sleeping":
            let overwrite = arguments.count == 4 && arguments[3] == "--overwrite"
            guard arguments.count == 3 || overwrite, arguments[1] == "--round",
                  let round = Int(arguments[2]), round > 0 else {
                fail("usage: face-render \(arguments[0]) --round N [--overwrite]")
            }
            if arguments[0] == "render-sleeping" {
                let written = try FaceRender.runSleeping(round: round, root: root, overwrite: overwrite)
                print("render-sleeping: wrote \(written.count) files to \(Measurement.sleepingDirectory)/renders/round-\(round)/")
            } else {
                let written = try FaceRender.run(round: round, root: root, overwrite: overwrite)
                print("render: wrote \(written.count) files to docs/design/face-expression-2026-10-26/renders/round-\(round)/")
            }
        default:
            fail("usage: face-render measure [--rendered | --sleeping] | check | render --round N [--overwrite] "
                 + "| render-sleeping --round N [--overwrite] | preview DIR [SCALE]")
        }
    } catch {
        fail("face-render: \(error)")
    }
}
