import SwiftUI
import XCTest
@testable import CatRobot

/// scripts/face-render の `check` と同じ判定。値は CatFaceGeometry が描画に使うパスから取る。
final class CatFaceGeometryTests: XCTestCase {
    /// 片目・片側だけを変える表情。ほかは左右対称（ハイライトは光源が一つなので除く）。
    private let asymmetricExpressions: Set<FaceExpression> = [.curious, .thinking]

    func testCanvasIsSixteenByNine() {
        XCTAssertEqual(CatFaceGeometry.aspectRatio, 16.0 / 9.0, accuracy: 0.0001)
    }

    func testEveryPresetFitsNormalizedCanvas() {
        for expression in FaceExpression.allCases {
            for pose in CatFaceGeometry.mouthPoses {
                let points = CatFaceGeometry.drawingPoints(for: .preset(expression), mouthPose: pose)
                XCTAssertFalse(points.isEmpty)
                for point in points {
                    XCTAssertTrue((0...1).contains(point.x) && (0...1).contains(point.y),
                                  "\(expression) \(pose): \(point) is outside the canvas")
                }
            }
        }
    }

    func testMouthOpeningIncreasesAcrossSpeakingPoses() {
        let openings = CatFaceGeometry.mouthPoses.map(CatFaceGeometry.mouthOpening(for:))
        XCTAssertEqual(CatFaceGeometry.mouthPoses, [.closed, .small, .medium, .wide])
        XCTAssertEqual(openings.first, 0)
        for (smaller, larger) in zip(openings, openings.dropFirst()) {
            XCTAssertLessThan(smaller, larger)
        }

        for expression in FaceExpression.allCases {
            let appearance = CatFaceAppearance.preset(expression)
            let bottoms = CatFaceGeometry.mouthPoses.map {
                CatFaceGeometry.mouthBounds(for: appearance, mouthPose: $0).maxY
            }
            for index in bottoms.indices.dropFirst() {
                XCTAssertLessThan(bottoms[index - 1], bottoms[index], "\(expression): \(bottoms)")
            }
        }
    }

    func testSymmetricPresetsMirrorLeftAndRight() {
        for expression in FaceExpression.allCases where !asymmetricExpressions.contains(expression) {
            XCTAssertEqual(CatFaceGeometry.unmirroredShapeNames(for: .preset(expression)), [], "\(expression)")
        }
        // 片側だけを変える表情は、検査が非対称を検出できることの確認にもなる。
        for expression in asymmetricExpressions {
            XCTAssertFalse(CatFaceGeometry.unmirroredShapeNames(for: .preset(expression)).isEmpty, "\(expression)")
        }
    }

    func testHappyEnlargesEyesAboutEighteenPercent() {
        let neutral = CatFaceAppearance.preset(.neutral)
        let happy = CatFaceAppearance.preset(.happy)
        for side in CatFaceSide.allCases {
            let ratio = CatFaceGeometry.eyeSize(for: happy, side: side) / CatFaceGeometry.eyeSize(for: neutral, side: side)
            XCTAssertEqual(ratio, 1.18, accuracy: 0.05, "\(side)")
            // 目は開いたまま（細めた目・三日月目にしない）で、瞳も大きくする。
            XCTAssertEqual(happy.eye(side).lid, 0)
            XCTAssertGreaterThan(happy.eye(side).pupilRadii.width * happy.eye(side).widthScale,
                                 neutral.eye(side).pupilRadii.width * neutral.eye(side).widthScale)
            XCTAssertGreaterThan(happy.eye(side).pupilRadii.height * happy.eye(side).heightScale,
                                 neutral.eye(side).pupilRadii.height * neutral.eye(side).heightScale)
        }
    }

    /// sleeping は両目を完全に閉じる: まぶたが外形を全部覆い、その上に金色の弧が目と同じ横幅で目の下半分に乗る。
    /// 弧の縦の厚さは下書き sleeping-draft.png の実測（キャンバス高さ単位）: 中央 0.031、幅の 5% の位置 0.014、先端は尖って 0。
    func testSleepingClosesEyesUnderGoldLidArc() {
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let sleeping = CatFaceAppearance.preset(.sleeping)
        for side in CatFaceSide.allCases {
            let eye = CatFaceGeometry.eye(side: side, appearance: sleeping)
            XCTAssertEqual(sleeping.eye(side).closed, 1, "\(side)")
            XCTAssertTrue(eye.outline.path(in: rect).cgPath.subtracting(eye.lid.path(in: rect).cgPath).isEmpty,
                          "\(side): lid does not cover the eye")
            let arc = eye.closedLid.bounds
            let frame = eye.outline.bounds
            XCTAssertEqual(arc.width, frame.width, accuracy: frame.width * 0.05, "\(side): arc span")
            XCTAssertGreaterThanOrEqual(arc.minY, frame.midY - 0.001, "\(side): arc starts above the eye center")
            XCTAssertLessThanOrEqual(arc.maxY, frame.maxY, "\(side): arc goes below the eye")
            let path = eye.closedLid.path(in: rect).cgPath
            for (fraction, expected) in [(0.5, 0.031), (0.05, 0.014), (0.95, 0.014)] {
                XCTAssertEqual(closedLidThickness(path, atFraction: fraction, in: rect), expected, accuracy: 0.003,
                               "\(side): arc thickness at \(fraction)")
            }
            for fraction in [0.0, 1.0] {
                XCTAssertLessThanOrEqual(closedLidThickness(path, atFraction: fraction, in: rect), 0.004,
                                         "\(side): arc tip at \(fraction) is not pointed")
            }
        }
    }

    /// sleeping の鼻・口・ひげは sleepy と同じ形（鼻は定数、口とひげの全パスが一致する）。
    func testSleepingSharesSleepyNoseMouthAndWhiskers() {
        let sleeping = CatFaceAppearance.preset(.sleeping)
        let sleepy = CatFaceAppearance.preset(.sleepy)
        for side in CatFaceSide.allCases {
            XCTAssertEqual(CatFaceGeometry.whiskers(side: side, appearance: sleeping).map(\.points),
                           CatFaceGeometry.whiskers(side: side, appearance: sleepy).map(\.points), "\(side) whiskers")
        }
        for pose in CatFaceGeometry.mouthPoses {
            let opening = CatFaceGeometry.mouthOpening(for: pose)
            let a = CatFaceGeometry.mouth(appearance: sleeping, opening: opening)
            let b = CatFaceGeometry.mouth(appearance: sleepy, opening: opening)
            XCTAssertEqual(([a.neck] + a.lines + [a.lowerLip, a.cavity, a.round]).map(\.points),
                           ([b.neck] + b.lines + [b.lowerLip, b.cavity, b.round]).map(\.points), "mouth \(pose)")
            XCTAssertEqual(a.roundness, b.roundness, "mouth \(pose)")
        }
    }

    /// sleeping 以外の表情は目を閉じない（閉じた目の弧は sleeping だけが見せる）。
    func testOnlySleepingClosesTheEyes() {
        for expression in FaceExpression.allCases where expression != .sleeping {
            for side in CatFaceSide.allCases {
                XCTAssertEqual(CatFaceAppearance.preset(expression).eye(side).closed, 0, "\(expression) \(side)")
            }
        }
    }

    /// 眠りの Z は sleeping だけが見せる。3 つは小 → 大で右上がりに並び、画面の右半分で閉じた目の弧より上にある
    /// （参照 docs/design/sleeping-zzz-2026-10-28/sleeping-zzz-reference.png）。
    func testOnlySleepingShowsSleepMarksAboveTheClosedEyes() {
        for expression in FaceExpression.allCases {
            XCTAssertEqual(CatFaceAppearance.preset(expression).sleepMarks, expression == .sleeping ? 1 : 0, "\(expression)")
        }
        let sleeping = CatFaceAppearance.preset(.sleeping)
        let marks = CatFaceGeometry.sleepMarks().map(\.bounds)
        XCTAssertEqual(marks.count, 3)
        for (smaller, larger) in zip(marks, marks.dropFirst()) {
            XCTAssertLessThan(smaller.maxX, larger.minX, "Zs overlap horizontally")
            XCTAssertLessThan(larger.minY, smaller.minY, "Zs do not rise to the right")
            XCTAssertLessThan(smaller.height, larger.height, "Zs do not grow to the right")
        }
        let arcTop = CatFaceSide.allCases.map { CatFaceGeometry.eye(side: $0, appearance: sleeping).closedLid.bounds.minY }.min()!
        for mark in marks {
            XCTAssertGreaterThan(mark.minX, 0.5, "\(mark) is not on the right half")
            XCTAssertLessThan(mark.maxY, arcTop, "\(mark) is not above the closed eyes")
        }
    }

    /// 瞳の上に目の高さの 3% 以上の虹彩が残り（瞳を 3% 上へずらしても外形の内側）、大きな白丸が目の外形の内側にあって
    /// まぶたにかからないこと。scripts/face-render の check と同じ判定（CoreGraphics の集合演算、1600×900）。
    /// 完全に閉じた目（sleeping）は瞳と白丸が見えなくてよく、代わりにまぶたが外形を全部覆うことを確かめる。
    func testPupilsAndHighlightsStayVisible() {
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        for expression in FaceExpression.allCases {
            let appearance = CatFaceAppearance.preset(expression)
            for side in CatFaceSide.allCases {
                let eye = CatFaceGeometry.eye(side: side, appearance: appearance)
                let outline = eye.outline.path(in: rect).cgPath
                if appearance.eye(side).closed >= 1 {
                    XCTAssertTrue(outline.subtracting(eye.lid.path(in: rect).cgPath).isEmpty,
                                  "\(expression) \(side): lid does not cover the closed eye")
                    continue
                }
                let margin = outline.boundingBoxOfPath.height * 0.03
                let raisedPupil = eye.pupil.path(in: rect).offsetBy(dx: 0, dy: -margin).cgPath
                XCTAssertTrue(raisedPupil.subtracting(outline).isEmpty,
                              "\(expression) \(side): pupil leaves less than 3% of the eye height of iris above it")
                let highlight = eye.highlight.path(in: rect).cgPath
                XCTAssertTrue(highlight.subtracting(outline).isEmpty, "\(expression) \(side): highlight is not inside the eye")
                if appearance.eye(side).lid > 0 {
                    XCTAssertTrue(highlight.intersection(eye.lid.path(in: rect).cgPath).isEmpty,
                                  "\(expression) \(side): highlight is under the lid")
                }
            }
        }
    }

    /// 描画と同じ塗り・線幅のパス同士で、意図しない交差がないこと（通常とコントラスト強調の線幅の両方）。
    /// 判定は CoreGraphics の集合演算（SwiftUI の `Path.intersection(_:).isEmpty` は空でも false を返し、
    /// 引数の順で結果が変わったため。macOS 26 で確認）。
    func testFeaturesDoNotIntersect() {
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        for expression in FaceExpression.allCases {
            for pose in CatFaceGeometry.mouthPoses {
                for lineScale in [1.0, 1.35] {
                    let parts = CatFaceGeometry.featurePaths(for: .preset(expression), mouthPose: pose,
                                                             lineScale: lineScale, in: rect)
                    for (index, first) in parts.enumerated() {
                        for second in parts.dropFirst(index + 1) where mustStaySeparate(first.kind, second.kind) {
                            XCTAssertTrue(first.path.cgPath.intersection(second.path.cgPath).isEmpty,
                                          "\(expression) \(pose) x\(lineScale): \(first.name) intersects \(second.name)")
                        }
                    }
                }
            }
        }
    }

    /// 閉じた目の弧の縦の厚さ（キャンバス高さ単位）。fraction は弧の幅に対する x の位置（0 = 外側の先端、1 = 鼻側の先端）。
    /// scripts/face-render の check と同じ計り方。
    private func closedLidThickness(_ path: CGPath, atFraction fraction: CGFloat, in rect: CGRect) -> CGFloat {
        let bounds = path.boundingBoxOfPath
        let x = bounds.minX + bounds.width * fraction
        let step = rect.height / 4000
        var inside = 0
        var y = bounds.minY
        while y <= bounds.maxY {
            if path.contains(CGPoint(x: x, y: y)) { inside += 1 }
            y += step
        }
        return CGFloat(inside) * step / rect.height
    }

    /// 鼻と ω の縦線は採用画像どおりつながるので除き、口の部品同士も除く。
    private func mustStaySeparate(_ first: CatFaceGeometry.FeatureKind, _ second: CatFaceGeometry.FeatureKind) -> Bool {
        switch (first, second) {
        case (.nose, .mouthLine), (.mouthLine, .nose),
             (.mouthLine, .mouthLine), (.mouthLine, .mouthOpening),
             (.mouthOpening, .mouthLine), (.mouthOpening, .mouthOpening):
            false
        default:
            true
        }
    }
}
