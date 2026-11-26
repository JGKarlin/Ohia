import Foundation

/// The Sparkle feed and EdDSA public key read from the built Info.plist.
///
/// `SUFeedURL` and `SUPublicEDKey` expand from build settings that are empty
/// in the project; only the release script supplies real values. Parsing
/// returns `nil` for anything else, so Debug, public-source and plain Release
/// builds never start an updater.
///
/// The feed is https for any host, or plain http only for `localhost`, which
/// the update rehearsal serves from (App Transport Security blocks plain http
/// to IP addresses). Sparkle uses `SUFeedURL` as written, stripping only
/// quotes, so a feed that would need whitespace trimmed is refused. Sparkle
/// trims whitespace from `SUPublicEDKey` before decoding it, and so does this.
struct OhiaUpdateConfiguration: Equatable {
    let feedURL: URL
    let publicEDKey: String

    private static let publicKeyByteCount = 32
    private static let plainHTTPHost = "localhost"

    static func from(infoDictionary: [String: Any]) -> OhiaUpdateConfiguration? {
        guard let feed = infoDictionary["SUFeedURL"] as? String,
              feed.trimmingCharacters(in: .whitespacesAndNewlines) == feed,
              let key = (infoDictionary["SUPublicEDKey"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !feed.isEmpty, !key.isEmpty,
              !feed.contains("$("), !key.contains("$("),
              let url = URL(string: feed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false), !host.isEmpty,
              scheme == "https" || (scheme == "http" && host == plainHTTPHost),
              let keyData = Data(base64Encoded: key),
              keyData.count == publicKeyByteCount
        else { return nil }
        return OhiaUpdateConfiguration(feedURL: url, publicEDKey: key)
    }

    /// The configuration of the running app bundle, or `nil` when this build
    /// carries no real feed and key.
    static var current: OhiaUpdateConfiguration? {
        from(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }
}
