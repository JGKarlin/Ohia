import AVFoundation
import Foundation
import ImageIO

/// What a media file records about its capture. `unzonedCaptureInstant` is
/// an absolute capture instant with no local time zone (an MP4 `mvhd` time or
/// a `Z` QuickTime date); the worker localizes it with the place's time zone.
public struct CaptureMetadataReading: Sendable, Equatable {
    public var metadata: AttachmentCaptureMetadata
    public var unzonedCaptureInstant: Date?

    public init(metadata: AttachmentCaptureMetadata, unzonedCaptureInstant: Date? = nil) {
        self.metadata = metadata
        self.unzonedCaptureInstant = unzonedCaptureInstant
    }
}

public enum CaptureMetadataReader {
    static let maxTitleCharacters = 200
    static let maxCaptionCharacters = 600
    static let maxCreditCharacters = 120
    static let maxKeywords = 12
    static let maxKeywordCharacters = 60

    // MARK: Images

    public static func readImage(at url: URL) -> CaptureMetadataReading? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return nil
        }
        return readImage(properties: properties, xmp: CGImageSourceCopyMetadataAtIndex(source, 0, options))
    }

    static func readImage(properties: [CFString: Any], xmp: CGImageMetadata?) -> CaptureMetadataReading {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]

        let filter = BoilerplateFilter(
            make: string(tiff[kCGImagePropertyTIFFMake]),
            systemMarkers: [
                string(exif[kCGImagePropertyExifUserComment]),
                string(tiff[kCGImagePropertyTIFFSoftware]),
                string(tiff[kCGImagePropertyTIFFModel])
            ]
        )

        let title = filter.accept(
            xmpStrings(xmp, "dc:title").first
                ?? string(iptc[kCGImagePropertyIPTCObjectName])
                ?? string(png[kCGImagePropertyPNGTitle]),
            limit: maxTitleCharacters
        )
        let caption = filter.accept(
            xmpStrings(xmp, "dc:description").first
                ?? string(iptc[kCGImagePropertyIPTCCaptionAbstract])
                ?? string(tiff[kCGImagePropertyTIFFImageDescription])
                ?? string(png[kCGImagePropertyPNGDescription]),
            limit: maxCaptionCharacters
        )
        let xmpKeywords = xmpStrings(xmp, "dc:subject")
        let keywords = filter.acceptList(
            xmpKeywords.isEmpty ? strings(iptc[kCGImagePropertyIPTCKeywords]) : xmpKeywords
        )
        let credit = filter.accept(
            xmpStrings(xmp, "photoshop:Credit").first
                ?? string(iptc[kCGImagePropertyIPTCCredit])
                ?? xmpStrings(xmp, "dc:creator").first
                ?? strings(iptc[kCGImagePropertyIPTCByline]).first
                ?? string(tiff[kCGImagePropertyTIFFArtist]),
            limit: maxCreditCharacters
        )

        let metadata = AttachmentCaptureMetadata(
            captureTime: imageCaptureTime(exif: exif, gps: gps),
            coordinate: imageCoordinate(gps: gps),
            title: title,
            caption: caption == title ? nil : caption,
            keywords: keywords,
            credit: credit
        )
        return CaptureMetadataReading(metadata: metadata)
    }

    static func imageCoordinate(gps: [CFString: Any]) -> AttachmentCaptureMetadata.Coordinate? {
        guard let latitude = double(gps[kCGImagePropertyGPSLatitude]),
              let longitude = double(gps[kCGImagePropertyGPSLongitude]) else {
            return nil
        }
        let latitudeRef = string(gps[kCGImagePropertyGPSLatitudeRef])?.uppercased()
        let longitudeRef = string(gps[kCGImagePropertyGPSLongitudeRef])?.uppercased()
        var altitude = double(gps[kCGImagePropertyGPSAltitude])
        if let ref = double(gps[kCGImagePropertyGPSAltitudeRef]), ref == 1, let value = altitude {
            altitude = -abs(value)
        }
        return AttachmentCaptureMetadata.Coordinate(
            latitude: latitudeRef == "S" ? -abs(latitude) : abs(latitude),
            longitude: longitudeRef == "W" ? -abs(longitude) : abs(longitude),
            altitudeMeters: altitude
        )
    }

    /// `DateTimeOriginal` is the local wall clock; its offset comes from
    /// `OffsetTimeOriginal`, or failing that from the GPS UTC timestamp.
    static func imageCaptureTime(exif: [CFString: Any], gps: [CFString: Any]) -> AttachmentCaptureMetadata.CaptureTime? {
        let candidates: [(CFString, CFString)] = [
            (kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifOffsetTimeOriginal),
            (kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifOffsetTimeDigitized)
        ]
        for (dateKey, offsetKey) in candidates {
            guard let digits = exifDateDigits(string(exif[dateKey])) else { continue }
            let offset = utcOffsetSeconds(string(exif[offsetKey]))
                ?? gpsDerivedOffset(localDigits: digits, gps: gps)
            if let time = AttachmentCaptureMetadata.CaptureTime(
                year: digits[0], month: digits[1], day: digits[2],
                hour: digits[3], minute: digits[4], second: digits[5],
                utcOffsetSeconds: offset
            ) {
                return time
            }
        }
        return nil
    }

    private static func exifDateDigits(_ value: String?) -> [Int]? {
        guard let value else { return nil }
        let digits = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard digits.count >= 6, digits[0] > 0 else { return nil }
        return Array(digits.prefix(6))
    }

    private static func gpsDerivedOffset(localDigits: [Int], gps: [CFString: Any]) -> Int? {
        guard let dateDigits = string(gps[kCGImagePropertyGPSDateStamp])
                .map({ $0.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }),
              dateDigits.count >= 3,
              let timeText = string(gps[kCGImagePropertyGPSTimeStamp]) else {
            return nil
        }
        let timeParts = timeText.split(separator: ":").compactMap { Double($0) }
        guard timeParts.count >= 3,
              timeParts.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 61 }),
              dateDigits.prefix(3).allSatisfy({ $0 > 0 && $0 <= 9999 }) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let utc = calendar.date(from: DateComponents(
                year: dateDigits[0], month: dateDigits[1], day: dateDigits[2],
                hour: Int(timeParts[0]), minute: Int(timeParts[1]), second: Int(timeParts[2])
              )),
              let local = calendar.date(from: DateComponents(
                year: localDigits[0], month: localDigits[1], day: localDigits[2],
                hour: localDigits[3], minute: localDigits[4], second: localDigits[5]
              )) else {
            return nil
        }
        // Offsets are whole quarter hours; anything else means the clocks disagree.
        let raw = local.timeIntervalSince(utc)
        let quarterHours = (raw / 900).rounded()
        guard abs(raw - quarterHours * 900) <= 120, abs(quarterHours) <= 56 else { return nil }
        return Int(quarterHours) * 900
    }

    /// `+03:00`, `-0500`, `Z`.
    static func utcOffsetSeconds(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.uppercased() == "Z" { return 0 }
        guard let sign = value.first, sign == "+" || sign == "-" else { return nil }
        let digits = value.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
              hours <= 14, minutes < 60 else {
            return nil
        }
        let seconds = hours * 3600 + minutes * 60
        return sign == "-" ? -seconds : seconds
    }

    // MARK: Movies

    public static func readMovie(at url: URL) async throws -> CaptureMetadataReading? {
        let asset = AVURLAsset(url: url)
        let items = try await asset.load(.metadata)
        let creationItem = (try? await asset.load(.creationDate)) ?? nil
        return try await readMovie(items: items, fallbackCreationItem: creationItem)
    }

    static func readMovie(items: [AVMetadataItem], fallbackCreationItem: AVMetadataItem?) async throws -> CaptureMetadataReading? {
        func first(_ identifiers: [AVMetadataIdentifier]) -> AVMetadataItem? {
            for identifier in identifiers {
                if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first {
                    return item
                }
            }
            return nil
        }
        func text(_ identifiers: [AVMetadataIdentifier]) async -> String? {
            guard let item = first(identifiers) else { return nil }
            return (try? await item.load(.stringValue)) ?? nil
        }

        var coordinate: AttachmentCaptureMetadata.Coordinate?
        if let iso = await text([
            .quickTimeMetadataLocationISO6709,
            .quickTimeUserDataLocationISO6709,
            .commonIdentifierLocation
        ]) {
            coordinate = AttachmentCaptureMetadata.Coordinate(iso6709: iso)
        }

        var captureTime: AttachmentCaptureMetadata.CaptureTime?
        var unzoned: Date?
        if let stamp = await text([.quickTimeMetadataCreationDate, .commonIdentifierCreationDate]) {
            (captureTime, unzoned) = parseQuickTimeDate(stamp)
        }
        if captureTime == nil, unzoned == nil, let item = fallbackCreationItem {
            unzoned = (try? await item.load(.dateValue)) ?? nil
        }

        let filter = BoilerplateFilter(
            make: await text([.quickTimeMetadataMake]),
            systemMarkers: [
                await text([.quickTimeMetadataModel]),
                await text([.quickTimeMetadataSoftware, .commonIdentifierSoftware])
            ]
        )
        let title = filter.accept(await text([.commonIdentifierTitle, .quickTimeMetadataTitle]), limit: maxTitleCharacters)
        let caption = filter.accept(
            await text([.commonIdentifierDescription, .quickTimeMetadataDescription]),
            limit: maxCaptionCharacters
        )
        let keywordText = await text([.quickTimeMetadataKeywords])
        let keywords = filter.acceptList(
            keywordText.map { $0.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init) } ?? []
        )
        let credit = filter.accept(
            await text([.commonIdentifierCreator, .commonIdentifierArtist, .quickTimeMetadataAuthor]),
            limit: maxCreditCharacters
        )

        let metadata = AttachmentCaptureMetadata(
            captureTime: captureTime,
            coordinate: coordinate,
            title: title,
            caption: caption == title ? nil : caption,
            keywords: keywords,
            credit: credit
        )
        guard metadata.hasContent || unzoned != nil else { return nil }
        return CaptureMetadataReading(metadata: metadata, unzonedCaptureInstant: unzoned)
    }

    /// `2026-10-06T06:50:54+0300` → local time with its offset; no zone → the
    /// recorder's local wall clock (offset unknown); `…Z` → an absolute UTC
    /// instant awaiting the place's time zone.
    static func parseQuickTimeDate(_ value: String) -> (AttachmentCaptureMetadata.CaptureTime?, Date?) {
        let pattern = #"^\s*(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return (nil, nil)
        }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: value).map { String(value[$0]) }
        }
        let numbers = (1...6).map { group($0).flatMap(Int.init) ?? 0 }
        let zone = group(7)
        if zone?.uppercased() != "Z" {
            let offset = zone.flatMap(utcOffsetSeconds)
            if zone != nil, offset == nil { return (nil, nil) }
            return (AttachmentCaptureMetadata.CaptureTime(
                year: numbers[0], month: numbers[1], day: numbers[2],
                hour: numbers[3], minute: numbers[4], second: numbers[5],
                utcOffsetSeconds: offset
            ), nil)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = calendar.date(from: DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2],
            hour: numbers[3], minute: numbers[4], second: numbers[5]
        ))
        return (nil, instant)
    }

    // MARK: Values

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func strings(_ value: Any?) -> [String] {
        if let array = value as? [Any] { return array.compactMap { string($0) } }
        return string(value).map { [$0] } ?? []
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// XMP values at `path`: a plain string, or each entry of a bag / seq /
    /// language alternative (`x-default` first, as ImageIO orders it).
    private static func xmpStrings(_ metadata: CGImageMetadata?, _ path: String) -> [String] {
        guard let metadata,
              let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else {
            return []
        }
        if let text = value as? String { return [text] }
        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { entry in
            if let text = entry as? String { return text }
            if CFGetTypeID(entry as CFTypeRef) == CGImageMetadataTagGetTypeID() {
                return CGImageMetadataTagCopyValue(entry as! CGImageMetadataTag) as? String
            }
            return nil
        }
    }
}

/// Drops values a camera, phone or app writes on its own: Olympus's
/// `OLYMPUS DIGITAL CAMERA`, the system `Screenshot` marker (which macOS also
/// writes to the EXIF user comment), software or model strings.
struct BoilerplateFilter {
    let makeToken: String?
    let systemMarkers: Set<String>

    init(make: String?, systemMarkers: [String?]) {
        let token = make?
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .first
            .map { Self.folded(String($0)) }
        self.makeToken = (token?.count ?? 0) >= 3 ? token : nil
        self.systemMarkers = Set(systemMarkers.compactMap { $0 }.map(Self.folded).filter { !$0.isEmpty })
    }

    func accept(_ value: String?, limit: Int) -> String? {
        guard let cleaned = Self.cleaned(value), !isBoilerplate(cleaned) else { return nil }
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func acceptList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let accepted = accept(value, limit: CaptureMetadataReader.maxKeywordCharacters),
                  seen.insert(Self.folded(accepted)).inserted else { continue }
            result.append(accepted)
            if result.count == CaptureMetadataReader.maxKeywords { break }
        }
        return result
    }

    private func isBoilerplate(_ value: String) -> Bool {
        let key = Self.folded(value)
        if systemMarkers.contains(key) { return true }
        // Camera-written descriptions are upper-case and name the maker.
        if let makeToken, key.contains(makeToken), value == value.uppercased() { return true }
        return false
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .replacingOccurrences(of: "\u{0}", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
