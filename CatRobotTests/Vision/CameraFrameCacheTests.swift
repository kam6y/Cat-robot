import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import CatRobot

final class CameraFrameCacheTests: XCTestCase {
    func testSnapshotBakesRotationWithoutMirroring() throws {
        let buffer = try cameraTestBuffer(width: 4, height: 2, stripes: true)
        let cases: [(CGImagePropertyOrientation, Int, Int, [UInt8])] = [
            (.up, 4, 2, [255, 0, 0]),
            (.down, 4, 2, [255, 255, 0]),
            (.right, 2, 4, [255, 0, 0]),
            (.left, 2, 4, [255, 255, 0])
        ]
        for (rotation, width, height, firstColor) in cases {
            var cache = CameraFrameCache()
            let generation = UUID()
            cache.store(buffer, generation: generation, capturedAt: 1,
                        imageOrientation: rotation)
            let snapshot = try XCTUnwrap(cache.snapshot(generation: generation, now: 1.1))
            XCTAssertEqual(snapshot.image.width, width)
            XCTAssertEqual(snapshot.image.height, height)
            XCTAssertEqual(try cameraImageRGB(snapshot.image, x: 0, y: 0), firstColor, "rotation \(rotation)")
        }
    }

    func testSnapshotFits1024WithoutUpscaling() throws {
        for (width, height, expectedWidth, expectedHeight) in [(1600, 800, 1024, 512), (4, 2, 4, 2)] {
            var cache = CameraFrameCache()
            let generation = UUID()
            cache.store(try cameraTestBuffer(width: width, height: height), generation: generation,
                        capturedAt: 0, imageOrientation: .up)
            let snapshot = try XCTUnwrap(cache.snapshot(generation: generation, now: 0))
            XCTAssertEqual(snapshot.image.width, expectedWidth)
            XCTAssertEqual(snapshot.image.height, expectedHeight)
        }
    }

    func testOnlyFreshCurrentGenerationCanBeReadAndClearDropsFrame() throws {
        var cache = CameraFrameCache()
        let generation = UUID()
        cache.store(try cameraTestBuffer(width: 4, height: 2), generation: generation,
                    capturedAt: 1, imageOrientation: .down)
        XCTAssertNil(try cache.snapshot(generation: UUID(), now: 1.1))
        XCTAssertNil(try cache.snapshot(generation: generation, now: 0.9))
        XCTAssertNil(try cache.snapshot(generation: generation, now: .nan))
        XCTAssertNotNil(try cache.snapshot(generation: generation, now: 1.399))
        XCTAssertNil(try cache.snapshot(generation: generation, now: 1.4))
        cache.clear()
        XCTAssertNil(try cache.snapshot(generation: generation, now: 1.1))
    }

    func testNewestFrameReplacesEarlierFrame() throws {
        var cache = CameraFrameCache()
        let first = UUID(), latest = UUID()
        let buffer = try cameraTestBuffer(width: 4, height: 2)
        cache.store(buffer, generation: first, capturedAt: 1, imageOrientation: .up)
        cache.store(buffer, generation: latest, capturedAt: 2, imageOrientation: .down)
        XCTAssertNil(try cache.snapshot(generation: first, now: 2))
        let result = try XCTUnwrap(cache.snapshot(generation: latest, now: 2.1))
        XCTAssertEqual(result.capturedAt, 2)
    }
}

func cameraTestBuffer(width: Int, height: Int, stripes: Bool = false) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                      kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      attributes, &result), kCVReturnSuccess)
    let buffer = try XCTUnwrap(result)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let colors: [[UInt8]] = [[0, 0, 255, 255], [0, 255, 0, 255], [255, 0, 0, 255], [0, 255, 255, 255]]
    for y in 0..<height {
        for x in 0..<width {
            let color = colors[stripes ? x % 4 : 0]
            for channel in 0..<4 { bytes[y * stride + x * 4 + channel] = color[channel] }
        }
    }
    return buffer
}

func cameraImageRGB(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let index = y * image.width * 4 + x * 4
    return [bytes[index], bytes[index + 1], bytes[index + 2]]
}

func makeCameraTestImage() throws -> CGImage {
    let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
        bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
    return try XCTUnwrap(context.makeImage())
}
