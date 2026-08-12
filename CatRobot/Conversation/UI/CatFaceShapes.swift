import SwiftUI

enum CatFaceSide {
    case left
    case right

    func point(_ point: CGPoint) -> CGPoint {
        switch self {
        case .left:
            point
        case .right:
            CGPoint(x: 1 - point.x, y: point.y)
        }
    }
}

enum CatFaceGeometry {
    static let aspectRatio = 1672.0 / 941.0

    static let eyeCenter = CGPoint(x: 0.404, y: 0.515)
    static let muzzleCenter = CGPoint(x: 0.450, y: 0.700)
    static let noseCenter = CGPoint(x: 0.500, y: 0.625)
    static let mouthHinge = CGPoint(x: 0.500, y: 0.688)

    static let head = NormalizedPath.symmetricClosed(leftHalf: [
        .move(0.353, 0.921),
        .curve(0.325, 0.882, 0.318, 0.838, 0.373, 0.799),
        .curve(0.323, 0.777, 0.277, 0.733, 0.253, 0.669),
        .curve(0.237, 0.626, 0.257, 0.601, 0.269, 0.570),
        .curve(0.273, 0.509, 0.278, 0.451, 0.287, 0.398),
        .curve(0.268, 0.313, 0.254, 0.128, 0.273, 0.071),
        .curve(0.301, 0.039, 0.370, 0.165, 0.417, 0.219),
        .curve(0.451, 0.203, 0.480, 0.197, 0.500, 0.197),
    ], lowerControl: CGPoint(x: 0.408, y: 0.956))

    static let leftInnerEar = NormalizedPath([
        .move(0.289, 0.377),
        .curve(0.271, 0.290, 0.259, 0.122, 0.278, 0.102),
        .curve(0.306, 0.073, 0.363, 0.198, 0.367, 0.263),
        .line(0.344, 0.245),
        .line(0.354, 0.279),
        .line(0.328, 0.265),
        .curve(0.314, 0.306, 0.302, 0.348, 0.289, 0.377),
        .close,
    ])

    static let leftSclera = NormalizedPath([
        .move(0.340, 0.497),
        .curve(0.358, 0.451, 0.382, 0.435, 0.409, 0.439),
        .curve(0.434, 0.443, 0.449, 0.486, 0.451, 0.570),
        .curve(0.430, 0.592, 0.399, 0.605, 0.374, 0.589),
        .curve(0.351, 0.574, 0.341, 0.535, 0.340, 0.497),
        .close,
    ])

    static let leftLid = NormalizedPath([
        .move(0.332, 0.488),
        .curve(0.355, 0.454, 0.382, 0.430, 0.411, 0.433),
        .curve(0.434, 0.436, 0.452, 0.461, 0.462, 0.493),
    ])

    static let leftMuzzle = NormalizedPath([
        .move(0.500, 0.615),
        .curve(0.463, 0.587, 0.411, 0.600, 0.394, 0.662),
        .curve(0.377, 0.727, 0.412, 0.793, 0.491, 0.830),
        .curve(0.507, 0.812, 0.502, 0.702, 0.500, 0.615),
        .close,
    ])

    static let nose = NormalizedPath([
        .move(0.500, 0.592),
        .curve(0.532, 0.592, 0.538, 0.611, 0.524, 0.632),
        .curve(0.515, 0.646, 0.505, 0.663, 0.500, 0.663),
        .curve(0.495, 0.663, 0.485, 0.646, 0.476, 0.632),
        .curve(0.462, 0.611, 0.468, 0.592, 0.500, 0.592),
        .close,
    ])

    static let leftWhiskers = [
        NormalizedPath([.move(0.234, 0.628), .curve(0.289, 0.596, 0.347, 0.605, 0.388, 0.638)]),
        NormalizedPath([.move(0.242, 0.702), .curve(0.290, 0.666, 0.344, 0.642, 0.393, 0.657)]),
        NormalizedPath([.move(0.269, 0.766), .curve(0.306, 0.724, 0.355, 0.689, 0.400, 0.684)]),
    ]

    static let centerForeheadMark = NormalizedPath([.move(0.500, 0.255), .curve(0.490, 0.275, 0.492, 0.326, 0.500, 0.371), .curve(0.508, 0.326, 0.510, 0.275, 0.500, 0.255), .close])
    static let leftForeheadMark = NormalizedPath([.move(0.466, 0.304), .curve(0.459, 0.318, 0.469, 0.352, 0.484, 0.378), .curve(0.478, 0.347, 0.475, 0.318, 0.466, 0.304), .close])
    static let foreheadMarks = [centerForeheadMark, leftForeheadMark, leftForeheadMark.mirrored]

    static let leftBrowMark = NormalizedPath([.move(0.378, 0.365), .curve(0.395, 0.346, 0.420, 0.346, 0.433, 0.382), .curve(0.411, 0.367, 0.392, 0.370, 0.378, 0.365), .close])
    static let browMarks = [leftBrowMark, leftBrowMark.mirrored]

    static let mouthStem = NormalizedPath([.move(0.500, 0.663), .line(0.500, 0.688)])
    static let leftSmile = NormalizedPath([.move(0.500, 0.688), .curve(0.490, 0.702, 0.474, 0.706, 0.462, 0.696)])
    static let mouthLines = [mouthStem, leftSmile, leftSmile.mirrored]

    static let leftFang = NormalizedPath([.move(0.475, 0.696), .line(0.484, 0.696), .line(0.480, 0.711), .close])
    static let fangs = [leftFang, leftFang.mirrored]

    static let mirroredFeaturePairs: [(left: CGPoint, right: CGPoint)] = {
        let left = [
            eyeCenter,
            CGPoint(x: 0.273, y: 0.071),
            CGPoint(x: 0.234, y: 0.628), CGPoint(x: 0.388, y: 0.638),
            CGPoint(x: 0.242, y: 0.702), CGPoint(x: 0.393, y: 0.657),
            CGPoint(x: 0.269, y: 0.766), CGPoint(x: 0.400, y: 0.684),
        ]
        return left.map { ($0, CGPoint(x: 1 - $0.x, y: $0.y)) }
    }()

    static let landmarksAndControlPoints: [CGPoint] = {
        let mouthPoses: [MouthPose] = [.small, .medium, .wide]
        let pathPoints = [head, leftInnerEar, leftInnerEar.mirrored, leftSclera, leftSclera.mirrored,
                          leftLid, leftLid.mirrored, leftMuzzle, leftMuzzle.mirrored, nose]
            + leftWhiskers + leftWhiskers.map(\.mirrored) + foreheadMarks + browMarks
            + mouthLines + fangs
            + mouthPoses.map(mouthCavity) + mouthPoses.map(tongue)
        let leftEyeEllipsePoints = [
            CGPoint(x: 0.372, y: 0.515), CGPoint(x: 0.436, y: 0.515),
            CGPoint(x: 0.404, y: 0.440), CGPoint(x: 0.404, y: 0.590),
            CGPoint(x: 0.386, y: 0.515), CGPoint(x: 0.422, y: 0.515),
            CGPoint(x: 0.404, y: 0.455), CGPoint(x: 0.404, y: 0.575),
        ]
        let ellipsePoints = [eyeCenter, muzzleCenter] + leftEyeEllipsePoints
            + ([eyeCenter, muzzleCenter] + leftEyeEllipsePoints).map { CGPoint(x: 1 - $0.x, y: $0.y) }
            + [noseCenter, mouthHinge]
        return pathPoints.flatMap(\.points) + ellipsePoints
    }()

    static func mouthOpening(for pose: MouthPose) -> CGFloat {
        switch pose {
        case .closed: 0
        case .small: 0.018
        case .medium: 0.040
        case .wide: 0.070
        }
    }

    static func mouthCavity(for pose: MouthPose) -> NormalizedPath {
        let opening = mouthOpening(for: pose)
        let halfWidth = 0.025 + opening * 0.52
        let top = mouthHinge.y + 0.004
        let bottom = top + opening
        return NormalizedPath([
            .move(0.5 - halfWidth, top),
            .curve(0.5 - halfWidth * 0.55, bottom, 0.5 + halfWidth * 0.55, bottom, 0.5 + halfWidth, top),
            .curve(0.5 + halfWidth * 0.45, top + 0.010, 0.5 - halfWidth * 0.45, top + 0.010, 0.5 - halfWidth, top),
            .close,
        ])
    }

    static func tongue(for pose: MouthPose) -> NormalizedPath {
        let opening = mouthOpening(for: pose)
        let halfWidth = 0.010 + opening * 0.25
        let top = mouthHinge.y + opening * 0.55
        let bottom = mouthHinge.y + opening * 0.91
        return NormalizedPath([
            .move(0.5 - halfWidth, top),
            .curve(0.5 - halfWidth * 0.55, bottom, 0.5 + halfWidth * 0.55, bottom, 0.5 + halfWidth, top),
            .curve(0.5 + halfWidth * 0.52, top - 0.004, 0.5 - halfWidth * 0.52, top - 0.004, 0.5 - halfWidth, top),
            .close,
        ])
    }
}

struct NormalizedPath {
    enum Command {
        case move(CGPoint)
        case line(CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close

        static func move(_ x: CGFloat, _ y: CGFloat) -> Self { .move(CGPoint(x: x, y: y)) }
        static func line(_ x: CGFloat, _ y: CGFloat) -> Self { .line(CGPoint(x: x, y: y)) }
        static func curve(_ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat,
                          _ x: CGFloat, _ y: CGFloat) -> Self {
            .curve(to: CGPoint(x: x, y: y),
                   control1: CGPoint(x: c1x, y: c1y),
                   control2: CGPoint(x: c2x, y: c2y))
        }

        var points: [CGPoint] {
            switch self {
            case let .move(point), let .line(point): [point]
            case let .curve(to, control1, control2): [control1, control2, to]
            case .close: []
            }
        }

        var mirrored: Self {
            func mirror(_ point: CGPoint) -> CGPoint { CGPoint(x: 1 - point.x, y: point.y) }
            return switch self {
            case let .move(point): Command.move(mirror(point))
            case let .line(point): Command.line(mirror(point))
            case let .curve(to, control1, control2):
                Command.curve(to: mirror(to), control1: mirror(control1), control2: mirror(control2))
            case .close: Command.close
            }
        }
    }

    let commands: [Command]

    init(_ commands: [Command]) {
        self.commands = commands
    }

    static func symmetricClosed(leftHalf: [Command], lowerControl: CGPoint) -> Self {
        guard case let .move(start)? = leftHalf.first else { return Self([]) }

        func mirror(_ point: CGPoint) -> CGPoint { CGPoint(x: 1 - point.x, y: point.y) }

        var anchors = [start]
        for command in leftHalf.dropFirst() {
            switch command {
            case let .move(point), let .line(point): anchors.append(point)
            case let .curve(to, _, _): anchors.append(to)
            case .close: break
            }
        }

        var commands = leftHalf
        let segments = Array(leftHalf.dropFirst())
        for (index, command) in segments.enumerated().reversed() {
            let previous = anchors[index]
            switch command {
            case .line:
                commands.append(.line(mirror(previous)))
            case let .curve(_, control1, control2):
                commands.append(.curve(to: mirror(previous),
                                       control1: mirror(control2),
                                       control2: mirror(control1)))
            case .move, .close:
                break
            }
        }
        commands.append(.curve(to: start,
                               control1: mirror(lowerControl),
                               control2: lowerControl))
        commands.append(.close)
        return Self(commands)
    }

    var points: [CGPoint] { commands.flatMap(\.points) }
    var mirrored: Self { Self(commands.map(\.mirrored)) }

    func path(in rect: CGRect) -> Path {
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + normalized.x * rect.width,
                    y: rect.minY + normalized.y * rect.height)
        }

        var path = Path()
        for command in commands {
            switch command {
            case let .move(value): path.move(to: point(value))
            case let .line(value): path.addLine(to: point(value))
            case let .curve(to, control1, control2):
                path.addCurve(to: point(to), control1: point(control1), control2: point(control2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

struct CatHeadShape: Shape {
    func path(in rect: CGRect) -> Path { CatFaceGeometry.head.path(in: rect) }
}

struct CatInnerEarShape: Shape {
    let side: CatFaceSide
    func path(in rect: CGRect) -> Path {
        (side == .left ? CatFaceGeometry.leftInnerEar : CatFaceGeometry.leftInnerEar.mirrored).path(in: rect)
    }
}

struct CatScleraShape: Shape {
    let side: CatFaceSide
    func path(in rect: CGRect) -> Path {
        (side == .left ? CatFaceGeometry.leftSclera : CatFaceGeometry.leftSclera.mirrored).path(in: rect)
    }
}

struct CatLidShape: Shape {
    let side: CatFaceSide
    func path(in rect: CGRect) -> Path {
        (side == .left ? CatFaceGeometry.leftLid : CatFaceGeometry.leftLid.mirrored).path(in: rect)
    }
}

struct CatMuzzleShape: Shape {
    let side: CatFaceSide
    func path(in rect: CGRect) -> Path {
        (side == .left ? CatFaceGeometry.leftMuzzle : CatFaceGeometry.leftMuzzle.mirrored).path(in: rect)
    }
}

struct CatNoseShape: Shape {
    func path(in rect: CGRect) -> Path { CatFaceGeometry.nose.path(in: rect) }
}

struct CatNormalizedPathShape: Shape {
    let definition: NormalizedPath
    func path(in rect: CGRect) -> Path { definition.path(in: rect) }
}

struct CatMouthCavityShape: Shape {
    let pose: MouthPose

    func path(in rect: CGRect) -> Path {
        CatFaceGeometry.mouthCavity(for: pose).path(in: rect)
    }
}

struct CatTongueShape: Shape {
    let pose: MouthPose

    func path(in rect: CGRect) -> Path {
        CatFaceGeometry.tongue(for: pose).path(in: rect)
    }
}

extension CatFaceSide: Hashable {}
