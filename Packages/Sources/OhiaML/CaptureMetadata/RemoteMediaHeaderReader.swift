import Foundation
import ImageIO

public enum RemoteMediaFetchError: Error, Equatable, Sendable {
    /// The link no longer serves the file (expired, removed, forbidden).
    case unavailable(String)
    /// Offline, timed out, or a server-side failure worth retrying.
    case transient(String)
    /// The file is not a readable QuickTime / MP4 movie within our limits.
    case unsupported(String)
}

public struct RemoteRangeResponse: Sendable, Equatable {
    public let data: Data
    /// Full resource length from `Content-Range`, when the server states it.
    public let totalLength: Int?

    public init(data: Data, totalLength: Int?) {
        self.data = data
        self.totalLength = totalLength
    }
}

/// Loads at most `range.count` bytes starting at `range.lowerBound`.
public typealias RemoteRangeLoader = @Sendable (_ url: URL, _ range: Range<Int>) async throws -> RemoteRangeResponse

public struct RemoteMediaHeaderResult: Sendable, Equatable {
    public let reading: CaptureMetadataReading?
    public let totalBytes: Int?
}

/// Reads a remote movie's metadata without downloading it: walks the
/// top-level ISO-BMFF boxes with HTTP range requests until it finds `moov`
/// (at the start of iPhone recordings, at the end of many others), then
/// parses `ftyp` + `moov` with AVFoundation from a temporary file.
public enum RemoteMovieHeaderReader {
    static let windowBytes = 64 * 1024
    static let maxMovieBoxBytes = 16 * 1024 * 1024
    static let maxRequests = 32
    /// Upper bound for any offset when the server states no length. Box
    /// sizes come from untrusted bytes, so every bound is checked by
    /// subtraction against this (or the real length) before adding.
    static let maxAddressableBytes = 1 << 40
    /// Box types a QuickTime / ISO-BMFF file can open with.
    static let leadingBoxTypes: Set<String> = ["ftyp", "moov", "mdat", "wide", "free", "skip", "pnot", "uuid", "junk"]

    public static func read(
        url: URL,
        filename: String,
        mimeType: String,
        loader: RemoteRangeLoader
    ) async throws -> RemoteMediaHeaderResult {
        let header = try await movieHeader(url: url, loader: loader)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohia-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        // Never use the untrusted attachment filename as a path component.
        let fileURL = directory.appendingPathComponent("header.\(fileExtension(filename: filename, mimeType: mimeType))")
        try (header.ftyp + header.moov).write(to: fileURL, options: .atomic)
        let reading = try await CaptureMetadataReader.readMovie(at: fileURL)
        return RemoteMediaHeaderResult(reading: reading, totalBytes: header.totalBytes)
    }

    struct MovieHeader: Equatable {
        let ftyp: Data
        let moov: Data
        let totalBytes: Int?
    }

    static func movieHeader(url: URL, loader: RemoteRangeLoader) async throws -> MovieHeader {
        var offset = 0
        var total: Int?
        var ftyp = Data()
        for _ in 0..<maxRequests {
            if let total, offset >= total { break }
            try Task.checkCancellation()
            let response = try await loader(url, offset..<(offset + windowBytes))
            total = total ?? response.totalLength
            let window = response.data
            guard window.count >= 8 else { break }

            var cursor = 0
            var nextOffset: Int?
            while cursor + 8 <= window.count {
                let size32 = readUInt32(window, at: cursor)
                let typeBytes = window.subdata(in: window.startIndex + cursor + 4 ..< window.startIndex + cursor + 8)
                guard typeBytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
                    throw RemoteMediaFetchError.unsupported("Not a QuickTime or MP4 file")
                }
                let type = String(decoding: typeBytes, as: UTF8.self)
                let boxStart = offset + cursor
                if boxStart == 0, !Self.leadingBoxTypes.contains(type) {
                    throw RemoteMediaFetchError.unsupported("Not a QuickTime or MP4 file")
                }
                // Bytes this box may span: to the end of the file, never past
                // the addressable bound. `boxStart` never exceeds the bound
                // because every earlier advance was checked against it.
                let fileEnd = min(total ?? maxAddressableBytes, maxAddressableBytes)
                guard boxStart < fileEnd else {
                    throw RemoteMediaFetchError.unsupported("Box starts past the end of the file")
                }
                let remaining = fileEnd - boxStart
                var headerLength = 8
                let size: Int
                if size32 == 1 {
                    guard window.count - cursor >= 16 else { break }
                    let size64 = readUInt64(window, at: cursor + 8)
                    guard size64 <= UInt64(remaining) else {
                        throw RemoteMediaFetchError.unsupported("Box size out of range")
                    }
                    size = Int(size64)
                    headerLength = 16
                } else if size32 == 0 {
                    // Box runs to the end of the file.
                    guard total != nil else { throw RemoteMediaFetchError.unsupported("Open-ended box without a length") }
                    size = remaining
                } else {
                    size = Int(size32)
                }
                guard size >= headerLength, size <= remaining else {
                    throw RemoteMediaFetchError.unsupported("Malformed box")
                }
                let fitsInWindow = size <= window.count - cursor

                if type == "moov" {
                    guard size <= maxMovieBoxBytes else {
                        throw RemoteMediaFetchError.unsupported("Movie header larger than \(maxMovieBoxBytes) bytes")
                    }
                    let moov: Data
                    if fitsInWindow {
                        moov = window.subdata(in: window.startIndex + cursor ..< window.startIndex + cursor + size)
                    } else {
                        moov = try await loader(url, boxStart..<(boxStart + size)).data
                    }
                    guard moov.count == size else {
                        throw RemoteMediaFetchError.transient("Short read of movie header")
                    }
                    return MovieHeader(ftyp: ftyp, moov: moov, totalBytes: total)
                }
                if type == "ftyp", ftyp.isEmpty, size <= 4096, fitsInWindow {
                    ftyp = window.subdata(in: window.startIndex + cursor ..< window.startIndex + cursor + size)
                }
                if fitsInWindow {
                    cursor += size
                } else {
                    nextOffset = boxStart + size
                    break
                }
            }
            // A box header straddling the window end is re-read from its start.
            let advanced = nextOffset ?? (offset + cursor)
            guard advanced > offset else {
                throw RemoteMediaFetchError.unsupported("Box walk made no progress")
            }
            offset = advanced
        }
        throw RemoteMediaFetchError.unsupported("No movie header found")
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[base + $1]) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        return (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(data[base + $1]) }
    }

    private static func fileExtension(filename: String, mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "video/quicktime": return "mov"
        case "video/mp4": return "mp4"
        case "video/x-m4v": return "m4v"
        case "video/3gpp": return "3gp"
        default:
            let ext = (filename as NSString).pathExtension.lowercased()
            return ["mov", "mp4", "m4v", "3gp"].contains(ext) ? ext : "mov"
        }
    }
}

/// Reads a remote photo's metadata from its first bytes: JPEG APP1/EXIF and
/// HEIC `meta` sit at the start of the file, and ImageIO parses properties
/// from a truncated buffer.
public enum RemoteImageHeaderReader {
    static let headerBytes = 256 * 1024

    public static func read(
        url: URL,
        loader: RemoteRangeLoader
    ) async throws -> RemoteMediaHeaderResult {
        let response = try await loader(url, 0..<headerBytes)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !response.data.isEmpty,
              let source = CGImageSourceCreateWithData(response.data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            throw RemoteMediaFetchError.unsupported("Not a readable image")
        }
        let reading = CaptureMetadataReader.readImage(
            properties: properties,
            xmp: CGImageSourceCopyMetadataAtIndex(source, 0, options)
        )
        return RemoteMediaHeaderResult(reading: reading, totalBytes: response.totalLength)
    }
}

/// Range loader over an ephemeral, cookieless `URLSession`. Streams the body
/// and stops at the requested length, so a server that ignores `Range` and
/// answers `200` with the whole file still costs only the window. Only URLs
/// (and redirect targets) that `allowing` accepts are ever requested.
public enum URLSessionRangeLoader {
    public static func loader(allowing: @escaping @Sendable (URL) -> Bool) -> RemoteRangeLoader {
        { url, range in try await load(url: url, range: range, allowing: allowing) }
    }

    /// Refuses any redirect whose target the host policy rejects; the
    /// refused 3xx then surfaces as `unavailable`.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        let allowing: @Sendable (URL) -> Bool

        init(allowing: @escaping @Sendable (URL) -> Bool) {
            self.allowing = allowing
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let url = request.url, allowing(url) else { return nil }
            return request
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func load(
        url: URL,
        range: Range<Int>,
        allowing: @escaping @Sendable (URL) -> Bool
    ) async throws -> RemoteRangeResponse {
        guard allowing(url) else {
            throw RemoteMediaFetchError.unavailable("Untrusted download host")
        }
        guard !range.isEmpty else { return RemoteRangeResponse(data: Data(), totalLength: nil) }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: RedirectPolicy(allowing: allowing))
        } catch let error as URLError {
            throw classify(error)
        }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteMediaFetchError.transient("Non-HTTP response")
        }
        let total: Int?
        switch http.statusCode {
        case 206:
            total = contentRangeTotal(http.value(forHTTPHeaderField: "Content-Range"))
        case 200:
            // The server ignored Range; its body starts at byte 0.
            guard range.lowerBound == 0 else {
                throw RemoteMediaFetchError.unsupported("Server does not support range requests")
            }
            total = http.expectedContentLength >= 0 ? Int(http.expectedContentLength) : nil
        case 416:
            return RemoteRangeResponse(
                data: Data(),
                totalLength: contentRangeTotal(http.value(forHTTPHeaderField: "Content-Range"))
            )
        case 408, 425, 429, 500...599:
            throw RemoteMediaFetchError.transient("HTTP \(http.statusCode)")
        default:
            throw RemoteMediaFetchError.unavailable("HTTP \(http.statusCode)")
        }
        var data = Data()
        data.reserveCapacity(min(range.count, 1 << 20))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= range.count { break }
            }
        } catch let error as URLError {
            throw classify(error)
        }
        return RemoteRangeResponse(data: data, totalLength: total)
    }

    static func contentRangeTotal(_ header: String?) -> Int? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    private static func classify(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .badURL, .unsupportedURL, .fileDoesNotExist, .noPermissionsToReadFile:
            return RemoteMediaFetchError.unavailable(error.localizedDescription)
        default:
            return RemoteMediaFetchError.transient(error.localizedDescription)
        }
    }
}
