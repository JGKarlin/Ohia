import CryptoKit
import Foundation

/// Content-derived identity for transient Projects presentation artifacts.
/// These values are rebuilt from committed mail/project inputs, so random
/// UUIDs would make equal computations compare unequal on every refresh.
enum DeterministicProjectArtifactID {
    static func make(kind: String, components: [String]) -> UUID {
        let canonical = ([kind] + components)
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        let hex = SHA256.hash(data: Data(canonical.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        let first = String(hex.prefix(8))
        let second = String(hex.dropFirst(8).prefix(4))
        let third = String(hex.dropFirst(12).prefix(4))
        let fourth = String(hex.dropFirst(16).prefix(4))
        let fifth = String(hex.dropFirst(20).prefix(12))
        let uuidString = "\(first)-\(second)-\(third)-\(fourth)-\(fifth)"
        return UUID(uuidString: uuidString) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    static func date(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }

    static func double(_ value: Double) -> String {
        String(value.bitPattern, radix: 16)
    }
}
