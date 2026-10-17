import AppKit
import ImageIO

/// Owned RGBA/BGRA buffers prepared off the animation clock.
struct CutoutPixels {
    let width: Int, height: Int
    var rgba: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width; height = image.height
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 16_000_000 else {
            throw CutoutError.invalid("Image exceeds the character asset pixel budget")
        }
        rgba = [UInt8](repeating: 0, count: width * height * 4)
        let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw CutoutError.invalid("Cannot decode character RGBA") }
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CutoutError.invalid("Cannot read image: \(url.path)")
        }
        return image
    }

    func image(appKitFormat: Bool = false) throws -> CGImage {
        // AppKit backing stores use BGRA. Prepare the lossless channel order
        // once so display-list replay need not permute every source image.
        var bytes = rgba
        if appKitFormat {
            for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: appKitFormat
                ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw CutoutError.invalid("Cannot encode character RGBA")
        }
        return image
    }

}
