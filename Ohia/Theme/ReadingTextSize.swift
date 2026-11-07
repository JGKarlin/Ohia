import Foundation
import SwiftUI

/// User-facing scale for substantive reading content. The labels deliberately
/// avoid point sizes: the preference describes the reading experience while
/// each surface retains its role-appropriate base typography.
enum ReadingTextSize: String, CaseIterable, Identifiable {
    static let storageKey = "readingTextSize"
    static let defaultPreference: ReadingTextSize = .standard

    case smallest
    case smaller
    case standard
    case larger
    case largest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smallest: "Smallest"
        case .smaller: "Smaller"
        case .standard: "Standard"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    /// Canonical body-prose base (e.g. locked-email card body at Standard).
    static let canonicalBodyBase: CGFloat = 12.5

    /// Largest body-prose target for the canonical reader surface.
    static let largestBodyPointSize: CGFloat = 18.75

    /// The scale is intentionally nonlinear at the large end. Larger steps up
    /// gently from Standard; Largest lands at 18.75 pt on the canonical body base.
    /// The two smaller settings remain useful without shrinking prose below 10 pt.
    var scale: CGFloat {
        switch self {
        case .smallest: 0.80
        case .smaller: 0.90
        case .standard: 1.00
        case .larger: 1.20
        case .largest: Self.largestBodyPointSize / Self.canonicalBodyBase
        }
    }

    static func resolved(rawValue: String?) -> ReadingTextSize {
        rawValue.flatMap(ReadingTextSize.init(rawValue:)) ?? defaultPreference
    }

    static func stored(in defaults: UserDefaults = .standard) -> ReadingTextSize {
        resolved(rawValue: defaults.string(forKey: storageKey))
    }

    func pointSize(
        base: CGFloat,
        minimum: CGFloat = 10,
        maximumScale: CGFloat? = nil
    ) -> CGFloat {
        let appliedScale = maximumScale.map { min(scale, $0) } ?? scale
        return max(minimum, base * appliedScale)
    }

    func font(
        base: CGFloat,
        weight: Font.Weight = .regular,
        maximumScale: CGFloat? = nil
    ) -> Font {
        .system(
            size: pointSize(base: base, maximumScale: maximumScale),
            weight: weight
        )
    }

    func spacing(_ base: CGFloat, maximumScale: CGFloat? = nil) -> CGFloat {
        let appliedScale = maximumScale.map { min(scale, $0) } ?? scale
        return base * appliedScale
    }
}

extension EnvironmentValues {
    @Entry var readingTextSize: ReadingTextSize = .standard
}

private struct ReadingTextSizePreferenceModifier: ViewModifier {
    @AppStorage(ReadingTextSize.storageKey)
    private var rawValue = ReadingTextSize.defaultPreference.rawValue

    func body(content: Content) -> some View {
        content.environment(
            \.readingTextSize,
            ReadingTextSize.resolved(rawValue: rawValue)
        )
    }
}

extension View {
    func applyReadingTextSizePreference() -> some View {
        modifier(ReadingTextSizePreferenceModifier())
    }
}
