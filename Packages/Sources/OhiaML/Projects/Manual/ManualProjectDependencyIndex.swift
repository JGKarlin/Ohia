import Foundation
import OhiaCore

public struct ManualProjectDependencyIndex: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        let dependencies: MailProjectDependencySet
        let messageDecisionIDs: Set<UUID>
        let threadDecisionIDs: Set<UUID>
    }

    private let entries: [UUID: Entry]

    public init(configurations: [MailProjectConfigurationSnapshot]) {
        var compiled: [UUID: Entry] = [:]
        for configuration in configurations.sorted(by: { $0.projectID.uuidString < $1.projectID.uuidString }) {
            let messageDecisions = Set(configuration.manualDecisions.compactMap {
                $0.targetKind == .message ? $0.targetID : nil
            })
            let threadDecisions = Set(configuration.manualDecisions.compactMap {
                $0.targetKind == .thread ? $0.targetID : nil
            })
            compiled[configuration.projectID] = Entry(
                dependencies: Self.dependencySet(for: configuration),
                messageDecisionIDs: messageDecisions,
                threadDecisionIDs: threadDecisions
            )
        }
        entries = compiled
    }

    static func dependencySet(
        for configuration: MailProjectConfigurationSnapshot
    ) -> MailProjectDependencySet {
        var facets: Set<MailProjectRuleFacet> = [.account]
        for group in configuration.groups {
            for condition in group.conditions {
                facets.insert(condition.facet)
                guard keywordFacets.contains(condition.facet) else { continue }
                let scopes = condition.keywordScopes.isEmpty
                    ? defaultKeywordScopes
                    : condition.keywordScopes
                facets.formUnion(scopes.map(facet(for:)))
            }
        }
        return MailProjectDependencySet(
            facets: facets,
            dependsOnThreadIdentity: configuration.manualDecisions.contains {
                $0.targetKind == .thread
            }
        )
    }

    private static let keywordFacets: Set<MailProjectRuleFacet> = [
        .subject, .body, .attachmentFilename, .attachmentText,
    ]

    private static let defaultKeywordScopes: Set<MailProjectKeywordScope> = [.subject, .body]

    private static func facet(for scope: MailProjectKeywordScope) -> MailProjectRuleFacet {
        switch scope {
        case .subject: .subject
        case .body: .body
        case .attachmentFilename: .attachmentFilename
        case .attachmentText: .attachmentText
        }
    }

    public var projectIDs: Set<UUID> { Set(entries.keys) }

    public func dependencies(for projectID: UUID) -> MailProjectDependencySet? {
        entries[projectID]?.dependencies
    }

    public func affectedProjectIDs(
        messageIDs: Set<UUID>,
        threadIDs: Set<UUID>,
        changedFacets: Set<MailProjectRuleFacet>
    ) -> Set<UUID> {
        Set(entries.compactMap { projectID, entry in
            let facetMatch = changedFacets.isEmpty == false
                && entry.dependencies.facets.isDisjoint(with: changedFacets) == false
            let directMessage = entry.messageDecisionIDs.isDisjoint(with: messageIDs) == false
            let directThread = entry.threadDecisionIDs.isDisjoint(with: threadIDs) == false
            let possibleThreadDeparture = messageIDs.isEmpty == false
                && entry.dependencies.dependsOnThreadIdentity
            return facetMatch || directMessage || directThread || possibleThreadDeparture
                ? projectID
                : nil
        })
    }
}
