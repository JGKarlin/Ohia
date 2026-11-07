import Foundation
import OhiaCore

/// When, where and by whom a photo or video attachment was captured, read
/// from its embedded EXIF / IPTC / XMP / QuickTime metadata. Every value is
/// recorded file metadata or a MapKit name for a recorded coordinate, never
/// something inferred from pixels.
public struct AttachmentCaptureMetadata: Codable, Sendable, Equatable {
    /// Bump when reading or naming changes so stored rows are visited again.
    public static let readerVersion = "capture-v1"

    public struct Coordinate: Codable, Sendable, Equatable {
        public let latitude: Double
        public let longitude: Double
        public let altitudeMeters: Double?

        public init?(latitude: Double, longitude: Double, altitudeMeters: Double? = nil) {
            guard latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude),
                  // Cameras without a fix write 0,0 ("Null Island").
                  abs(latitude) > 1e-6 || abs(longitude) > 1e-6 else {
                return nil
            }
            self.latitude = latitude
            self.longitude = longitude
            self.altitudeMeters = altitudeMeters.flatMap { $0.isFinite ? $0 : nil }
        }

        /// ISO 6709 point as written by QuickTime/MP4 (`+DD.DDDD+DDD.DDDD+AAA.AAA/`),
        /// including the degree-minute(-second) forms the standard allows.
        public init?(iso6709: String) {
            let pattern = #"^\s*([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: iso6709, range: NSRange(iso6709.startIndex..., in: iso6709)),
                  let latRange = Range(match.range(at: 1), in: iso6709),
                  let lonRange = Range(match.range(at: 2), in: iso6709),
                  let latitude = Self.iso6709Degrees(String(iso6709[latRange]), degreeDigits: 2),
                  let longitude = Self.iso6709Degrees(String(iso6709[lonRange]), degreeDigits: 3) else {
                return nil
            }
            let altitude = Range(match.range(at: 3), in: iso6709).flatMap { Double(iso6709[$0]) }
            self.init(latitude: latitude, longitude: longitude, altitudeMeters: altitude)
        }

        private static func iso6709Degrees(_ token: String, degreeDigits: Int) -> Double? {
            guard let sign = token.first, sign == "+" || sign == "-" else { return nil }
            let body = token.dropFirst()
            let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let integer = String(parts[0])
            let fraction = parts.count > 1 ? "." + parts[1] : ""
            guard !integer.isEmpty, integer.allSatisfy(\.isNumber) else { return nil }
            let value: Double?
            switch integer.count {
            case degreeDigits:
                value = Double(integer + fraction)
            case degreeDigits + 2:
                let degrees = Double(integer.prefix(degreeDigits))
                let minutes = Double(String(integer.suffix(2)) + fraction)
                value = degrees.flatMap { d in minutes.map { d + $0 / 60 } }
            case degreeDigits + 4:
                let degrees = Double(integer.prefix(degreeDigits))
                let minutes = Double(integer.dropFirst(degreeDigits).prefix(2))
                let seconds = Double(String(integer.suffix(2)) + fraction)
                if let degrees, let minutes, let seconds {
                    value = degrees + minutes / 60 + seconds / 3600
                } else {
                    value = nil
                }
            default:
                value = nil
            }
            return value.map { sign == "-" ? -$0 : $0 }
        }
    }

    /// Wall-clock capture time where the media was recorded, plus the UTC
    /// offset when the file states one.
    public struct CaptureTime: Codable, Sendable, Equatable {
        /// `yyyy-MM-dd'T'HH:mm:ss` in the capture location's local time.
        public let localDateTime: String
        public let utcOffsetSeconds: Int?

        public init?(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, utcOffsetSeconds: Int?) {
            guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
                  (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
                return nil
            }
            if let utcOffsetSeconds, abs(utcOffsetSeconds) > 14 * 3600 { return nil }
            self.localDateTime = String(
                format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, min(second, 59)
            )
            self.utcOffsetSeconds = utcOffsetSeconds
            // Reject dates the calendar would silently normalize (Feb 30 → Mar 2).
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let wall = wallClockInGMT,
                  calendar.dateComponents([.year, .month, .day], from: wall)
                    == DateComponents(year: year, month: month, day: day) else {
                return nil
            }
        }

        /// The local wall-clock time of an absolute instant in `timeZone`.
        public init?(absolute date: Date, timeZone: TimeZone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day,
                  let hour = parts.hour, let minute = parts.minute, let second = parts.second else {
                return nil
            }
            self.init(
                year: year, month: month, day: day, hour: hour, minute: minute, second: second,
                utcOffsetSeconds: timeZone.secondsFromGMT(for: date)
            )
        }

        var components: DateComponents? {
            let digits = localDateTime.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard digits.count == 6 else { return nil }
            return DateComponents(
                year: digits[0], month: digits[1], day: digits[2],
                hour: digits[3], minute: digits[4], second: digits[5]
            )
        }

        /// The wall-clock time as a `Date` in GMT, for formatting with a GMT
        /// formatter so the displayed time is the capture-location time.
        var wallClockInGMT: Date? {
            guard let components else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar.date(from: components)
        }

        public var absoluteDate: Date? {
            guard let utcOffsetSeconds, let wall = wallClockInGMT else { return nil }
            return wall.addingTimeInterval(TimeInterval(-utcOffsetSeconds))
        }

        /// Language-neutral form for prompts and search: `2026-10-06 06:50 (UTC+03:00)`.
        public var evidenceText: String {
            let minutePrecision = String(localDateTime.prefix(16)).replacingOccurrences(of: "T", with: " ")
            guard let utcOffsetSeconds else { return minutePrecision }
            let sign = utcOffsetSeconds < 0 ? "-" : "+"
            let magnitude = abs(utcOffsetSeconds)
            return minutePrecision + String(format: " (UTC%@%02d:%02d)", sign, magnitude / 3600, (magnitude % 3600) / 60)
        }
    }

    /// A MapKit name for the recorded coordinate, in the reading language.
    public struct Place: Codable, Sendable, Equatable {
        /// A named point of interest or natural feature at the coordinate.
        public let landmark: String?
        /// City with its state / prefecture context, as MapKit formats it.
        public let locality: String?
        public let country: String?
        public let languageIdentifier: String
        public let timeZoneIdentifier: String?

        public init(
            landmark: String?,
            locality: String?,
            country: String?,
            languageIdentifier: String,
            timeZoneIdentifier: String? = nil
        ) {
            self.landmark = Self.cleaned(landmark)
            self.locality = Self.cleaned(locality)
            self.country = Self.cleaned(country)
            self.languageIdentifier = languageIdentifier
            self.timeZoneIdentifier = Self.cleaned(timeZoneIdentifier)
        }

        /// `Landmark, City, State, Country`, dropping any part another part
        /// already contains (MapKit's city context often carries the country).
        public var displayName: String? {
            var parts: [String] = []
            for candidate in [landmark, locality, country].compactMap({ $0 }) {
                let key = Self.folded(candidate)
                if parts.contains(where: { Self.folded($0).contains(key) }) { continue }
                parts.removeAll { key.contains(Self.folded($0)) }
                parts.append(candidate)
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }

        static func folded(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func cleaned(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }
    }

    public var captureTime: CaptureTime?
    public var coordinate: Coordinate?
    public var place: Place?
    public var title: String?
    public var caption: String?
    public var keywords: [String]
    public var credit: String?
    /// True byte size of a Mail Drop file, learned from the server.
    public var remoteSizeBytes: Int?
    /// A capture instant the file recorded without a time zone (MP4 `mvhd`,
    /// a `Z` QuickTime date). `captureTime` is derived from it in the place's
    /// zone once known; kept so a later place lookup can re-localize it.
    public var unzonedCaptureInstant: Date?

    public init(
        captureTime: CaptureTime? = nil,
        coordinate: Coordinate? = nil,
        place: Place? = nil,
        title: String? = nil,
        caption: String? = nil,
        keywords: [String] = [],
        credit: String? = nil,
        remoteSizeBytes: Int? = nil,
        unzonedCaptureInstant: Date? = nil
    ) {
        self.captureTime = captureTime
        self.coordinate = coordinate
        self.place = place
        self.title = title
        self.caption = caption
        self.keywords = keywords
        self.credit = credit
        self.remoteSizeBytes = remoteSizeBytes
        self.unzonedCaptureInstant = unzonedCaptureInstant
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureTime = try container.decodeIfPresent(CaptureTime.self, forKey: .captureTime)
        coordinate = try container.decodeIfPresent(Coordinate.self, forKey: .coordinate)
        place = try container.decodeIfPresent(Place.self, forKey: .place)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        credit = try container.decodeIfPresent(String.self, forKey: .credit)
        remoteSizeBytes = try container.decodeIfPresent(Int.self, forKey: .remoteSizeBytes)
        unzonedCaptureInstant = try container.decodeIfPresent(Date.self, forKey: .unzonedCaptureInstant)
    }

    /// True when the file recorded anything worth showing or searching.
    public var hasContent: Bool {
        captureTime != nil || unzonedCaptureInstant != nil || coordinate != nil || title != nil || caption != nil || !keywords.isEmpty || credit != nil
    }

    public static func versionTag(languageIdentifier: String) -> String {
        "\(readerVersion)|\(languageIdentifier)"
    }

    public static func decode(_ json: String?) -> AttachmentCaptureMetadata? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AttachmentCaptureMetadata.self, from: data)
    }

    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Reader-row fact: `Oct 6, 2026, 6:50 AM · Serengeti National Park, Tanzania`,
    /// with the time shown as the wall clock where it was captured.
    public func readerLine(locale: Locale) -> String? {
        var parts: [String] = []
        if let wall = captureTime?.wallClockInGMT {
            let style = Date.FormatStyle(
                date: .abbreviated,
                time: .shortened,
                locale: locale,
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
            parts.append(wall.formatted(style))
        }
        if let place = place?.displayName {
            parts.append(place)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Labelled lines for summaries, search and Composer evidence.
    public var evidenceText: String? {
        var lines: [String] = []
        if let captureTime { lines.append("Captured: \(captureTime.evidenceText)") }
        if let place = place?.displayName { lines.append("Place: \(place)") }
        if let coordinate {
            lines.append(String(format: "Coordinates: %.4f, %.4f", coordinate.latitude, coordinate.longitude))
        }
        if let title { lines.append("Title: \(title)") }
        if let caption { lines.append("Caption: \(caption)") }
        if !keywords.isEmpty { lines.append("Keywords: \(keywords.joined(separator: ", "))") }
        if let credit { lines.append("Credit: \(credit)") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Recorded time and place, for the mail summarizer's attachment list:
    /// `Recorded metadata: captured 2026-10-06 06:50 (UTC+03:00) at Serengeti National Park, Tanzania.`
    public var summaryLead: String? {
        var clauses: [String] = []
        if let captureTime { clauses.append("captured \(captureTime.evidenceText)") }
        if let place = place?.displayName { clauses.append("at \(place)") }
        return clauses.isEmpty ? nil : "Recorded metadata: " + clauses.joined(separator: " ") + "."
    }

    /// Person-written title / caption, each clipped so the summarizer's small
    /// per-attachment budget keeps room for the visual description.
    public var summaryCaptions: String? {
        func clipped(_ value: String) -> String {
            value.count <= Self.summaryCaptionCharacters
                ? value
                : String(value.prefix(Self.summaryCaptionCharacters)).trimmingCharacters(in: .whitespaces)
        }
        let captions = [
            title.map { "title \"\(clipped($0))\"" },
            caption.map { "caption \"\(clipped($0))\"" }
        ].compactMap { $0 }
        return captions.isEmpty ? nil : "Embedded " + captions.joined(separator: ", ") + "."
    }

    static let summaryCaptionCharacters = 80

    private enum CodingKeys: String, CodingKey {
        case captureTime, coordinate, place, title, caption, keywords, credit, remoteSizeBytes, unzonedCaptureInstant
    }
}

/// Attachments that can carry capture metadata. This is the one rule both
/// the capture worker's store query and reply-readiness use, so a row that
/// readiness waits on is always a row the worker visits.
public enum CaptureMediaKind: Sendable, Equatable {
    case image
    case movie

    /// MIME families the worker's store query fetches; mirrored by
    /// `CaptureMetadataWorker.candidateDescriptor`.
    public static func isQueriedMIMEFamily(_ mimeType: String) -> Bool {
        let mime = mimeType.lowercased()
        return mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime == "application/octet-stream"
    }

    public static func of(mimeType: String, filename: String) -> CaptureMediaKind? {
        guard isQueriedMIMEFamily(mimeType) else { return nil }
        let mime = mimeType.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") || imageExtensions.contains(ext) { return .image }
        if mime.hasPrefix("video/") || movieExtensions.contains(ext) { return .movie }
        return nil
    }

    private static let imageExtensions: Set<String> = [
        "avif", "dng", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]
    private static let movieExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp"]
}

public extension Attachment {
    /// A photo or video never yet visited for capture metadata. Reply
    /// preparation waits for this first visit so a prepared reply sees the
    /// capture time and place; a deferred or stale row (already attempted,
    /// or named in another reading language) does not hold replies back.
    var awaitsFirstCaptureMetadataVisit: Bool {
        CaptureMediaKind.of(mimeType: mimeType, filename: filename) != nil
            && captureMetadataVersion == nil
            && (captureMetadataAttemptCount ?? 0) == 0
    }
}
