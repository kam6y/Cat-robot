import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Confined to the capture queue. Retains one buffer; conversion happens only on request.
struct CameraFrameCache {
    private struct Frame {
        let buffer: CVPixelBuffer
        let generation: UUID
        let capturedAt: TimeInterval
        let imageOrientation: CGImagePropertyOrientation
    }
    private var frame: Frame?
    private let context = CIContext(options: [.cacheIntermediates: false])

    mutating func store(_ buffer: CVPixelBuffer, generation: UUID, capturedAt: TimeInterval,
                        imageOrientation: CGImagePropertyOrientation) {
        frame = .init(buffer: buffer, generation: generation, capturedAt: capturedAt,
                      imageOrientation: imageOrientation)
    }

    mutating func clear() { frame = nil }

    func snapshot(generation: UUID, now: TimeInterval) throws -> CameraSnapshot? {
        guard let frame, frame.generation == generation,
              CameraSnapshot.isFresh(capturedAt: frame.capturedAt, now: now) else { return nil }
        var image = CIImage(cvPixelBuffer: frame.buffer).oriented(frame.imageOrientation)
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > 1024 {
            let scale = 1024 / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let output = context.createCGImage(image, from: image.extent) else {
            throw CameraSnapshotError.unavailable
        }
        return .init(generation: generation, capturedAt: frame.capturedAt, image: output)
    }
}
