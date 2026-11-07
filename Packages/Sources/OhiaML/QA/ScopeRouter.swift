import Foundation
import OhiaCore

public enum AskScopeMode: String, Sendable, Equatable {
    case direct
    case wide
    case standard
}

public struct AskPromptBudget: Sendable, Equatable {
    public let directMessageLimit: Int
    public let wideMessageLimit: Int
    public let wideSourceLimit: Int
    public let standardSourceLimit: Int
    public let directSourceLimit: Int

    public init(
        directMessageLimit: Int = 40,
        wideMessageLimit: Int = 500,
        wideSourceLimit: Int = 20,
        standardSourceLimit: Int = 6,
        directSourceLimit: Int = 160
    ) {
        self.directMessageLimit = directMessageLimit
        self.wideMessageLimit = wideMessageLimit
        self.wideSourceLimit = wideSourceLimit
        self.standardSourceLimit = standardSourceLimit
        self.directSourceLimit = directSourceLimit
    }

    public static let `default` = AskPromptBudget()
}

public struct AskScopeRoute: Sendable, Equatable {
    public let mode: AskScopeMode
    public let scopedMessageCount: Int
    public let sourceLimit: Int
    public let scopeUnit: String

    public init(
        mode: AskScopeMode,
        scopedMessageCount: Int,
        sourceLimit: Int,
        scopeUnit: String = "email"
    ) {
        self.mode = mode
        self.scopedMessageCount = scopedMessageCount
        self.sourceLimit = sourceLimit
        self.scopeUnit = scopeUnit
    }

    public var retrievalK: Int? {
        switch mode {
        case .direct: return nil
        case .wide, .standard: return sourceLimit
        }
    }

    public func uiSummary(actualSourceCount: Int) -> String {
        switch mode {
        case .direct:
            return "Read \(Self.pluralizedCount(scopedMessageCount, unit: scopeUnit)) directly"
        case .wide, .standard:
            return "Searched \(Self.pluralizedCount(scopedMessageCount, unit: scopeUnit)), read \(actualSourceCount) closest \(actualSourceCount == 1 ? "source" : "sources")"
        }
    }

    public func promptScopeSummary(filter: FilterSpec) -> String {
        var parts: [String] = [
            "\(Self.pluralizedCount(scopedMessageCount, unit: scopeUnit)) in the active scope",
            "routing mode: \(mode.rawValue)"
        ]

        if !filter.collections.isEmpty {
            let collections = filter.collections
                .map(\.rawValue)
                .sorted()
                .joined(separator: ", ")
            parts.append("collections: \(collections)")
        } else {
            parts.append("collections: default Ask source collections")
        }

        if let range = filter.dateRange {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            parts.append("date range: \(formatter.string(from: range.lowerBound)) to \(formatter.string(from: range.upperBound))")
        }
        if !filter.accountIds.isEmpty {
            parts.append("accounts: \(filter.accountIds.count)")
        }
        if !filter.senderEmails.isEmpty {
            let senders = filter.senderEmails.prefix(4).joined(separator: ", ")
            let suffix = filter.senderEmails.count > 4 ? ", ..." : ""
            parts.append("senders: \(senders)\(suffix)")
        }
        if let hasAttachment = filter.hasAttachment {
            parts.append(hasAttachment ? "has attachments only" : "without attachments only")
        }
        if let keywords = filter.keywords, !keywords.isEmpty {
            parts.append("keywords: \(keywords.prefix(4).joined(separator: ", "))")
        }
        if let allowedMessageIds = filter.allowedMessageIds {
            parts.append(allowedMessageIds.isEmpty ? "visible-message gate: empty" : "visible-message gate: active")
        }

        return parts.joined(separator: "; ")
    }

    private static func pluralizedCount(_ count: Int, unit: String) -> String {
        "\(count) \(count == 1 ? unit : unit + "s")"
    }
}

public enum ScopeRouter {
    public static func decide(
        scopeSize: Int,
        budget: AskPromptBudget = .default
    ) -> AskScopeRoute {
        if scopeSize <= budget.directMessageLimit {
            return AskScopeRoute(
                mode: .direct,
                scopedMessageCount: scopeSize,
                sourceLimit: scopeSize == 0 ? 0 : budget.directSourceLimit
            )
        }
        if scopeSize <= budget.wideMessageLimit {
            return AskScopeRoute(
                mode: .wide,
                scopedMessageCount: scopeSize,
                sourceLimit: budget.wideSourceLimit
            )
        }
        return AskScopeRoute(
            mode: .standard,
            scopedMessageCount: scopeSize,
            sourceLimit: budget.standardSourceLimit
        )
    }
}
