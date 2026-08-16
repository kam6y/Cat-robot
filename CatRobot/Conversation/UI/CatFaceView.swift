import SwiftUI

struct CatFaceView: View {
    let state: CatVisualState
    let mouthPose: MouthPose
    let reduceMotion: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var blinkScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let size = fittedSize(in: proxy.size)
            let outline = max(colorSchemeContrast == .increased ? 3 : 2,
                              size.width * (colorSchemeContrast == .increased ? 0.0032 : 0.0022))

            ZStack {
                CatHeadShape()
                    .fill(Palette.fur)
                    .stroke(Palette.outline, lineWidth: outline)

                ForEach([CatFaceSide.left, .right], id: \.self) { side in
                    CatInnerEarShape(side: side)
                        .fill(Palette.innerEar)
                        .stroke(Palette.outline, lineWidth: outline * 0.70)
                        .offset(y: attentionOffset * size.height)
                }

                ForEach(Array(CatFaceGeometry.foreheadMarks.enumerated()), id: \.offset) { _, mark in
                    CatNormalizedPathShape(definition: mark).fill(Palette.teal)
                }
                ForEach(Array(CatFaceGeometry.browMarks.enumerated()), id: \.offset) { _, mark in
                    CatNormalizedPathShape(definition: mark).fill(Palette.cream)
                }

                ForEach([CatFaceSide.left, .right], id: \.self) { side in
                    eye(side: side, outline: outline, size: size)
                }

                CatMuzzleShape()
                    .fill(Palette.cream)
                    .stroke(Palette.outline, lineWidth: outline * 0.75)

                CatNoseShape()
                    .fill(Palette.nose)
                    .stroke(Palette.outline, lineWidth: outline * 0.85)

                mouth(outline: outline)

                whiskers(outline: outline)
            }
            .frame(width: size.width, height: size.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(CatFaceGeometry.aspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: state)
        .task(id: blinkTaskID) {
            blinkScale = 1
            guard state == .thinking, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.8))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.10)) { blinkScale = 0.08 }
                try? await Task.sleep(for: .seconds(0.13))
                withAnimation(.easeInOut(duration: 0.13)) { blinkScale = 1 }
            }
        }
    }

    private var blinkTaskID: String { "\(state)-\(reduceMotion)" }
    private var attentionOffset: CGFloat { state == .listening && !reduceMotion ? -0.005 : 0 }

    private func fittedSize(in available: CGSize) -> CGSize {
        let candidateHeight = available.width / CatFaceGeometry.aspectRatio
        if candidateHeight <= available.height {
            return CGSize(width: available.width, height: candidateHeight)
        }
        return CGSize(width: available.height * CatFaceGeometry.aspectRatio, height: available.height)
    }

    @ViewBuilder
    private func eye(side: CatFaceSide, outline: CGFloat, size: CGSize) -> some View {
        let center = side.point(CatFaceGeometry.eyeCenter)
        let irisCenter = CGPoint(x: center.x, y: center.y + attentionOffset)

        CatScleraShape(side: side)
            .fill(Palette.cream)
            .stroke(Palette.outline, lineWidth: outline * 0.75)

        Ellipse()
            .fill(Palette.iris)
            .stroke(Palette.outline, lineWidth: outline * 0.65)
            .frame(width: size.width * 0.064, height: size.height * 0.150 * blinkScale)
            .position(x: irisCenter.x * size.width, y: irisCenter.y * size.height)

        Ellipse()
            .fill(Palette.outline)
            .frame(width: size.width * 0.036, height: size.height * 0.120 * blinkScale)
            .position(x: irisCenter.x * size.width, y: irisCenter.y * size.height)

        Ellipse()
            .fill(Palette.cream)
            .frame(width: size.width * 0.011, height: size.height * 0.027 * blinkScale)
            .position(x: (irisCenter.x - 0.009) * size.width, y: (irisCenter.y - 0.030) * size.height)

        CatScleraShape(side: side)
            .fill(Palette.fur)
            .opacity(1 - blinkScale)

        CatLidShape(side: side)
            .stroke(Palette.outline,
                    style: StrokeStyle(lineWidth: outline * 1.45, lineCap: .round, lineJoin: .round))
    }

    @ViewBuilder
    private func mouth(outline: CGFloat) -> some View {
        ZStack {
            ForEach(Array([MouthPose.closed, .small, .medium, .wide].enumerated()), id: \.offset) { _, pose in
                mouthLayer(for: pose, outline: outline)
                    .opacity(pose == mouthPose ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.11 : 0.14), value: mouthPose)
    }

    @ViewBuilder
    private func mouthLayer(for pose: MouthPose, outline: CGFloat) -> some View {
        if pose != .closed {
            CatMouthCavityShape(pose: pose)
                .fill(Palette.outline)

            if pose == .medium || pose == .wide {
                CatTongueShape(pose: pose)
                    .fill(Palette.tongue)

                ForEach(Array(CatFaceGeometry.fangs.enumerated()), id: \.offset) { _, fang in
                    CatNormalizedPathShape(definition: fang).fill(Palette.cream)
                }
            }
        }

        ForEach(Array(CatFaceGeometry.mouthLines.enumerated()), id: \.offset) { _, line in
            CatNormalizedPathShape(definition: line)
                .stroke(Palette.outline,
                        style: StrokeStyle(lineWidth: outline * 0.80, lineCap: .round, lineJoin: .round))
        }
    }

    @ViewBuilder
    private func whiskers(outline: CGFloat) -> some View {
        ForEach(Array(CatFaceGeometry.leftWhiskers.enumerated()), id: \.offset) { _, whisker in
            CatNormalizedPathShape(definition: whisker)
                .stroke(Palette.cream,
                        style: StrokeStyle(lineWidth: outline * 0.65, lineCap: .round, lineJoin: .round))
            CatNormalizedPathShape(definition: whisker.mirrored)
                .stroke(Palette.cream,
                        style: StrokeStyle(lineWidth: outline * 0.65, lineCap: .round, lineJoin: .round))
        }
    }
}

private enum Palette {
    static let fur = Color(red: 0x20 / 255, green: 0x21 / 255, blue: 0x23 / 255)
    static let cream = Color(red: 0xFF / 255, green: 0xF0 / 255, blue: 0xD8 / 255)
    static let iris = Color(red: 0xC7 / 255, green: 0x8A / 255, blue: 0x3D / 255)
    static let teal = Color(red: 0x4F / 255, green: 0xA5 / 255, blue: 0xA3 / 255)
    static let innerEar = Color(red: 0xBE / 255, green: 0x76 / 255, blue: 0x6E / 255)
    static let nose = Color(red: 0xC9 / 255, green: 0x79 / 255, blue: 0x70 / 255)
    static let tongue = Color(red: 0xBE / 255, green: 0x76 / 255, blue: 0x6E / 255)
    static let outline = Color(red: 0x08 / 255, green: 0x08 / 255, blue: 0x09 / 255)
}

#if DEBUG
#Preview("Trace comparison") {
    ZStack {
        Image("CatReference").resizable().scaledToFit().opacity(0.28)
        CatFaceView(state: .speaking, mouthPose: .medium, reduceMotion: true).opacity(0.72)
    }
}
#endif
