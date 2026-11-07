import Foundation

/// Returns an account only when every source is attributable to the same one.
/// Mixed, missing, and empty source sets stay neutral in ActivityStrip.
public enum SummarizationAccountResolver {
    public static func singleAccountID(in accountIDs: [UUID?]) -> UUID? {
        guard let firstAccountID = accountIDs.first, let firstAccountID else { return nil }
        guard accountIDs.allSatisfy({ $0 == firstAccountID }) else { return nil }
        return firstAccountID
    }
}
