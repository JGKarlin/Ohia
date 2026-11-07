import Foundation

public enum TriageVerdictJSON {
    private struct RequiredFields: Decodable {
        let isActionable: Bool
        let requiresConfirmation: Bool
    }

    public static func hasRequiredBooleanFields(_ value: String?) -> Bool {
        guard let value,
              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let data = value.data(using: .utf8) else {
            return false
        }
        return (try? JSONDecoder().decode(RequiredFields.self, from: data)) != nil
    }
}
