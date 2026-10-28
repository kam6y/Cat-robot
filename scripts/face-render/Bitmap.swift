import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// sRGB・RGBA8 の画素バッファ（参照画像の計測と合成に使う）。
struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    init(image: CGImage) {
        self.init(width: image.width, height: image.height)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        withContext { context in
            drawImage(image, in: bounds, context: context)
        }
    }

    init(contentsOf path: String) throws {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HarnessError("画像を読めません: \(path)")
        }
        self.init(image: image)
    }

    func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        let index = (y * width + x) * 4
        return (Double(pixels[index]), Double(pixels[index + 1]), Double(pixels[index + 2]))
    }

    /// 上が y=0 の座標系で描く CGContext を渡す。
    mutating func withContext(_ body: (CGContext) -> Void) {
        let width = width
        let height = height
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            body(context)
        }
    }

    func makeImage() -> CGImage {
        var copy = pixels
        return copy.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return context.makeImage()!
        }
    }

    func cropped(to rect: CGRect) -> CGImage {
        makeImage().cropping(to: rect.integral)!
    }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw HarnessError("書き込めません: \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw HarnessError("PNG の保存に失敗: \(path)") }
}

/// 黒地に画像を並べる・重ねるための合成。
func compose(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    var canvas = Bitmap(width: width, height: height)
    canvas.withContext { context in
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        draw(context)
    }
    return canvas.makeImage()
}

/// 上下反転済みの context に CGImage を正立で描く。
func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext, alpha: CGFloat = 1) {
    context.saveGState()
    context.setAlpha(alpha)
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    context.restoreGState()
}
