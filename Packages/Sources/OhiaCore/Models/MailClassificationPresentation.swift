import Foundation

public enum MailClassificationFacetLabel {
    /// Prevents semantic topic extraction from duplicating a shared purpose
    /// category without introducing synonym or keyword inference.
    public static func isCanonical(_ raw: String) -> Bool {
        let candidate = normalized(raw)
        let labels = MailPurpose.allCases.map { [$0.rawValue, $0.displayLabel] }
        return labels.joined().contains { normalized($0) == candidate }
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

public extension MailPurpose {
    var displayLabel: String {
        switch self {
        case .correspondence: "Correspondence"
        case .announcement: "Announcement"
        case .receipt: "Receipt"
        case .promotion: "Promotion"
        case .newsletter: "Newsletter"
        case .verificationCode: "Verification code"
        case .notification: "Notification"
        case .security: "Security"
        case .shipping: "Shipping"
        case .travel: "Travel"
        case .finance: "Finance"
        case .calendar: "Scheduling"
        case .support: "Support"
        case .legal: "Legal"
        case .socialActivity: "Social activity"
        case .other: "Other"
        }
    }

    var systemImageName: String {
        switch self {
        case .correspondence: "bubble.left.and.bubble.right"
        case .announcement: "megaphone"
        case .receipt: "doc.text"
        case .promotion: "tag"
        case .newsletter: "newspaper"
        case .verificationCode: "key.fill"
        case .notification: "bell"
        case .security: "lock.shield"
        case .shipping: "shippingbox"
        case .travel: "airplane"
        case .finance: "banknote"
        case .calendar: "calendar"
        case .support: "lifepreserver"
        case .legal: "scale.3d"
        case .socialActivity: "person.2"
        case .other: "ellipsis.circle"
        }
    }

    var notificationIcon: String {
        switch self {
        case .correspondence: "💬"
        case .announcement, .promotion: "📣"
        case .receipt: "🧾"
        case .newsletter: "📰"
        case .verificationCode: "🔑"
        case .notification: "🔔"
        case .security: "🔒"
        case .shipping: "📦"
        case .travel: "✈️"
        case .finance: "💰"
        case .calendar: "📅"
        case .support: "🛟"
        case .legal: "⚖️"
        case .socialActivity: "👥"
        case .other: "✉️"
        }
    }
}
