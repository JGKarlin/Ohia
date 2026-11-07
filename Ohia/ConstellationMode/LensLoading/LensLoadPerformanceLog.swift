import Foundation
import OSLog
import OhiaCore

/// Aggregate-only lens timing. Deliberately excludes message IDs, account IDs,
/// filter fingerprints, subjects, addresses, paths, and query text.
enum LensLoadPerformanceLog {
    nonisolated static let logger = Logger(
        subsystem: "com.ohia.app",
        category: "LensLoading"
    )

    nonisolated static func start() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    nonisolated static func record(
        lens: FrameKey,
        stage: String,
        startedAt: UInt64? = nil,
        candidateCount: Int = 0,
        resultCount: Int = 0,
        cache: String = "none"
    ) {
        let elapsedMilliseconds: Int
        if let startedAt {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
            elapsedMilliseconds = Int(elapsed / 1_000_000)
        } else {
            elapsedMilliseconds = 0
        }
        logger.notice(
            "lens_load lens=\(lens.rawValue, privacy: .public) stage=\(stage, privacy: .public) elapsed_ms=\(elapsedMilliseconds, privacy: .public) candidates=\(candidateCount, privacy: .public) results=\(resultCount, privacy: .public) cache=\(cache, privacy: .public)"
        )
    }
}
