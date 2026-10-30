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
        let rect = arcRect
        let intersecting: [(String, CatFaceAppearance)] = FaceExpression.allCases.map { ("\($0)", .preset($0)) } + [("yawning", .yawning)]
        for (label, appearance) in intersecting {
            for pose in CatFaceGeometry.mouthPoses {
                for lineScale in [1.0, 1.35] {
                    let parts = CatFaceGeometry.featurePaths(for: appearance, mouthPose: pose, lineScale: lineScale, in: rect)
                    for (index, first) in parts.enumerated() {
                        for second in parts.dropFirst(index + 1) where mustStaySeparate(first.kind, second.kind) {
                            expect(first.path.cgPath.intersection(second.path.cgPath).isEmpty,
                                   "\(label) \(pose) x\(lineScale): \(first.name) intersects \(second.name)")
                        }
                    }
                }
            }
        }

        // testPresetsIgnoreYawnAndPerEyeBlink
        for expression in FaceExpression.allCases {
            let appearance = CatFaceAppearance.preset(expression)
            expect(appearance.yawn == 0, "\(expression): yawn should be 0")
            for side in CatFaceSide.allCases {
                expect(appearance.eye(side).blink == 0, "\(expression) \(side): blink should be 0")
            }
            for pose in CatFaceGeometry.mouthPoses {
                let names = CatFaceGeometry.featurePaths(for: appearance, mouthPose: pose, in: rect).map(\.name)
                expect(!names.contains { $0.contains("yawn") }, "\(expression) \(pose): has yawn parts \(names)")
            }
        }

        // testYawningShutsEyesUnderInvertedGoldArc
        let yawning = CatFaceAppearance.yawning
        expect(yawning.yawn == 1, "yawning: yawn is \(yawning.yawn), expected 1")
        expect(CatFaceGeometry.unmirroredShapeNames(for: yawning).isEmpty,
               "yawning: not mirrored \(CatFaceGeometry.unmirroredShapeNames(for: yawning))")
        for point in CatFaceGeometry.drawingPoints(for: yawning, mouthPose: .closed)
        where !((0...1).contains(point.x) && (0...1).contains(point.y)) {
            failures.append("yawning: \(point) is outside the canvas")
        }
        for side in CatFaceSide.allCases {
            let eye = CatFaceGeometry.eye(side: side, appearance: yawning)
            expect(yawning.eye(side).closed == 1 && yawning.eye(side).lid == 1, "yawning \(side): eye is not shut")
            expect(eye.outline.path(in: arcRect).cgPath.subtracting(eye.lid.path(in: arcRect).cgPath).isEmpty,
                   "yawning \(side): lid does not cover the eye")
            let arc = eye.closedLid.bounds
            let frame = eye.outline.bounds
            // 参考の ∩ の弧: 目の中心より上に頂点があり、鼻側の先端だけが中心の少し下まで下がる。横幅は目の横半径の約 1.62 倍。
            expect(arc.minY > frame.minY && arc.maxY < frame.midY + 0.03,
                   "yawning \(side): arc \(arc) is not in the upper middle of the eye \(frame)")
            expect(abs(arc.width - 0.202) <= 0.01, "yawning \(side): arc span \(arc.width), expected about 0.202")
            let path = eye.closedLid.path(in: arcRect).cgPath
            let apex = closedLidThickness(path, atFraction: side == .left ? 0.352 : 0.648, in: arcRect)
            expect(abs(apex - 0.042) <= 0.004, "yawning \(side): arc thickness at the apex is \(apex), expected about 0.042")
            for fraction in [0.0, 1.0] {
                let tip = closedLidThickness(path, atFraction: fraction, in: arcRect)
                expect(tip <= 0.004, "yawning \(side): arc tip at \(fraction) is not pointed (\(tip))")
            }
        }

        // testYawningOpensBigMouthWithTongueAndFangsUnderRaisedNose
        let parts = CatFaceGeometry.featurePaths(for: yawning, mouthPose: .closed, in: rect)
        func normalized(_ bounds: CGRect) -> CGRect {
            CGRect(x: bounds.minX / rect.width, y: bounds.minY / rect.height,
                   width: bounds.width / rect.width, height: bounds.height / rect.height)
        }
        let mouth = CatFaceGeometry.mouthBounds(for: yawning, mouthPose: .closed)
        expect(abs(mouth.height - 0.40) <= 0.02 && abs(mouth.width - 0.249) <= 0.012 && mouth.maxY < 1,
               "yawning: mouth bounds \(mouth), expected about 0.249 x 0.40 inside the canvas")
        let nose = parts.first { $0.kind == .nose }.map { normalized($0.path.boundingRect) } ?? .null
        expect(abs(nose.maxY - 0.5154) <= 0.006 && abs(nose.height - 0.084) <= 0.006,
               "yawning: nose \(nose), expected bottom about 0.5154 and height about 0.084")
        expect(abs(mouth.minY - nose.maxY) <= 0.012, "yawning: mouth top \(mouth.minY) does not meet the nose bottom \(nose.maxY)")
        // 唇の尖りは参考どおり鼻の下端より少し上（0.5112）まで届き、舌・牙・下端は動かない。
        expect(abs(mouth.minY - 0.5112) <= 0.003, "yawning: mouth top \(mouth.minY), expected about 0.5112")
        let tongue = parts.first { $0.name == "yawn tongue" }.map { normalized($0.path.boundingRect) }
        expect(tongue.map { abs($0.minY - 0.7024) <= 0.003 && mouth.insetBy(dx: 0.005, dy: 0.005).contains($0) } ?? false,
               "yawning: tongue \(String(describing: tongue)) is missing or not inside the mouth with its top about 0.7024")
        let fangs = parts.filter { $0.name.hasSuffix("yawn fang") }.map { normalized($0.path.boundingRect) }
        expect(fangs.count == 2, "yawning: \(fangs.count) fangs, expected 2")
        for fang in fangs {
            expect(abs(fang.maxY - 0.628) <= 0.003 && fang.minY > nose.maxY && mouth.contains(fang),
                   "yawning: fang \(fang) is not hanging inside the mouth with its tip about 0.628")
        }
        if fangs.count == 2 {
            expect(abs(fangs[0].minX - (1 - fangs[1].maxX)) <= 0.001 && abs(fangs[0].minY - fangs[1].minY) <= 0.001,
                   "yawning: fangs \(fangs) are not mirrored")
        }

        // testYawningWhiskersMatchTheReference
        // 参考 yawn-reference.png のひげ 3 本の外接（キャンバス単位。端の白っぽい画素も含めて測る。左右は 0.001 以内で
        // 一致するので平均）。右は鏡映。
        let referenceWhiskers = [
            CGRect(x: 0.0437, y: 0.4942, width: 0.2476 - 0.0437, height: 0.5446 - 0.4942),
            CGRect(x: 0.0634, y: 0.5505, width: 0.2647 - 0.0634, height: 0.6530 - 0.5505),
            CGRect(x: 0.1083, y: 0.5946, width: 0.2644 - 0.1083, height: 0.7295 - 0.5946),
        ]
        for side in CatFaceSide.allCases {
            let bounds = CatFaceGeometry.whiskers(side: side, appearance: yawning).map(\.bounds)
            expect(bounds.count == 3, "yawning \(side): \(bounds.count) whiskers, expected 3")
            for (index, (actual, reference)) in zip(bounds, referenceWhiskers).enumerated() {
                let expected = side == .left ? reference
                    : CGRect(x: 1 - reference.maxX, y: reference.minY, width: reference.width, height: reference.height)
                expect(abs(actual.minX - expected.minX) <= 0.005 && abs(actual.maxX - expected.maxX) <= 0.005
                       && abs(actual.minY - expected.minY) <= 0.005 && abs(actual.maxY - expected.maxY) <= 0.005,
                       "yawning \(side) whisker \(index + 1): \(actual) is not at the reference \(expected)")
            }
            expect(CatFaceGeometry.whiskers(side: side, appearance: sleepy).map(\.bounds) != bounds,
                   "yawning \(side): whiskers did not move from sleepy")
        }

        // testYawnGrowsTheMouthFromTheNose
        var heights: [CGFloat] = []
        for amount in [0.0, 0.25, 0.5, 0.75, 1.0] {
            var partial = yawning
            partial.yawn = amount
            heights.append(CatFaceGeometry.mouthBounds(for: partial, mouthPose: .closed).height)
        }
        for (smaller, larger) in zip(heights, heights.dropFirst()) {
            expect(smaller < larger, "yawn: mouth does not grow with yawn \(heights)")
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
