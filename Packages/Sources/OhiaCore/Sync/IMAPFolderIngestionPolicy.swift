import Foundation

public enum IMAPFolderIngestionPolicy {
    private static let junkLeafNames: Set<String> = [
        "BULK MAIL",
        "JUNK",
        "JUNK EMAIL",
        "SPAM",
    ]

    private static let trashLeafNames: Set<String> = [
        "BIN",
        "DELETED",
        "DELETED ITEMS",
        "DELETED MESSAGES",
        "TRASH",
    ]

    private static let excludedLeafNames: Set<String> = junkLeafNames.union(trashLeafNames)

    private static let draftsLeafNames: Set<String> = [
        "DRAFT",
        "DRAFT ITEMS",
        "DRAFT MESSAGES",
        "DRAFTS",
    ]

    public static func isExcluded(folderName: String, attributes: [String]) -> Bool {
        let normalizedAttributes = Set(attributes.map { $0.uppercased() })
        if normalizedAttributes.contains("\\TRASH") || normalizedAttributes.contains("\\JUNK") {
            return true
        }

        return excludedLeafNames.contains(normalizedLeafName(folderName))
    }

    public static func isSyncEligible(folderName: String, attributes: [String]) -> Bool {
        let normalizedAttributes = Set(attributes.map { $0.uppercased() })
        return !normalizedAttributes.contains("\\NOSELECT")
            && !isExcluded(folderName: folderName, attributes: attributes)
    }

    public static func isCorpusEligible(folderName: String, attributes: [String]) -> Bool {
        isSyncEligible(folderName: folderName, attributes: attributes)
            && !isDraftsFolder(folderName: folderName, attributes: attributes)
    }

    public static func isDraftsFolder(folderName: String, attributes: [String]) -> Bool {
        let normalizedAttributes = Set(attributes.map { $0.uppercased() })
        if normalizedAttributes.contains("\\DRAFTS") {
            return true
        }
        return draftsLeafNames.contains(normalizedLeafName(folderName))
    }

    public static func matchesJunkLeafName(_ folderName: String) -> Bool {
        junkLeafNames.contains(normalizedLeafName(folderName))
    }

    public static func matchesTrashLeafName(_ folderName: String) -> Bool {
        trashLeafNames.contains(normalizedLeafName(folderName))
    }

    private static func normalizedLeafName(_ folderName: String) -> String {
        let normalizedName = folderName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return normalizedName
            .split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == "." })
            .last
            .map(String.init) ?? normalizedName
    }
}
