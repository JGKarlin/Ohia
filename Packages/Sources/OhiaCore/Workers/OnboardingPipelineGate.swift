import Foundation

public enum OnboardingPipelineGate {
    public static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    public static let hasCompletedFirstIngestionKey = "hasCompletedFirstIngestion"
    public static let hasReachedWitnessPanelKey = "hasReachedOnboardingWitnessPanel"
    public static let hasRequestedModelPreparationKey = "hasRequestedOnboardingModelPreparation"

    /// Allows non-visual analysis and model preparation before onboarding
    /// completes. Layout placement and IMAP stay behind `isReleased` so the
    /// witness panel owns the live reveal boundary.
    public static func allowsPreparation(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: hasCompletedOnboardingKey)
            || defaults.bool(forKey: hasRequestedModelPreparationKey)
    }

    /// Releases visible constellation placement and post-onboarding work.
    public static func isReleased(defaults: UserDefaults) -> Bool {
        guard defaults.bool(forKey: hasCompletedOnboardingKey) else { return false }
        return defaults.bool(forKey: hasCompletedFirstIngestionKey)
            || defaults.bool(forKey: hasReachedWitnessPanelKey)
    }

    public static func allowsQwenModelLoad(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: hasCompletedOnboardingKey)
    }

    public static func isWitnessActivityActive(defaults: UserDefaults) -> Bool {
        isWitnessActivityActive(
            hasCompletedOnboarding: defaults.bool(forKey: hasCompletedOnboardingKey),
            hasReachedWitnessPanel: defaults.bool(forKey: hasReachedWitnessPanelKey),
            hasCompletedFirstIngestion: defaults.bool(forKey: hasCompletedFirstIngestionKey)
        )
    }

    public static func isWitnessActivityActive(
        hasCompletedOnboarding: Bool,
        hasReachedWitnessPanel: Bool,
        hasCompletedFirstIngestion: Bool
    ) -> Bool {
        hasCompletedOnboarding
            && hasReachedWitnessPanel
            && !hasCompletedFirstIngestion
    }

    public static func sharedDefaults() -> UserDefaults {
        OhiaSharedDefaults.store
    }
}
