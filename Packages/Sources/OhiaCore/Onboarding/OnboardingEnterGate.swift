/// Pure decision: should the onboarding "Enter" button be enabled?
///
/// Enable only once the constellation has drawn at least one visible node.
public enum OnboardingEnterGate {
    public static func isEnabled(hasRenderedNode: Bool) -> Bool {
        hasRenderedNode
    }
}
