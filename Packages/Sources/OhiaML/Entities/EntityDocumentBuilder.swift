import Foundation
import OhiaCore

public enum EntityDocumentBuilder {
    public static let attachmentSummaryCap = 600

    public static func buildCorrespondentDocument(
        displayName: String,
        emailAddress: String,
        profile: CorrespondentProfile,
        firstSeenAt: Date,
        lastSeenAt: Date
    ) -> String {
        [
            "Correspondent: \(displayName) <\(emailAddress.lowercased())>",
            formatRoleDistribution(profile.relationshipDistribution),
            formatTopicList(profile.topTopics),
            formatLanguageList(profile.languagePreferences),
            "Familiarity: \(formatScore(profile.familiarityScore))  (over \(profile.messageCount) messages)",
            "First contact: \(formatYMD(firstSeenAt))  ·  Last contact: \(formatYMD(lastSeenAt))"
        ].joined(separator: "\n")
    }

    public static func buildAttachmentDocument(
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        parentSubject: String,
        parentSenderDisplay: String,
        parentSentAt: Date,
        coAttachmentFilenames: [String],
        extractedTextSummary: String,
        messageEvidenceDigest: String? = nil
    ) -> String {
        var lines = [
            "Attachment: \(filename)",
            "Content type: \(mimeType)  ·  Size: \(formatBytes(sizeBytes))",
            "From message: \"\(parentSubject)\" by \(parentSenderDisplay) (\(formatYMD(parentSentAt)))"
        ]
        if !coAttachmentFilenames.isEmpty {
            lines.append("Co-attachments on the same message: " + coAttachmentFilenames.joined(separator: ", "))
        }
        if let messageEvidenceDigest,
           !messageEvidenceDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Message evidence bundle:")
            lines.append(String(messageEvidenceDigest.prefix(attachmentSummaryCap * 2)))
        }
        lines.append("Extracted-text summary (first \(attachmentSummaryCap) chars):")
        lines.append(String(extractedTextSummary.prefix(attachmentSummaryCap)))
        return lines.joined(separator: "\n")
    }

    private static func formatRoleDistribution(_ labels: [WeightedLabel]) -> String {
        guard !labels.isEmpty else { return "Role distribution: (none yet)" }
        return "Role distribution: " + labels.prefix(5)
            .map { "\($0.label) (\(formatScore($0.score)))" }
            .joined(separator: ", ")
    }

    private static func formatTopicList(_ topics: [WeightedLabel]) -> String {
        guard !topics.isEmpty else { return "Recent topics: (none yet)" }
        return "Recent topics: " + topics.prefix(5).map(\.label).joined(separator: ", ")
    }

    private static func formatLanguageList(_ languages: [WeightedLabel]) -> String {
        guard !languages.isEmpty else { return "Languages: (unknown)" }
        return "Languages: " + languages.prefix(5).map(\.label).joined(separator: ", ")
    }

    private static func formatScore(_ score: Double) -> String {
        String(format: "%.2f", score)
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    private static func formatYMD(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
