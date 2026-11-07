import Foundation

/// Semantic folder role used by deletion-sync logic. Gmail's `\All` folder is
/// the only place where a vanished UID represents a real message deletion.
public enum IMAPFolderRole: String, Sendable, Equatable, CaseIterable {
    case inbox
    case gmailAll
    case other
}

/// Classify a folder by name and RFC 6154 special-use attributes.
public func classifyIMAPFolderRole(folder: String, attributes: [String]) -> IMAPFolderRole {
    let normalizedAttributes = Set(attributes.map { $0.uppercased() })
    if normalizedAttributes.contains("\\ALL") { return .gmailAll }
    if normalizedAttributes.contains("\\INBOX") { return .inbox }

    let normalizedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if normalizedFolder == "INBOX" { return .inbox }
    if normalizedFolder == "[GMAIL]/ALL MAIL" || normalizedFolder == "[GOOGLE MAIL]/ALL MAIL" {
        return .gmailAll
    }
    return .other
}
