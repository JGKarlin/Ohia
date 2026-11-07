import Foundation

/// Breaks an incoming email into an ordered sequence of `TaskUnit`s that an
/// agent should execute before composing a reply.
public enum TaskDecomposer {

    /// Attachment-signal keywords scanned in the body text.
    private static let attachmentKeywords: [String] = [
        "attached", "see attached", "plans", "document", "report", "file"
    ]

    // MARK: - Public API

    /// Decomposes the incoming email into an ordered array of `TaskUnit`s.
    ///
    /// The returned array always ends with a `.compose` unit. Indices are
    /// sequential starting from 0.
    public static func decompose(
        subject: String,
        bodyText: String,
        dimensions: MessageDimensions,
        triageVerdict: TriageVerdict? = nil,
        hasAttachmentEvidence: Bool = false
    ) -> [TaskUnit] {
        let structuredAction: ActionSpec?
        if let verdict = triageVerdict,
           verdict.isActionable,
           let action = verdict.action,
           !action.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            structuredAction = action
        } else {
            structuredAction = nil
        }

        // Rule 1 – empty body with no structured action → single compose task.
        guard !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || structuredAction != nil else {
            return [TaskUnit(
                description: "Compose reply",
                taskType: .compose,
                searchQuery: "",
                index: 0
            )]
        }

        var units: [TaskUnit] = []
        var hasLocateAttachment = false

        // Rule 2 – Qwen's structured triage action is the primary research
        // signal. Historical dimension tasks remain a fallback for stored
        // messages that predate structured triage.
        if let action = structuredAction {
            var queryParts = [action.summary]
            queryParts.append(contentsOf: action.decisionInputs)
            if let deadline = action.deadline?.displayText {
                queryParts.append(deadline)
            }

            // `ActionKind.review` can refer to inline text or a URL as well as
            // a file. Route it exclusively to attachment search only when the
            // message or its thread actually carries attachment evidence.
            let unitType: TaskUnitType = action.kind == .review && hasAttachmentEvidence
                ? .locateAttachment
                : .search
            if unitType == .locateAttachment {
                hasLocateAttachment = true
            }

            units.append(TaskUnit(
                description: "Handle requested action: \(action.summary)",
                taskType: unitType,
                searchQuery: queryParts.joined(separator: " "),
                index: 0
            ))
        } else if triageVerdict?.action == nil {
            for req in dimensions.tasks where req.confidence >= 0.4 {
                let lower = req.taskType.lowercased()
                let isLocate = lower.contains("review") || lower.contains("find") || lower.contains("locate")
                let unitType: TaskUnitType = isLocate ? .locateAttachment : .search
                let query = req.actionObject ?? req.taskType

                if unitType == .locateAttachment {
                    hasLocateAttachment = true
                }

                units.append(TaskUnit(
                    description: "Handle historical task requirement: \(req.taskType)",
                    taskType: unitType,
                    searchQuery: query,
                    index: 0
                ))
            }
        }

        // Rule 3 – attachment keyword scan.
        if !hasLocateAttachment {
            let lowerBody = bodyText.lowercased()
            let mentionsAttachment = attachmentKeywords.contains { lowerBody.contains($0) }
                && (structuredAction == nil || hasAttachmentEvidence)
            if mentionsAttachment {
                units.append(TaskUnit(
                    description: "Locate referenced attachment",
                    taskType: .locateAttachment,
                    searchQuery: subject,
                    index: 0
                ))
                hasLocateAttachment = true
            }
        }

        // Rule 4 – ensure at least one research task exists.
        if units.isEmpty {
            units.append(TaskUnit(
                description: "General search for context",
                taskType: .search,
                searchQuery: "\(subject) \(bodyText)",
                index: 0
            ))
        }

        // Rule 5 – always end with compose.
        units.append(TaskUnit(
            description: "Compose reply",
            taskType: .compose,
            searchQuery: "",
            index: 0
        ))

        // Rule 6 – reindex sequentially.
        return units.enumerated().map { (i, unit) in
            TaskUnit(
                description: unit.description,
                taskType: unit.taskType,
                searchQuery: unit.searchQuery,
                index: i
            )
        }
    }
}
