import Foundation

public enum InitialIMAPImportCompletionEvaluator {
    public struct Folder: Sendable, Equatable {
        public let name: String
        public let total: Int?
        public let remaining: Int?
        public let snapshotUIDValidity: UInt32?
        public let terminalExclusionReason: String?

        public init(
            name: String,
            total: Int?,
            remaining: Int?,
            snapshotUIDValidity: UInt32?,
            terminalExclusionReason: String?
        ) {
            self.name = name
            self.total = total
            self.remaining = remaining
            self.snapshotUIDValidity = snapshotUIDValidity
            self.terminalExclusionReason = terminalExclusionReason
        }
    }

    public static func isComplete(
        requiredFolderNames: Set<String>,
        folders: [Folder]
    ) -> Bool {
        guard requiredFolderNames.isEmpty == false else { return false }
        let foldersByName = Dictionary(grouping: folders, by: \.name)
        return requiredFolderNames.allSatisfy { requiredName in
            guard let matching = foldersByName[requiredName], matching.isEmpty == false else {
                return false
            }
            return matching.allSatisfy(isAuthoritativelyComplete)
        }
    }

    private static func isAuthoritativelyComplete(_ folder: Folder) -> Bool {
        if let reason = folder.terminalExclusionReason,
           reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        guard folder.snapshotUIDValidity != nil,
              let total = folder.total,
              let remaining = folder.remaining else {
            return false
        }
        return total >= 0 && remaining == 0
    }
}
