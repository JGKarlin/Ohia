import OhiaML

enum AppleIntelligenceOnboardingGate {
    static func shouldShowStep(for availability: AppleIntelligenceAvailability.State) -> Bool {
        availability != .available
    }
}
