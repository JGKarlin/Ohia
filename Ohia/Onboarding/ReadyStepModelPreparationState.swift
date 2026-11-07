import OhiaML

/// Segmented model choice on the Ready step: the two recommended tiers plus
/// the opt-in Ultra tier when this Mac can run it. Mirrors Model Settings,
/// where Ultra targets the primary opt-in model and persists as Quality mode
/// plus the opt-in model ID.
enum ReadyStepModelSelection: Hashable {
    case mode(GenerationModelMode)
    case ultra

    var displayName: String {
        switch self {
        case .mode(let mode):
            return mode.displayName
        case .ultra:
            return "Ultra"
        }
    }

    /// The mode persisted for this selection. Ultra has no mode of its own —
    /// like Model Settings it falls back to `.quality`, and the opt-in model
    /// ID is what actually distinguishes it.
    var persistedMode: GenerationModelMode {
        switch self {
        case .mode(let mode):
            return mode
        case .ultra:
            return .quality
        }
    }

    /// The segments the Ready step offers: Performance and Quality always,
    /// Ultra only when this Mac has a memory-compatible opt-in model — the
    /// same gate Model Settings applies to its Ultra tab.
    static func availableSegments(hasOptInModel: Bool) -> [ReadyStepModelSelection] {
        var segments = GenerationModelMode.allCases.map(ReadyStepModelSelection.mode)
        if hasOptInModel {
            segments.append(.ultra)
        }
        return segments
    }
}

struct ReadyStepModelPreparationState: Equatable {
    var selectedSegment: ReadyStepModelSelection = .mode(.performance)
    private(set) var hasRequestedDownload = false

    var shouldShowDownloadProgress: Bool {
        hasRequestedDownload
    }

    mutating func requestDownload() {
        hasRequestedDownload = true
    }
}
