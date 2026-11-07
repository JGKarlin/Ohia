// EngineSelector.swift
// Selects between the primary MLX engine and an optional fallback engine.

import Foundation

/// Manages selection between a primary (MLX) engine and an optional fallback engine.
///
/// The DraftOrchestrator and TrainingOrchestrator interact only with the
/// TrainingEngine protocol — EngineSelector handles the switching logic.
public final class EngineSelector: @unchecked Sendable {

    // MARK: - Properties

    /// The primary MLX-based training engine.
    public let primary: any TrainingEngine

    /// An optional fallback engine (e.g. Apple Foundation Models), nil on macOS < 26.
    public let fallback: (any TrainingEngine)?

    /// When true, the scheduler has requested that the primary engine be paused
    /// (e.g. due to battery pressure or thermal state). The fallback is used instead
    /// when available.
    public var forcePausePrimary: Bool = false

    // MARK: - Init

    public init(primary: any TrainingEngine, fallback: (any TrainingEngine)?) {
        self.primary = primary
        self.fallback = fallback
    }

    // MARK: - Selection Logic

    /// The engine that should be used right now.
    ///
    /// Selection rules (in priority order):
    /// 1. Primary when loaded and not force-paused.
    /// 2. Fallback when primary is paused or not loaded, and fallback is loaded.
    /// 3. Primary when paused but fallback is unavailable/not loaded (still better than nothing).
    /// 4. nil when nothing is usable.
    public var activeEngine: (any TrainingEngine)? {
        if primary.isModelLoaded && !forcePausePrimary {
            return primary
        }

        if let fallback, fallback.isModelLoaded {
            return fallback
        }

        // Paused but no usable fallback — prefer primary over nil if it is loaded.
        if primary.isModelLoaded {
            return primary
        }

        return nil
    }

    /// True only when the primary engine has a model loaded and is ready to train.
    public var canTrain: Bool {
        primary.isModelLoaded
    }

    /// The primary engine if its model is loaded, otherwise nil.
    public var trainingEngine: (any TrainingEngine)? {
        primary.isModelLoaded ? primary : nil
    }

    /// Human-readable status suitable for display in an activity strip.
    public var statusDescription: String {
        switch (primary.isModelLoaded, forcePausePrimary, fallback?.isModelLoaded) {
        case (true, false, _):
            return "MLX engine active"
        case (true, true, .some(true)):
            return "Fallback engine active (primary paused)"
        case (true, true, _):
            return "MLX engine active (paused, no fallback)"
        case (false, _, .some(true)):
            return "Fallback engine active (primary not loaded)"
        default:
            return "No engine available"
        }
    }
}
