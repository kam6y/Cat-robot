import CoreGraphics
import Foundation
import SwiftUI

/// CatRobotTests/Conversation/UI/CatFaceGeometryTests.swift と同じ判定を、同じ製品ヘルパーで行う。
enum GeometryCheck {
    static let asymmetricExpressions: Set<FaceExpression> = [.curious, .thinking]

    /// 失敗の説明を返す（空なら合格）。
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { failures.append(message()) }
        }

        // testCanvasIsSixteenByNine
        expect(abs(CatFaceGeometry.aspectRatio - 16.0 / 9.0) < 0.0001, "canvas is not 16:9")

        // testEveryPresetFitsNormalizedCanvas
        for expression in FaceExpression.allCases {
            for pose in CatFaceGeometry.mouthPoses {
                let points = CatFaceGeometry.drawingPoints(for: .preset(expression), mouthPose: pose)
                expect(!points.isEmpty, "\(expression) \(pose): no drawing points")
                for point in points where !((0...1).contains(point.x) && (0...1).contains(point.y)) {
                    failures.append("\(expression) \(pose): \(point) is outside the canvas")
                }
            }
        }

        // testMouthOpeningIncreasesAcrossSpeakingPoses
        let openings = CatFaceGeometry.mouthPoses.map(CatFaceGeometry.mouthOpening(for:))
        expect(CatFaceGeometry.mouthPoses == [.closed, .small, .medium, .wide], "mouth poses are not closed...wide")
        expect(openings.first == 0, "closed mouth is open")
        for (smaller, larger) in zip(openings, openings.dropFirst()) {
            expect(smaller < larger, "mouth opening does not increase: \(openings)")
        }
        for expression in FaceExpression.allCases {
            let appearance = CatFaceAppearance.preset(expression)
            let bottoms = CatFaceGeometry.mouthPoses.map {
                CatFaceGeometry.mouthBounds(for: appearance, mouthPose: $0).maxY
            }
            for index in bottoms.indices.dropFirst() {
                expect(bottoms[index - 1] < bottoms[index], "\(expression): mouth bottom does not move down \(bottoms)")
            }
        }

        // testSymmetricPresetsMirrorLeftAndRight
        for expression in FaceExpression.allCases where !asymmetricExpressions.contains(expression) {
            let names = CatFaceGeometry.unmirroredShapeNames(for: .preset(expression))
            expect(names.isEmpty, "\(expression): not mirrored: \(names)")
        }
        for expression in asymmetricExpressions {
            expect(!CatFaceGeometry.unmirroredShapeNames(for: .preset(expression)).isEmpty,
                   "\(expression): expected an asymmetric shape")
        }

        // testHappyEnlargesEyesAboutEighteenPercent
        let neutral = CatFaceAppearance.preset(.neutral)
        let happy = CatFaceAppearance.preset(.happy)
        for side in CatFaceSide.allCases {
            let ratio = CatFaceGeometry.eyeSize(for: happy, side: side) / CatFaceGeometry.eyeSize(for: neutral, side: side)
            expect(abs(ratio - 1.18) <= 0.05, "happy \(side) eye ratio \(ratio) is not about 1.18")
            expect(happy.eye(side).lid == 0, "happy \(side) eye is not fully open")
            expect(happy.eye(side).pupilRadii.width * happy.eye(side).widthScale
                   > neutral.eye(side).pupilRadii.width * neutral.eye(side).widthScale, "happy \(side) pupil is not wider")
            expect(happy.eye(side).pupilRadii.height * happy.eye(side).heightScale
                   > neutral.eye(side).pupilRadii.height * neutral.eye(side).heightScale, "happy \(side) pupil is not taller")
        }

        // testSleepingClosesEyesUnderGoldLidArc
        let sleeping = CatFaceAppearance.preset(.sleeping)
        let arcRect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        for side in CatFaceSide.allCases {
            let eye = CatFaceGeometry.eye(side: side, appearance: sleeping)
            expect(sleeping.eye(side).closed == 1, "sleeping \(side): eye is not closed")
            expect(eye.outline.path(in: arcRect).cgPath.subtracting(eye.lid.path(in: arcRect).cgPath).isEmpty,
                   "sleeping \(side): lid does not cover the eye")
            let arc = eye.closedLid.bounds
            let frame = eye.outline.bounds
            expect(abs(arc.width - frame.width) <= frame.width * 0.05,
                   "sleeping \(side): arc span \(arc.width) differs from the eye span \(frame.width)")
            expect(arc.minY >= frame.midY - 0.001 && arc.maxY <= frame.maxY,
                   "sleeping \(side): arc \(arc) is not in the lower half of the eye \(frame)")
            // 下書きの弧の縦の厚さ（キャンバス高さ単位）: 中央 0.031、幅の 5% の位置 0.014、先端 0。
            let path = eye.closedLid.path(in: arcRect).cgPath
            for (fraction, expected) in [(0.5, 0.031), (0.05, 0.014), (0.95, 0.014)] {
                let thickness = closedLidThickness(path, atFraction: fraction, in: arcRect)
                expect(abs(thickness - expected) <= 0.003,
                       "sleeping \(side): arc thickness at \(fraction) is \(thickness), expected about \(expected)")
            }
            for fraction in [0.0, 1.0] {
                let tip = closedLidThickness(path, atFraction: fraction, in: arcRect)
                expect(tip <= 0.004, "sleeping \(side): arc tip at \(fraction) is not pointed (\(tip))")
            }
        }

        // testSleepingSharesSleepyNoseMouthAndWhiskers
        let sleepy = CatFaceAppearance.preset(.sleepy)
        for side in CatFaceSide.allCases {
            expect(CatFaceGeometry.whiskers(side: side, appearance: sleeping).map(\.points)
                   == CatFaceGeometry.whiskers(side: side, appearance: sleepy).map(\.points),
                   "sleeping \(side) whiskers differ from sleepy")
        }
        for pose in CatFaceGeometry.mouthPoses {
            let opening = CatFaceGeometry.mouthOpening(for: pose)
            let a = CatFaceGeometry.mouth(appearance: sleeping, opening: opening)
            let b = CatFaceGeometry.mouth(appearance: sleepy, opening: opening)
            expect(([a.neck] + a.lines + [a.lowerLip, a.cavity, a.round]).map(\.points)
                   == ([b.neck] + b.lines + [b.lowerLip, b.cavity, b.round]).map(\.points) && a.roundness == b.roundness,
                   "sleeping mouth \(pose) differs from sleepy")
        }

        // testOnlySleepingClosesTheEyes
        for expression in FaceExpression.allCases where expression != .sleeping {
            for side in CatFaceSide.allCases {
                expect(CatFaceAppearance.preset(expression).eye(side).closed == 0, "\(expression) \(side): eye should stay open")
            }
        }

        // testOnlySleepingShowsSleepMarksAboveTheClosedEyes
        for expression in FaceExpression.allCases {
            let expected: CGFloat = expression == .sleeping ? 1 : 0
            expect(CatFaceAppearance.preset(expression).sleepMarks == expected, "\(expression): sleep marks should be \(expected)")
        }
        let marks = CatFaceGeometry.sleepMarks().map(\.bounds)
        expect(marks.count == 3, "sleeping: \(marks.count) Zs, expected 3")
        for (smaller, larger) in zip(marks, marks.dropFirst()) {
            expect(smaller.maxX < larger.minX && larger.minY < smaller.minY && smaller.height < larger.height,
                   "sleeping: Zs \(smaller) and \(larger) do not rise and grow to the right")
        }
        let arcTop = CatFaceSide.allCases.map { CatFaceGeometry.eye(side: $0, appearance: sleeping).closedLid.bounds.minY }.min()!
        for mark in marks {
            expect(mark.minX > 0.5 && mark.maxY < arcTop, "sleeping: Z \(mark) is not on the right above the closed eyes")
        }

        // testPupilsAndHighlightsStayVisible
        for expression in FaceExpression.allCases {
            for problem in visibilityProblems(.preset(expression)) {
                failures.append("\(expression): \(problem)")
            }
        }

        // testFeaturesDoNotIntersect
        // 判定は CoreGraphics の集合演算（SwiftUI の Path.intersection(_:).isEmpty は空でも false を返し、
        // 引数の順で結果が変わったため。macOS 26 で確認）。
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        for expression in FaceExpression.allCases {
            for pose in CatFaceGeometry.mouthPoses {
                for lineScale in [1.0, 1.35] {
                    let parts = CatFaceGeometry.featurePaths(for: .preset(expression), mouthPose: pose,
                                                             lineScale: lineScale, in: rect)
                    for (index, first) in parts.enumerated() {
                        for second in parts.dropFirst(index + 1) where mustStaySeparate(first.kind, second.kind) {
                            expect(first.path.cgPath.intersection(second.path.cgPath).isEmpty,
                                   "\(expression) \(pose) x\(lineScale): \(first.name) intersects \(second.name)")
                        }
                    }
                }
            }
        }
        return failures
    }

    /// 瞳の上に目の高さの 3% 以上の虹彩が残り（瞳を 3% 上へずらしても外形の内側）、大きな白丸が外形の内側で
    /// まぶたにかからないこと。
    static func visibilityProblems(_ appearance: CatFaceAppearance) -> [String] {
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        var problems: [String] = []
        for side in CatFaceSide.allCases {
            let eye = CatFaceGeometry.eye(side: side, appearance: appearance)
            let outline = eye.outline.path(in: rect).cgPath
            if appearance.eye(side).closed >= 1 {
                // 閉じた目（sleeping）は瞳と白丸が見えなくてよい。代わりにまぶたが外形を全部覆うこと。
                if !outline.subtracting(eye.lid.path(in: rect).cgPath).isEmpty {
                    problems.append("\(side) lid does not cover the closed eye")
                }
                continue
            }
            let margin = outline.boundingBoxOfPath.height * 0.03
            let raisedPupil = eye.pupil.path(in: rect).offsetBy(dx: 0, dy: -margin).cgPath
            if !raisedPupil.subtracting(outline).isEmpty {
                // 実際の余裕（目の高さに対する %）を二分法で求めて添える。
                var low: CGFloat = 0
                var high = outline.boundingBoxOfPath.height * 0.2
                for _ in 0..<20 {
                    let middle = (low + high) / 2
                    let moved = eye.pupil.path(in: rect).offsetBy(dx: 0, dy: -middle).cgPath
                    if moved.subtracting(outline).isEmpty { low = middle } else { high = middle }
                }
                let percent = low / outline.boundingBoxOfPath.height * 100
                problems.append("\(side) pupil leaves less than 3% of the eye height of iris above it ("
                                + String(format: "%.2f%%", percent) + ")")
            }
            let highlight = eye.highlight.path(in: rect).cgPath
            if !highlight.subtracting(outline).isEmpty {
                problems.append("\(side) highlight is not inside the eye")
            }
            if appearance.eye(side).lid > 0, !highlight.intersection(eye.lid.path(in: rect).cgPath).isEmpty {
                problems.append("\(side) highlight is under the lid")
            }
        }
        return problems
    }

    /// 閉じた目の弧の縦の厚さ（キャンバス高さ単位）。fraction は弧の幅に対する x の位置（0 = 外側の先端、1 = 鼻側の先端）。
    static func closedLidThickness(_ path: CGPath, atFraction fraction: CGFloat, in rect: CGRect) -> CGFloat {
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
    private static func mustStaySeparate(_ first: CatFaceGeometry.FeatureKind,
                                         _ second: CatFaceGeometry.FeatureKind) -> Bool {
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
