import CoreGraphics
import Foundation
import ImageIO

/// How much memory decoding one image from mail may take, wherever Ohia
/// decodes one: in `OhiaPDFParser.xpc` for text recognition, in the app and
/// the workers for Vision's classification and detection, for the PNG the
/// on-device model reads, and for the thumbnails the app draws.
///
/// The budget is in decoded bytes, not pixels. A few megabytes of PNG or
/// OpenEXR can declare an image of any size, and ImageIO decodes some images
/// whole before it can scale them (interlaced PNG and OpenEXR among them), so
/// what a decode costs is the declared pixel count times the bytes each pixel
/// takes decoded: 4 for an 8-bit image, 8 for a 16-bit one, 16 for a
/// floating-point one. The header gives both before any pixel is decoded,
/// and an image whose whole decode would exceed `maxDecodedBytes` is refused.
/// A smaller copy, when asked for, is sized in bytes at the source's depth
/// too, since ImageIO makes it at that depth, and every image handed back has
/// 8 bits per channel: Vision and the drawing code need no more.
public enum ImageDecodeBudget {
    /// The most memory a whole decode of one image may need: 512 MiB, an
    /// 8-bit RGBA image of 2^27 pixels (about 134 megapixels, enough for
    /// 108-megapixel phone photos and A1 drawings scanned at 300 dpi), a
    /// 16-bit one of 2^26, a floating-point one of 2^25. ImageIO's working
    /// set while decoding runs about a quarter to a half over the pixels
    /// themselves: measured on macOS 27, the worst images within the budget
    /// (an 8-bit interlaced PNG of 11,585 pixels square, a 16-bit one of
    /// 8,192 and an OpenEXR of 5,792) peaked at 0.59 to 0.77 GB, where a
    /// 16-bit interlaced PNG and an OpenEXR of 11,585 pixels square, which
    /// a pixel count admitted, had peaked at 1.35 and 2.75 GB; refused by
    /// their headers, they now take 4 MB.
    public static let maxDecodedBytes = 1 << 29

    /// What an image's header says about its decode.
    public struct Header: Sendable, Equatable {
        public let width: Int
        public let height: Int
        /// The most bytes one pixel takes decoded: four samples (ImageIO
        /// decodes color with an alpha or padding channel) of one byte up to
        /// 8 bits, two up to 16, and four for floating-point or deeper
        /// samples, or when the header gives no depth.
        public let bytesPerPixel: Int

        public init(width: Int, height: Int, bytesPerPixel: Int) {
            self.width = width
            self.height = height
            self.bytesPerPixel = bytesPerPixel
        }

        /// The bytes a whole decode needs; nil when that overflows.
        public var decodedBytes: Int? {
            let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            guard !pixelOverflow else { return nil }
            let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
            return byteOverflow ? nil : bytes
        }

        /// Whether a whole decode needs at most `bytes`.
        public func fits(within bytes: Int = ImageDecodeBudget.maxDecodedBytes) -> Bool {
            guard let decodedBytes else { return false }
            return decodedBytes <= bytes
        }

        /// The longest side a copy of the image, its aspect ratio kept, may
        /// have to take at most `bytes` at the image's own depth: the whole
        /// long side when the image already fits.
        public func longSide(fittingIn bytes: Int) -> Int {
            let longSide = max(width, height)
            guard let decodedBytes, decodedBytes > bytes else { return longSide }
            let scale = (Double(max(1, bytes)) / Double(decodedBytes)).squareRoot()
            return max(1, Int((Double(longSide) * scale).rounded(.down)))
        }
    }

    /// The types ImageIO declares it decodes as images
    /// (`CGImageSourceCopyTypeIdentifiers`), every one a raster format. On
    /// macOS 27 ImageIO also opens a PDF (`com.adobe.pdf`, one image, a
    /// rendered thumbnail), a type it does not declare: a PDF named like an
    /// image would reach the PDF parser in the app or a worker. The source's
    /// type is checked against this list before anything else reads it
    /// (`isRasterImage`). The list, rather than conformance to
    /// `UTType.image`, because it is what ImageIO itself says it decodes: two
    /// of its raster types (`com.microsoft.cur`, `public.avis`) do not
    /// conform to `public.image`, while `com.adobe.pdf` is neither listed
    /// nor an image type.
    static let rasterTypes: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])

    /// Whether `source` is of a raster type ImageIO declares
    /// (`rasterTypes`), from the type ImageIO detected in its first bytes:
    /// checked before `CGImageSourceGetCount` or a properties read, which
    /// would open a PDF.
    public static func isRasterImage(_ source: CGImageSource) -> Bool {
        guard let type = CGImageSourceGetType(source) as String? else { return false }
        return rasterTypes.contains(type)
    }

    /// The first image's header; nil when ImageIO cannot read one, or when
    /// the source is not of a raster type ImageIO declares (`isRasterImage`),
    /// a PDF among them, which is then never opened.
    public static func header(of source: CGImageSource) -> Header? {
        guard isRasterImage(source),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let isFloat = (properties[kCGImagePropertyIsFloat] as? NSNumber)?.boolValue == true
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue
        let bytesPerSample: Int
        switch depth {
        case .some(let bits) where !isFloat && bits > 0 && bits <= 8:
            bytesPerSample = 1
        case .some(let bits) where !isFloat && bits > 8 && bits <= 16:
            bytesPerSample = 2
        default:
            bytesPerSample = 4
        }
        return Header(width: width, height: height, bytesPerPixel: 4 * bytesPerSample)
    }

    public static func header(of data: Data) -> Header? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(header(of:))
    }

    public static func header(ofFileAt url: URL) -> Header? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(header(of:))
    }

    /// Whether `data` may be decoded in this process: ImageIO reads a raster
    /// image's header in it and the whole decode fits `maxDecodedBytes`.
    /// Reads only the header. False for bytes ImageIO does not read as a
    /// raster image, a PDF named like an image among them, so that nothing
    /// that would open them (`NSImage`, a model's image attachment) is
    /// handed them either.
    public static func admits(_ data: Data) -> Bool {
        header(of: data)?.fits() == true
    }

    /// `admits` for the image in a file.
    public static func admits(fileAt url: URL) -> Bool {
        header(ofFileAt: url)?.fits() == true
    }

    /// Whether the app may draw `data` with `NSImage(data:)`: a raster
    /// image `admits`, or an SVG (`looksLikeSVG`). ImageIO does not read
    /// SVG, and gives one no type; `NSImage` draws it as a vector at the
    /// size it is shown, so no decode budget applies. A PDF is refused:
    /// ImageIO types a PDF by its bytes.
    ///
    /// Only for `NSImage(data:)`, which picks the image representation from
    /// the bytes, the same bytes this checks. `NSImage(contentsOfFile:)`
    /// picks it from the file's extension, so it would open a raster image
    /// or an SVG with a PDF inside as a PDF when the attachment is named
    /// `.pdf`, and an SVG named `.png` not at all.
    public static func admitsDrawing(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil else {
            return looksLikeSVG(data.prefix(svgSniffLength))
        }
        return header(of: source)?.fits() == true
    }

    /// How much of an untyped file `looksLikeSVG` reads: enough for a long
    /// licence comment or document type declaration before the `<svg`
    /// element.
    static let svgSniffLength = 1 << 16

    /// Whether `prefix`, a file's first bytes, opens an SVG document: markup
    /// in UTF-8, or UTF-16 with its byte-order mark, whose first character
    /// (after any byte-order mark and white space) is `<`, with an `<svg`
    /// element in it. A prefix with a `%PDF-` header in it is refused too,
    /// though `NSImage(data:)` draws such a file as the SVG it opens with.
    static func looksLikeSVG(_ prefix: Data) -> Bool {
        let text: String
        if prefix.starts(with: [0xFF, 0xFE]) || prefix.starts(with: [0xFE, 0xFF]) {
            text = String(data: prefix.prefix(prefix.count & ~1), encoding: .utf16) ?? ""
        } else {
            text = String(decoding: prefix, as: UTF8.self)
        }
        guard !text.contains("%PDF-") else { return false }
        let markup = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        guard markup.first == "<" else { return false }
        return markup.range(of: "<svg", options: .caseInsensitive) != nil
    }

    public enum Decoded {
        case image(CGImage)
        /// ImageIO could not read an image, or could not decode it.
        case undecodable
        /// Decoding the image whole could need more than the budget; no
        /// pixel was decoded.
        case tooLarge(Header)
    }

    /// The first image in `source`, upright (ImageIO applies its EXIF
    /// orientation), at 8 bits per channel, no longer than `maxPixelSize` on
    /// its long side and taking no more than `maxBytes` at the image's own
    /// depth, its aspect ratio kept. Refused before a pixel is decoded when a
    /// whole decode could need more than `maxDecodedBytes`.
    public static func thumbnail(
        of source: CGImageSource,
        maxPixelSize: Int? = nil,
        maxBytes: Int? = nil,
        maxDecodedBytes: Int = ImageDecodeBudget.maxDecodedBytes
    ) -> Decoded {
        guard let header = header(of: source) else { return .undecodable }
        guard header.fits(within: maxDecodedBytes) else { return .tooLarge(header) }
        var longSide = max(header.width, header.height)
        if let maxBytes { longSide = min(longSide, header.longSide(fittingIn: maxBytes)) }
        if let maxPixelSize { longSide = min(longSide, max(1, maxPixelSize)) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let eightBit = eightBitsPerChannel(image) else { return .undecodable }
        return .image(eightBit)
    }

    /// The first image in `source` at full size and as stored (its EXIF
    /// orientation not applied), at 8 bits per channel. Refused like
    /// `thumbnail`.
    public static func image(
        of source: CGImageSource,
        maxDecodedBytes: Int = ImageDecodeBudget.maxDecodedBytes
    ) -> Decoded {
        guard let header = header(of: source) else { return .undecodable }
        guard header.fits(within: maxDecodedBytes) else { return .tooLarge(header) }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary),
              let eightBit = eightBitsPerChannel(image) else { return .undecodable }
        return .image(eightBit)
    }

    /// `image` itself when it has 8 bits per channel or fewer; otherwise a
    /// copy drawn at 8 bits per channel, in gray for a gray image without
    /// alpha and in sRGB otherwise. Floating-point samples outside 0...1 are
    /// clamped.
    static func eightBitsPerChannel(_ image: CGImage) -> CGImage? {
        let isFloat = image.bitmapInfo.contains(.floatComponents)
        guard image.bitsPerComponent > 8 || isFloat else { return image }
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            hasAlpha = true
        case .none, .noneSkipFirst, .noneSkipLast:
            hasAlpha = false
        @unknown default:
            hasAlpha = true
        }
        let isGray = image.colorSpace?.model == .monochrome && !hasAlpha
        guard let space = isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: isGray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
