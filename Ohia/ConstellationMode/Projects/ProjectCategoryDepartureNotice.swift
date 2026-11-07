import Foundation
import OhiaCore

enum ProjectCategoryDepartureReason {
    static func categoryName(
        previousClassification: MailClassification?,
        classification: MailClassification?,
        previousCustomCategoryKeys: Set<String>,
        customCategoryKeys: Set<String>,
        catalog: [CustomMailCategoryDescriptor],
        fallback: String?
    ) -> String {
        if previousClassification?.purpose != classification?.purpose,
           let previousPurpose = previousClassification?.purpose {
            return previousPurpose.displayLabel
        }
        if let removedKey = previousCustomCategoryKeys
            .subtracting(customCategoryKeys)
            .sorted()
            .first {
            return catalog.first { $0.key == removedKey }?.displayName ?? removedKey
        }
        return fallback
            ?? previousClassification?.purpose?.displayLabel
            ?? "the configured category"
    }
}

struct ProjectCategoryDepartureNotice: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        case undoChange
        case keepInProject
    }

    let messageID: UUID
    let projectID: UUID
    let projectName: String
    let categoryName: String
    let canUndo: Bool

    var id: String { "\(projectID.uuidString)|\(messageID.uuidString)" }

    var message: String {
        "Removed from \(projectName) because Category is no longer \(categoryName)"
    }

    var actions: [Action] {
        canUndo ? [.undoChange, .keepInProject] : [.keepInProject]
    }
}
