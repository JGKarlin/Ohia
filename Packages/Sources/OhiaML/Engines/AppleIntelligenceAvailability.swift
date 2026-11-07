import Foundation
import FoundationModels

public enum AppleImageAnalysisTier: String, Sendable, Equatable {
    case legacy
    case multimodal
}

public enum AppleIntelligenceModelGeneration: Sendable, Equatable {
    case macOS26Initial
    case macOS26Point4
    case macOS27

    public var displayName: String {
        switch self {
        case .macOS26Initial:
            return "macOS 26.0-26.3 generation"
        case .macOS26Point4:
            return "macOS 26.4 generation"
        case .macOS27:
            return "macOS 27 generation"
        }
    }
}

public struct AppleIntelligenceModelProfile: Sendable, Equatable {
    public static let legacyParserVersion = "apple-image-analysis-legacy-v5"
    public static let multimodalParserVersion = "apple-image-analysis-multimodal-v4"

    public let availability: AppleIntelligenceAvailability.State
    public let generation: AppleIntelligenceModelGeneration
    public let supportsVision: Bool
    public let supportsToolCalling: Bool
    public let supportsGuidedGeneration: Bool
    public let imageAnalysisTier: AppleImageAnalysisTier

    public var parserVersion: String {
        switch imageAnalysisTier {
        case .legacy:
            return Self.legacyParserVersion
        case .multimodal:
            return Self.multimodalParserVersion
        }
    }

    public static func resolve(
        osVersion: OperatingSystemVersion,
        availability: AppleIntelligenceAvailability.State,
        supportsVision: Bool,
        supportsToolCalling: Bool,
        supportsGuidedGeneration: Bool
    ) -> Self {
        let generation: AppleIntelligenceModelGeneration
        if osVersion.majorVersion >= 27 {
            generation = .macOS27
        } else if osVersion.majorVersion == 26, osVersion.minorVersion >= 4 {
            generation = .macOS26Point4
        } else {
            generation = .macOS26Initial
        }

        let imageAnalysisTier: AppleImageAnalysisTier = if
            osVersion.majorVersion >= 27,
            availability.isAvailable,
            supportsVision,
            supportsToolCalling,
            supportsGuidedGeneration
        {
            .multimodal
        } else {
            .legacy
        }

        return Self(
            availability: availability,
            generation: generation,
            supportsVision: supportsVision,
            supportsToolCalling: supportsToolCalling,
            supportsGuidedGeneration: supportsGuidedGeneration,
            imageAnalysisTier: imageAnalysisTier
        )
    }

    public static func current(
        model: SystemLanguageModel = .default,
        processInfo: ProcessInfo = .processInfo
    ) -> Self {
        let availability = AppleIntelligenceAvailability.current(model: model)

#if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            let capabilities = model.capabilities
            return resolve(
                osVersion: processInfo.operatingSystemVersion,
                availability: availability,
                supportsVision: capabilities.contains(.vision),
                supportsToolCalling: capabilities.contains(.toolCalling),
                supportsGuidedGeneration: capabilities.contains(.guidedGeneration)
            )
        }
#endif

        return resolve(
            osVersion: processInfo.operatingSystemVersion,
            availability: availability,
            supportsVision: false,
            supportsToolCalling: false,
            supportsGuidedGeneration: false
        )
    }
}

public enum AppleIntelligenceAvailability {
    public enum State: String, CaseIterable, Sendable, Equatable {
        case available
        case appleIntelligenceNotEnabled
        case deviceNotEligible
        case modelNotReady
        case unknown

        public var isAvailable: Bool {
            self == .available
        }
    }

    public static func current(model: SystemLanguageModel = .default) -> State {
        map(model.availability)
    }

    public static func map(_ availability: SystemLanguageModel.Availability) -> State {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .deviceNotEligible:
                return .deviceNotEligible
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .unknown
            }
        @unknown default:
            return .unknown
        }
    }
}
