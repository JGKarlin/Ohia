import Foundation
import Observation
import OhiaCore
import OhiaML
import SwiftData

enum ProjectConfigurationRoute: Equatable, Hashable, Sendable {
    case newProject
    case existingProject(UUID)
    case projectDraft(UUID)
}

private enum ProjectConfigurationOpenError: Error {
    case draftMustBeOpenedFromProjects
    case draftNoLongerExists
    case legacyUnnamedDraftMustBeOpenedAsNewProject
}

private enum ProjectConfigurationDraftNameError: Error {
    case reservedPlaceholder
}

enum ProjectConfigurationStage: Equatable, Sendable {
    case configure
    case review
}

enum ProjectConfigurationLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

enum ProjectConfigurationSaveStatus: Equatable, Sendable {
    case idle
    case autosaving
    case draftSaved
    case previewing
    case saving
    case reviewRequired
    case failed(String)
}

enum ProjectConfigurationReviewKind: Equatable, Sendable {
    case configuration
    case includeEarlierMail(projectID: UUID, proposedBoundary: Date?)
}

enum ProjectInitialIntakeChoice: String, CaseIterable, Equatable, Sendable {
    case includeMatchingExistingMail
    case newMailOnly

    var title: String {
        switch self {
        case .includeMatchingExistingMail: "Include Matching Existing Mail"
        case .newMailOnly: "New Mail Only"
        }
    }
}

enum ProjectConfigurationSection: String, CaseIterable, Equatable, Sendable, Identifiable {
    case projectName
    case accountScope
    case correspondents
    case lists
    case category
    case keywords
    case tags
    case language
    case threads
    case messages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projectName: "Project Name"
        case .accountScope: "Accounts"
        case .correspondents: "Correspondents"
        case .lists: "Lists"
        case .category: "Category"
        case .keywords: "Keywords"
        case .tags: "Tags"
        case .language: "Language"
        case .threads: "Threads"
        case .messages: "Messages"
        }
    }

    var symbolName: String {
        switch self {
        case .projectName: "textformat"
        case .accountScope: "tray.2"
        case .correspondents: "person.2"
        case .lists: "list.bullet.rectangle"
        case .category: "tray.full"
        case .keywords: "text.magnifyingglass"
        case .tags: "tag"
        case .language: "character.book.closed"
        case .threads: "point.3.connected.trianglepath.dotted"
        case .messages: "envelope.badge"
        }
    }
}

enum ProjectRuleValuePickerSection: String, CaseIterable, Equatable, Sendable, Identifiable {
    case accounts
    case fixedCategories
    case customCategories
    case correspondents
    case mailingLists
    case semanticTags

    var id: String { rawValue }
    var allowsFreeCreation: Bool { false }

    static let categoryCases: [Self] = [
        .fixedCategories,
        .customCategories,
    ]

    static let tagCases: [Self] = [
        .semanticTags,
    ]

    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .fixedCategories: "Fixed Categories"
        case .customCategories: "Custom Categories"
        case .correspondents: "Correspondents"
        case .mailingLists: "Lists"
        case .semanticTags: "Tags"
        }
    }

    var facet: MailProjectRuleFacet {
        switch self {
        case .accounts: .account
        case .fixedCategories: .fixedCategory
        case .customCategories: .customCategory
        case .correspondents: .correspondent
        case .mailingLists: .mailingList
        case .semanticTags: .semanticTag
        }
    }
}

nonisolated struct ProjectConfigurationDraftRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let existingProjectID: UUID?
    let updatedAt: Date

    init(
        id: UUID,
        displayName: String,
        existingProjectID: UUID?,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.existingProjectID = existingProjectID
        self.updatedAt = updatedAt
    }

    init?(
        snapshot: MailProjectConfigurationDraftSnapshot,
        fallbackDisplayName: String? = nil
    ) {
        guard snapshot.payloadVersion == 1,
              let payload = snapshot.payloadJSON.data(using: .utf8),
              let configuration = try? JSONDecoder().decode(
                MailProjectConfigurationSnapshot.self,
                from: payload
              ) else {
            return nil
        }
        let assignedTitle = Self.assignedTitle(
            configuration.displayName,
            isNewProject: configuration.existingProjectID == nil
        )
            ?? fallbackDisplayName.flatMap { Self.assignedTitle($0) }
        guard let assignedTitle else { return nil }
        self.init(
            id: snapshot.id,
            displayName: assignedTitle,
            existingProjectID: configuration.existingProjectID,
            updatedAt: snapshot.updatedAt
        )
    }

    private static func assignedTitle(
        _ value: String,
        isNewProject: Bool = false
    ) -> String? {
        let title = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard title.isEmpty == false else { return nil }
        if isNewProject,
           title.localizedCaseInsensitiveCompare("Untitled Project") == .orderedSame {
            return nil
        }
        return title
    }
}

struct ProjectConfigurationSaveCompletion: Equatable, Sendable {
    let projectID: UUID
    let configurationRevision: Int
}

nonisolated struct ProjectRuleValueOption: Equatable, Sendable, Identifiable {
    var id: String { stableKey }
    let stableKey: String
    let canonicalStableKey: String
    let displayName: String
    let detail: String?
    let resolvedAddresses: [String]
    let currentMatchCount: Int
    let isValid: Bool

    init(
        stableKey: String,
        canonicalStableKey: String? = nil,
        displayName: String,
        detail: String? = nil,
        resolvedAddresses: [String] = [],
        currentMatchCount: Int,
        isValid: Bool
    ) {
        self.stableKey = stableKey
        self.canonicalStableKey = canonicalStableKey ?? stableKey
        self.displayName = displayName
        self.detail = detail
        self.resolvedAddresses = resolvedAddresses
        self.currentMatchCount = currentMatchCount
        self.isValid = isValid
    }

    init(_ value: MailProjectCatalogValue) {
        self.init(
            stableKey: value.stableKey,
            displayName: value.displayName,
            detail: value.detail,
            currentMatchCount: value.currentMatchCount,
            isValid: value.isValid
        )
    }
}

nonisolated struct ProjectHistoricalSearchResult: Equatable, Sendable, Identifiable {
    var id: UUID { messageID }
    let messageID: UUID
    let threadID: UUID?
    let subject: String
    let correspondent: String
    let date: Date
    let accountID: UUID?
}

nonisolated struct ProjectHistoricalSearchClient: Sendable {
    let search: @Sendable (String, Set<UUID>) async throws -> [ProjectHistoricalSearchResult]

    static func live(container: ModelContainer) -> Self {
        let service = ProjectHistoricalSearchService(container: container)
        return Self { query, accountIDs in
            try await service.search(query: query, accountIDs: accountIDs)
        }
    }
}

actor ProjectHistoricalSearchService {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func search(
        query: String,
        accountIDs: Set<UUID>
    ) throws -> [ProjectHistoricalSearchResult] {
        let normalized = Self.normalizedSearchText(query)
        guard normalized.isEmpty == false else { return [] }
        let context = ModelContext(container)
        var results: [ProjectHistoricalSearchResult] = []
        for message in try context.fetch(FetchDescriptor<Message>()) {
            try Task.checkCancellation()
            if accountIDs.isEmpty == false {
                guard let accountID = message.accountID ?? message.account?.id,
                      accountIDs.contains(accountID) else { continue }
            }
            guard Self.searchText(for: message).contains(normalized) else { continue }
            results.append(Self.result(for: message))
        }
        return results.sorted(by: Self.resultOrder)
    }

    nonisolated static func result(for message: Message) -> ProjectHistoricalSearchResult {
        ProjectHistoricalSearchResult(
            messageID: message.id,
            threadID: message.thread?.id,
            subject: message.subject.isEmpty ? "No Subject" : message.subject,
            correspondent: message.fromName?.isEmpty == false
                ? message.fromName ?? message.fromAddress
                : message.fromAddress,
            date: message.receivedAt ?? message.sentAt ?? message.ingestedAt,
            accountID: message.accountID ?? message.account?.id
        )
    }

    private nonisolated static func searchText(for message: Message) -> String {
        let participantValues = message.participants.flatMap { link -> [String] in
            guard let participant = link.participant else { return [] }
            return [
                participant.displayName ?? "",
                participant.emailAddress,
                participant.correspondent?.primaryName ?? "",
            ]
        }
        return normalizedSearchText(([
            message.subject,
            message.fromName ?? "",
            message.fromAddress,
            message.thread?.subjectRoot ?? "",
        ] + participantValues).joined(separator: " "))
    }

    private nonisolated static func normalizedSearchText(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private nonisolated static func resultOrder(
        _ lhs: ProjectHistoricalSearchResult,
        _ rhs: ProjectHistoricalSearchResult
    ) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return lhs.messageID.uuidString < rhs.messageID.uuidString
    }
}

struct ProjectDecisionPresentation: Equatable, Sendable {
    let title: String
    let detail: String
}

nonisolated struct ProjectRuleConditionDraft: Equatable, Sendable, Identifiable {
    var id: UUID
    var facet: MailProjectRuleFacet
    var polarity: MailProjectConditionPolarity
    var quantifier: MailProjectValueQuantifier
    var values: [String]
    var correspondentRole: MailProjectCorrespondentRole?
    var keywordScopes: Set<MailProjectKeywordScope>
    var keywordOperator: MailProjectKeywordOperator?
    var sortIndex: Int

    init(
        id: UUID = UUID(),
        facet: MailProjectRuleFacet,
        polarity: MailProjectConditionPolarity = .include,
        quantifier: MailProjectValueQuantifier = .any,
        values: [String] = [],
        correspondentRole: MailProjectCorrespondentRole? = nil,
        keywordScopes: Set<MailProjectKeywordScope> = [],
        keywordOperator: MailProjectKeywordOperator? = nil,
        sortIndex: Int
    ) {
        self.id = id
        self.facet = facet
        self.polarity = polarity
        self.quantifier = quantifier
        self.values = values
        self.correspondentRole = correspondentRole
        if Self.keywordFacets.contains(facet) {
            self.keywordScopes = keywordScopes.isEmpty ? [.subject, .body] : keywordScopes
            self.keywordOperator = keywordOperator ?? .containsPhrase
        } else {
            self.keywordScopes = keywordScopes
            self.keywordOperator = keywordOperator
        }
        self.sortIndex = sortIndex
    }

    init(_ snapshot: MailProjectRuleConditionSnapshot) {
        id = snapshot.id
        facet = snapshot.facet
        polarity = snapshot.polarity
        quantifier = snapshot.quantifier
        values = snapshot.values
        correspondentRole = snapshot.correspondentRole
        keywordScopes = snapshot.keywordScopes
        keywordOperator = snapshot.keywordOperator
        sortIndex = snapshot.sortIndex
    }

    var snapshot: MailProjectRuleConditionSnapshot {
        MailProjectRuleConditionSnapshot(
            id: id,
            facet: facet,
            polarity: polarity,
            quantifier: quantifier,
            values: Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
                .filter { $0.isEmpty == false }
                .sorted(),
            correspondentRole: correspondentRole,
            keywordScopes: keywordScopes,
            keywordOperator: keywordOperator,
            sortIndex: sortIndex
        )
    }

    private static let keywordFacets: Set<MailProjectRuleFacet> = [
        .subject, .body, .attachmentFilename, .attachmentText,
    ]
}

nonisolated struct ProjectRuleGroupDraft: Equatable, Sendable, Identifiable {
    var id: UUID
    var kind: MailProjectRuleGroupKind
    var sortIndex: Int
    var conditions: [ProjectRuleConditionDraft]

    init(
        id: UUID = UUID(),
        kind: MailProjectRuleGroupKind,
        sortIndex: Int,
        conditions: [ProjectRuleConditionDraft] = []
    ) {
        self.id = id
        self.kind = kind
        self.sortIndex = sortIndex
        self.conditions = conditions
    }

    init(_ snapshot: MailProjectRuleGroupSnapshot) {
        self.init(
            id: snapshot.id,
            kind: snapshot.kind,
            sortIndex: snapshot.sortIndex,
            conditions: snapshot.conditions.map(ProjectRuleConditionDraft.init)
        )
    }

    var snapshot: MailProjectRuleGroupSnapshot {
        MailProjectRuleGroupSnapshot(
            id: id,
            kind: kind,
            sortIndex: sortIndex,
            conditions: conditions.map(\.snapshot)
        )
    }
}

nonisolated struct ProjectConfigurationDraftValue: Equatable, Sendable {
    var projectID: UUID
    var existingProjectID: UUID?
    var displayName: String
    var accountIDs: Set<UUID>
    var automaticIntakeStartAt: Date?
    var baseConfigurationRevision: Int
    var groups: [ProjectRuleGroupDraft]
    var manualDecisions: [MailProjectDecisionSnapshot]

    init(_ snapshot: MailProjectConfigurationSnapshot) {
        projectID = snapshot.projectID
        existingProjectID = snapshot.existingProjectID
        displayName = snapshot.displayName
        accountIDs = snapshot.accountIDs
        automaticIntakeStartAt = snapshot.automaticIntakeStartAt
        baseConfigurationRevision = snapshot.baseConfigurationRevision
        groups = snapshot.groups.map(ProjectRuleGroupDraft.init)
        manualDecisions = snapshot.manualDecisions
    }

    var snapshot: MailProjectConfigurationSnapshot {
        MailProjectConfigurationSnapshot(
            projectID: projectID,
            existingProjectID: existingProjectID,
            displayName: displayName,
            accountIDs: accountIDs,
            automaticIntakeStartAt: automaticIntakeStartAt,
            baseConfigurationRevision: baseConfigurationRevision,
            groups: groups.map(\.snapshot),
            manualDecisions: manualDecisions
        )
    }

    var intakeChoice: ProjectInitialIntakeChoice {
        get {
            automaticIntakeStartAt == nil ? .includeMatchingExistingMail : .newMailOnly
        }
        set {
            switch newValue {
            case .includeMatchingExistingMail:
                automaticIntakeStartAt = nil
            case .newMailOnly:
                automaticIntakeStartAt = automaticIntakeStartAt ?? .distantPast
            }
        }
    }
}

nonisolated struct ProjectConfigurationDraftFingerprint: Equatable, Sendable {
    let draft: ProjectConfigurationDraftValue
}

struct ProjectConfigurationServiceClient: Sendable {
    let saveDraft: @Sendable (MailProjectConfigurationSnapshot) async throws -> Void
    let loadDraft: @Sendable () async throws -> MailProjectConfigurationDraftSnapshot?
    let discardDraft: @Sendable () async throws -> Void
    let preview: @Sendable (MailProjectConfigurationSnapshot) async throws -> MailProjectPreview
    let save: @Sendable (MailProjectConfigurationSnapshot, String) async throws -> MailProjectSaveOutcome
    let includeEarlierMail: @Sendable (UUID, Date?, String) async throws -> MailProjectSaveOutcome

    static func live(
        container: ModelContainer,
        textReader: any ProjectTextFileReading = ProjectTextFileReader()
    ) -> Self {
        let service = ManualProjectConfigurationService(
            container: container,
            textReader: textReader
        )
        return Self(
            saveDraft: { draft in try await service.saveDraft(draft) },
            loadDraft: { try await service.loadDraft() },
            discardDraft: { try await service.discardDraft() },
            preview: { draft in try await service.preview(draft) },
            save: { draft, fingerprint in
                try await service.save(draft, reviewedPreviewFingerprint: fingerprint)
            },
            includeEarlierMail: { projectID, boundary, fingerprint in
                try await service.includeEarlierMail(
                    projectID: projectID,
                    proposedBoundary: boundary,
                    reviewedPreviewFingerprint: fingerprint
                )
            }
        )
    }
}

nonisolated struct ProjectTagRecommendationFingerprint: Equatable, Sendable {
    let projectTitle: String
    let selectedTagKeys: Set<String>
    let catalogRevision: String
}

private nonisolated final class ProjectTagRecommendationEmbeddingCache: @unchecked Sendable {
    private struct Key: Hashable {
        let version: String
        let dimension: Int
        let text: String
    }

    private let cacheLock = NSLock()
    private let embeddingLock = NSLock()
    private var vectorsByKey: [Key: [Float]] = [:]

    func embedBatch(
        _ texts: [String],
        using provider: any EmbeddingProvider
    ) -> [[Float]?] {
        embeddingLock.withLock {
            let keys = texts.map {
                Key(
                    version: provider.embeddingVersion,
                    dimension: provider.embeddingDimension,
                    text: $0
                )
            }
            var resolved = cacheLock.withLock {
                keys.reduce(into: [Key: [Float]]()) { result, key in
                    result[key] = vectorsByKey[key]
                }
            }
            var missingKeys: [Key] = []
            var missingTexts: [String] = []
            var seenMissing: Set<Key> = []
            for (key, text) in zip(keys, texts)
                where resolved[key] == nil && seenMissing.insert(key).inserted {
                missingKeys.append(key)
                missingTexts.append(text)
            }

            if missingTexts.isEmpty == false, Task.isCancelled == false {
                let embedded = provider.embedBatch(missingTexts)
                var newlyResolved: [Key: [Float]] = [:]
                for (key, vector) in zip(missingKeys, embedded) {
                    if let vector {
                        resolved[key] = vector
                        newlyResolved[key] = vector
                    }
                }
                cacheLock.withLock {
                    vectorsByKey.merge(newlyResolved) { _, latest in latest }
                }
            }
            return keys.map { resolved[$0] }
        }
    }
}

private nonisolated struct ProjectTagRecommendationCachedEmbedder: EmbeddingProvider {
    let provider: any EmbeddingProvider
    let cache: ProjectTagRecommendationEmbeddingCache

    var embeddingDimension: Int { provider.embeddingDimension }
    var embeddingVersion: String { provider.embeddingVersion }

    func embed(_ text: String) -> [Float]? {
        embedBatch([text]).first ?? nil
    }

    func embedBatch(_ texts: [String]) -> [[Float]?] {
        cache.embedBatch(texts, using: provider)
    }
}

nonisolated struct ProjectTagRecommendationClient: Sendable {
    let recommendations: @MainActor @Sendable (
        String,
        Set<String>,
        MailProjectRuleCatalogSnapshot
    ) async -> [MailProjectTagRecommendation]

    static let cooccurrenceOnly = Self { projectTitle, selectedTagKeys, catalog in
        ManualProjectTagRecommendationEngine(embedder: nil).recommendations(
            projectTitle: projectTitle,
            selectedTagKeys: selectedTagKeys,
            catalog: catalog
        )
    }

    static func live(
        prepareEmbedder: @escaping @MainActor @Sendable () async -> (any EmbeddingProvider)?
    ) -> Self {
        let embeddingCache = ProjectTagRecommendationEmbeddingCache()
        return Self(recommendations: { projectTitle, selectedTagKeys, catalog in
            await recommendations(
                projectTitle: projectTitle,
                selectedTagKeys: selectedTagKeys,
                catalog: catalog,
                prepareEmbedder: prepareEmbedder,
                embeddingCache: embeddingCache
            )
        })
    }

    static func live(embedder: (any EmbeddingProvider)?) -> Self {
        live { embedder }
    }

    @MainActor
    private static func recommendations(
        projectTitle: String,
        selectedTagKeys: Set<String>,
        catalog: MailProjectRuleCatalogSnapshot,
        prepareEmbedder: @escaping @MainActor @Sendable () async -> (any EmbeddingProvider)?,
        embeddingCache: ProjectTagRecommendationEmbeddingCache
    ) async -> [MailProjectTagRecommendation] {
        let prepared = await prepareEmbedder()
        let embedder: (any EmbeddingProvider)?
        if let prepared {
            embedder = ProjectTagRecommendationCachedEmbedder(
                provider: prepared,
                cache: embeddingCache
            )
        } else {
            embedder = nil
        }
        let task = Task.detached(priority: .userInitiated) {
            let engine = ManualProjectTagRecommendationEngine(embedder: embedder)
            return engine.recommendations(
                projectTitle: projectTitle,
                selectedTagKeys: selectedTagKeys,
                catalog: catalog
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

@Observable @MainActor
final class ProjectConfigurationState {
    private let requestedRoute: ProjectConfigurationRoute
    private let container: ModelContainer
    private let service: ProjectConfigurationServiceClient
    private let historicalSearch: ProjectHistoricalSearchClient
    private let tagRecommendationClient: ProjectTagRecommendationClient
    private let autosaveDelay: Duration
    private let now: @Sendable () -> Date

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var historicalSearchGeneration = 0
    @ObservationIgnored private var tagRecommendationGeneration = 0
    @ObservationIgnored private var reviewGeneration = 0
    @ObservationIgnored private var activationDraftFingerprint: ProjectConfigurationDraftFingerprint?

    private(set) var activeRoute: ProjectConfigurationRoute
    private(set) var loadState: ProjectConfigurationLoadState = .idle
    var stage: ProjectConfigurationStage = .configure
    var selectedSection: ProjectConfigurationSection = .projectName
    var draft: ProjectConfigurationDraftValue?
    private(set) var malformedDraftRecoveryAvailable = false
    private(set) var catalog: MailProjectRuleCatalogSnapshot?
    private(set) var tagRecommendations: [MailProjectTagRecommendation] = []
    private(set) var historicalSearchResults: [ProjectHistoricalSearchResult] = []
    var historicalSearchQuery = ""
    private(set) var preview: MailProjectPreview?
    private(set) var validationReport: MailProjectValidationReport?
    private(set) var saveStatus: ProjectConfigurationSaveStatus = .idle
    private(set) var completedSave: ProjectConfigurationSaveCompletion?
    private(set) var reviewKind: ProjectConfigurationReviewKind = .configuration
    private(set) var previewMessagesByID: [UUID: ProjectHistoricalSearchResult] = [:]

    var draftFingerprint: ProjectConfigurationDraftFingerprint? {
        draft.map(ProjectConfigurationDraftFingerprint.init(draft:))
    }

    var tagRecommendationFingerprint: ProjectTagRecommendationFingerprint? {
        guard let draft, let catalog else { return nil }
        return ProjectTagRecommendationFingerprint(
            projectTitle: draft.displayName,
            selectedTagKeys: selectedSemanticTagKeys,
            catalogRevision: catalog.validityRevision
        )
    }

    var isBusy: Bool {
        switch saveStatus {
        case .autosaving, .previewing, .saving: true
        default: false
        }
    }

    var canNavigateAway: Bool {
        saveStatus != .saving
    }

    init(
        route: ProjectConfigurationRoute,
        container: ModelContainer,
        service: ProjectConfigurationServiceClient? = nil,
        historicalSearch: ProjectHistoricalSearchClient? = nil,
        tagEmbedder: (any EmbeddingProvider)? = nil,
        tagRecommendationClient: ProjectTagRecommendationClient? = nil,
        autosaveDelay: Duration = .milliseconds(450),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        requestedRoute = route
        activeRoute = route
        self.container = container
        self.service = service ?? .live(container: container)
        self.historicalSearch = historicalSearch ?? .live(container: container)
        self.tagRecommendationClient = tagRecommendationClient ?? .live(embedder: tagEmbedder)
        self.autosaveDelay = autosaveDelay
        self.now = now
    }

    deinit {
        autosaveTask?.cancel()
    }

    func start() async {
        guard loadState == .idle else { return }
        loadState = .loading
        do {
            catalog = try loadCatalog(selectedValuesByFacet: [:])
            let stored = try await service.loadDraft()
            switch (requestedRoute, stored) {
            case (.projectDraft(let requestedID), .some(let stored)):
                guard stored.id == requestedID else {
                    throw ProjectConfigurationOpenError.draftNoLongerExists
                }
                let configuration = try decodeDraft(stored)
                activate(configuration, route: route(for: configuration))
            case (.projectDraft, .none):
                throw ProjectConfigurationOpenError.draftNoLongerExists
            case (.newProject, .some(let stored)):
                let configuration = try decodeDraft(stored)
                if Self.isLegacyUnnamedNewProject(configuration) {
                    try await service.discardDraft()
                    activate(
                        Self.replacingDisplayName(in: configuration, with: ""),
                        route: .newProject
                    )
                } else {
                    throw ProjectConfigurationOpenError.draftMustBeOpenedFromProjects
                }
            case (.existingProject, .some(let stored)):
                let configuration = try decodeDraft(stored)
                if Self.isLegacyUnnamedNewProject(configuration) {
                    throw ProjectConfigurationOpenError.legacyUnnamedDraftMustBeOpenedAsNewProject
                }
                throw ProjectConfigurationOpenError.draftMustBeOpenedFromProjects
            case (.newProject, .none), (.existingProject, .none):
                try activateInitialDraft(for: requestedRoute)
            }
        } catch {
            malformedDraftRecoveryAvailable = Self.isMalformedDraft(error)
            loadState = .failed(Self.message(for: error))
            saveStatus = .failed(Self.message(for: error))
        }
    }

    func discardCurrentDraftAndContinue() async {
        saveStatus = .autosaving
        do {
            try await service.discardDraft()
            malformedDraftRecoveryAvailable = false
            if case .projectDraft = requestedRoute {
                try activateInitialDraft(for: .newProject)
            } else {
                try activateInitialDraft(for: requestedRoute)
            }
            saveStatus = .idle
        } catch {
            loadState = .failed(Self.message(for: error))
            saveStatus = .failed(Self.message(for: error))
        }
    }

    func discardCurrentDraftForExit() async -> Bool {
        cancelAutosave()
        saveStatus = .autosaving
        do {
            try await service.discardDraft()
            historicalSearchGeneration &+= 1
            reviewGeneration &+= 1
            draft = nil
            activationDraftFingerprint = nil
            historicalSearchQuery = ""
            historicalSearchResults = []
            preview = nil
            validationReport = nil
            previewMessagesByID = [:]
            saveStatus = .idle
            loadState = .ready
            return true
        } catch {
            saveStatus = .failed(Self.message(for: error))
            return false
        }
    }

    func scheduleAutosave() {
        guard loadState == .ready,
              completedSave == nil,
              stage == .configure,
              let snapshot = draft?.snapshot else { return }
        autosaveTask?.cancel()
        let fingerprint = draftFingerprint
        guard fingerprint != activationDraftFingerprint else {
            saveStatus = .idle
            return
        }
        let shouldPersist = Self.shouldPersistDraft(snapshot)
        guard shouldPersist else {
            saveStatus = .idle
            return
        }
        saveStatus = .autosaving
        autosaveTask = Task { [weak self, service, autosaveDelay] in
            do {
                try await Task.sleep(for: autosaveDelay)
                try Task.checkCancellation()
                try await service.saveDraft(snapshot)
                guard let self, self.draftFingerprint == fingerprint else { return }
                self.saveStatus = .draftSaved
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.draftFingerprint == fingerprint else { return }
                self.saveStatus = .failed(Self.message(for: error))
            }
        }
    }

    func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    func persistDraftBeforeClosing() async -> Bool {
        guard canNavigateAway else { return false }
        cancelAutosave()
        guard loadState == .ready,
              completedSave == nil,
              let snapshot = draft?.snapshot else { return true }
        guard draftFingerprint != activationDraftFingerprint else {
            saveStatus = .idle
            return true
        }
        saveStatus = .autosaving
        do {
            if Self.shouldPersistDraft(snapshot) {
                try await service.saveDraft(snapshot)
                saveStatus = .draftSaved
            } else {
                try await service.discardDraft()
                saveStatus = .idle
            }
            return true
        } catch {
            saveStatus = .failed(Self.message(for: error))
            return false
        }
    }

    func persistDraftForWorkspaceDisappearance() async {
        _ = await persistDraftBeforeClosing()
    }

    func setInitialIntakeChoice(_ choice: ProjectInitialIntakeChoice) {
        guard draft?.existingProjectID == nil else { return }
        draft?.intakeChoice = choice
        preview = nil
    }

    func setDisplayName(_ displayName: String) {
        draft?.displayName = displayName
        preview = nil
    }

    func setAccountScope(_ accountIDs: Set<UUID>) {
        draft?.accountIDs = accountIDs
        historicalSearchGeneration &+= 1
        historicalSearchResults = []
        preview = nil
    }

    func setDefaultCorrespondent(
        _ stableKey: String,
        isSelected: Bool,
        role: MailProjectCorrespondentRole = .involves
    ) {
        guard var value = draft else { return }
        let key = stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return }

        if isSelected {
            guard Self.matchGroups(in: value.groups, contain: key) == false else { return }
            value.groups.append(Self.broadCorrespondentGroup(
                stableKey: key,
                role: role,
                sortIndex: value.groups.count
            ))
        } else {
            Self.removeCorrespondent(key, from: &value.groups)
        }

        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
    }

    func setDefaultCorrespondentRole(
        _ stableKey: String,
        role: MailProjectCorrespondentRole
    ) {
        guard var value = draft else { return }
        let key = stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return }
        var foundBroadPath = false

        for groupIndex in value.groups.indices.reversed()
            where Self.isBroadCorrespondentGroup(value.groups[groupIndex]) {
            guard let conditionIndex = value.groups[groupIndex].conditions.firstIndex(where: {
                $0.facet == .correspondent
                    && $0.polarity == .include
                    && $0.values.contains(key)
            }) else { continue }
            foundBroadPath = true
            value.groups[groupIndex].conditions[conditionIndex].values.removeAll { $0 == key }
            if value.groups[groupIndex].conditions[conditionIndex].values.isEmpty {
                value.groups.remove(at: groupIndex)
            }
        }

        guard foundBroadPath else { return }
        value.groups.append(Self.broadCorrespondentGroup(
            stableKey: key,
            role: role,
            sortIndex: value.groups.count
        ))
        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
    }

    func setDefaultCorrespondentRoles(
        _ stableKey: String,
        roles: Set<MailProjectCorrespondentRole>
    ) {
        guard var value = draft else { return }
        let key = stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return }
        let selectedRoles = roles.intersection([.from, .to, .cc, .bcc])
        let templates = Self.correspondentPathTemplates(for: key, in: value.groups)
        let categoryRestrictions = Self.correspondentCategoryRestrictions(
            for: key,
            in: value.groups
        )
        Self.removeCorrespondent(key, from: &value.groups)
        for role in Self.visibleCorrespondentRoles where selectedRoles.contains(role) {
            let roleTemplates = templates.filter { $0.role == role }
            let effectiveTemplates = roleTemplates.isEmpty
                ? [CorrespondentPathTemplate(role: role, localConditions: categoryRestrictions)]
                : roleTemplates
            for template in effectiveTemplates {
                value.groups.append(Self.correspondentGroup(
                    stableKey: key,
                    role: role,
                    localConditions: template.localConditions,
                    sortIndex: value.groups.count
                ))
            }
        }
        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
    }

    func setDefaultMailingList(_ stableKey: String, isSelected: Bool) {
        guard var value = draft else { return }
        let key = stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return }
        for index in value.groups.indices.reversed() where value.groups[index].kind == .match {
            for conditionIndex in value.groups[index].conditions.indices.reversed()
                where value.groups[index].conditions[conditionIndex].facet == .mailingList {
                value.groups[index].conditions[conditionIndex].values.removeAll { $0 == key }
                if value.groups[index].conditions[conditionIndex].values.isEmpty {
                    value.groups[index].conditions.remove(at: conditionIndex)
                }
            }
            if value.groups[index].conditions.isEmpty {
                value.groups.remove(at: index)
            }
        }
        if isSelected {
            value.groups.append(ProjectRuleGroupDraft(
                kind: .match,
                sortIndex: value.groups.count,
                conditions: [ProjectRuleConditionDraft(
                    facet: .mailingList,
                    values: [key],
                    sortIndex: 0
                )]
            ))
        }
        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
    }

    func projectCategoryChoice(
        stableKey: String,
        facet: MailProjectRuleFacet
    ) -> ProjectCategoryMembershipChoice? {
        guard Self.categoryFacets.contains(facet) else { return nil }
        let groups = draft?.groups ?? []
        if Self.categoryOnlyGroup(groups, kind: .projectWideExclusion, facet: facet, key: stableKey) {
            return .exclude
        }
        if Self.categoryOnlyGroup(groups, kind: .match, facet: facet, key: stableKey) {
            return .include
        }
        return nil
    }

    func setProjectCategory(
        stableKey: String,
        facet: MailProjectRuleFacet,
        choice: ProjectCategoryMembershipChoice?
    ) {
        guard Self.categoryFacets.contains(facet), var value = draft else { return }
        let key = stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return }
        Self.removeCategoryOnlyValue(key, facet: facet, from: &value.groups)
        if let choice {
            let kind: MailProjectRuleGroupKind = choice == .include
                ? .match
                : .projectWideExclusion
            value.groups.append(ProjectRuleGroupDraft(
                kind: kind,
                sortIndex: value.groups.count,
                conditions: [ProjectRuleConditionDraft(
                    facet: facet,
                    polarity: .include,
                    quantifier: .any,
                    values: [key],
                    sortIndex: 0
                )]
            ))
        }
        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
    }

    func correspondentExcludedCategories(
        _ stableKey: String
    ) -> [MailProjectRuleFacet: Set<String>] {
        let key = stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return (draft?.groups ?? []).reduce(into: [:]) { result, group in
            guard group.kind == .match,
                  group.conditions.contains(where: {
                      $0.facet == .correspondent
                          && $0.polarity == .include
                          && $0.values.contains(key)
                  }) else { return }
            for condition in group.conditions
                where Self.categoryFacets.contains(condition.facet)
                    && condition.polarity == .exclude {
                result[condition.facet, default: []].formUnion(condition.values)
            }
        }
    }

    func setCorrespondentCategory(
        _ correspondentKey: String,
        stableKey: String,
        facet: MailProjectRuleFacet,
        isIncluded: Bool
    ) {
        guard Self.categoryFacets.contains(facet), var value = draft else { return }
        let correspondent = correspondentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard correspondent.isEmpty == false, category.isEmpty == false else { return }
        var excluded = correspondentExcludedCategories(correspondent)
        if isIncluded {
            excluded[facet]?.remove(category)
        } else {
            excluded[facet, default: []].insert(category)
        }
        excluded = excluded.filter { $0.value.isEmpty == false }
        let templates = Self.correspondentPathTemplates(for: correspondent, in: value.groups)
            .map { template in
                CorrespondentPathTemplate(
                    role: template.role,
                    localConditions: template.localConditions.filter {
                        Self.categoryFacets.contains($0.facet) == false
                    } + excluded.keys.sorted(by: { $0.rawValue < $1.rawValue }).map { facet in
                        ProjectRuleConditionDraft(
                            facet: facet,
                            polarity: .exclude,
                            quantifier: .any,
                            values: excluded[facet, default: []].sorted(),
                            sortIndex: 0
                        )
                    }
                )
            }
        Self.removeCorrespondent(correspondent, from: &value.groups)
        for template in templates {
            value.groups.append(Self.correspondentGroup(
                stableKey: correspondent,
                role: template.role,
                localConditions: template.localConditions,
                sortIndex: value.groups.count
            ))
        }
        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
    }

    func upsertSharedCondition(_ condition: ProjectRuleConditionDraft) {
        guard condition.facet != .account,
              condition.facet != .correspondent,
              var value = draft else { return }

        let sharedIndices = value.groups.indices.filter {
            value.groups[$0].kind == .sharedCriteria
        }
        let sharedIndex: Int
        if let first = sharedIndices.first {
            sharedIndex = first
            for index in sharedIndices.dropFirst().reversed() {
                value.groups[sharedIndex].conditions.append(contentsOf: value.groups[index].conditions)
                value.groups.remove(at: index)
            }
        } else {
            value.groups.append(ProjectRuleGroupDraft(
                kind: .sharedCriteria,
                sortIndex: value.groups.count
            ))
            sharedIndex = value.groups.index(before: value.groups.endIndex)
        }

        var normalized = condition
        normalized.values = Array(Set(condition.values)).sorted()
        if Self.keywordFacets.contains(normalized.facet) {
            if normalized.keywordScopes.isEmpty {
                normalized.keywordScopes = [.subject, .body]
            }
            normalized.keywordOperator = normalized.keywordOperator ?? .containsPhrase
        }
        value.groups[sharedIndex].conditions.removeAll { $0.id == normalized.id }
        value.groups[sharedIndex].conditions.append(normalized)
        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
    }

    func removeSharedCondition(_ conditionID: UUID) {
        guard var value = draft else { return }
        for groupIndex in value.groups.indices.reversed()
            where value.groups[groupIndex].kind == .sharedCriteria {
            value.groups[groupIndex].conditions.removeAll { $0.id == conditionID }
            if value.groups[groupIndex].conditions.isEmpty {
                value.groups.remove(at: groupIndex)
            }
        }
        Self.coalesceSharedCriteriaGroups(in: &value.groups)
        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
    }

    @discardableResult
    func addCorrespondentSpecificGroup(
        correspondentKeys: Set<String>,
        role: MailProjectCorrespondentRole = .involves
    ) -> UUID? {
        guard var value = draft else { return nil }
        let keys = Set(correspondentKeys.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.isEmpty == false })
        guard keys.isEmpty == false,
              keys.allSatisfy({ Self.matchGroups(in: value.groups, contain: $0) }) else {
            return nil
        }

        Self.removeCorrespondentsFromBroadPaths(keys, in: &value.groups)
        let groupID = UUID()
        value.groups.append(ProjectRuleGroupDraft(
            id: groupID,
            kind: .match,
            sortIndex: value.groups.count,
            conditions: [
                ProjectRuleConditionDraft(
                    facet: .correspondent,
                    values: keys.sorted(),
                    correspondentRole: role,
                    sortIndex: 0
                ),
            ]
        ))
        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
        return groupID
    }

    @discardableResult
    func addCorrespondentSpecificCondition(
        _ condition: ProjectRuleConditionDraft,
        correspondentKeys: Set<String>
    ) -> [UUID] {
        guard var value = draft else { return [] }
        let keys = Set(correspondentKeys.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.isEmpty == false })
        guard keys.isEmpty == false else { return [] }

        var createdGroupIDs: [UUID] = []
        for key in keys.sorted() {
            let templates = Self.correspondentPathTemplates(for: key, in: value.groups)
            guard templates.isEmpty == false else { continue }
            Self.removeCorrespondent(key, from: &value.groups)
            for template in templates {
                let group = Self.correspondentGroup(
                    stableKey: key,
                    role: template.role,
                    localConditions: template.localConditions + [condition],
                    sortIndex: value.groups.count
                )
                createdGroupIDs.append(group.id)
                value.groups.append(group)
            }
        }

        guard createdGroupIDs.isEmpty == false else { return [] }
        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
        return createdGroupIDs
    }

    func removeCorrespondentSpecificGroup(
        _ groupID: UUID,
        keepCorrespondentsSelected: Bool
    ) {
        guard var value = draft,
              let groupIndex = value.groups.firstIndex(where: {
                  $0.id == groupID && $0.kind == .match
              }) else { return }
        let removedGroup = value.groups.remove(at: groupIndex)
        let removedRolesByKey = removedGroup.conditions
            .filter { $0.facet == .correspondent && $0.polarity == .include }
            .reduce(into: [String: MailProjectCorrespondentRole]()) { result, condition in
                for key in condition.values {
                    result[key] = condition.correspondentRole ?? .involves
                }
            }

        if keepCorrespondentsSelected {
            for key in removedRolesByKey.keys.sorted()
                where Self.matchGroups(in: value.groups, contain: key) == false {
                value.groups.append(Self.broadCorrespondentGroup(
                    stableKey: key,
                    role: removedRolesByKey[key] ?? .involves,
                    sortIndex: value.groups.count
                ))
            }
        }

        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
    }

    func setCorrespondentSelection(
        _ stableKeys: Set<String>,
        role: MailProjectCorrespondentRole,
        groupID: UUID?,
        conditionID: UUID?,
        keepRemovedCorrespondentsSelected: Bool = false
    ) {
        if groupID == nil, conditionID == nil {
            for key in stableKeys.sorted() {
                setDefaultCorrespondent(key, isSelected: true, role: role)
            }
            return
        }
        guard var value = draft else { return }
        let values = stableKeys.sorted()

        if let groupID,
           let groupIndex = value.groups.firstIndex(where: {
               $0.id == groupID && $0.kind == .match
           }) {
            if let conditionID {
                guard let conditionIndex = value.groups[groupIndex].conditions.firstIndex(where: {
                    $0.id == conditionID && $0.facet == .correspondent
                }) else { return }
                let previousCondition = value.groups[groupIndex].conditions[conditionIndex]
                let previousKeys = Set(previousCondition.values)
                let nextKeys = Set(values)
                if values.isEmpty {
                    let removedRolesByKey = keepRemovedCorrespondentsSelected
                        ? Self.correspondentRoles(in: value.groups[groupIndex])
                        : [:]
                    value.groups.remove(at: groupIndex)
                    if keepRemovedCorrespondentsSelected {
                        Self.restoreBroadCorrespondentPaths(
                            removedRolesByKey,
                            in: &value.groups
                        )
                    }
                } else {
                    value.groups[groupIndex].conditions[conditionIndex].values = values
                    value.groups[groupIndex].conditions[conditionIndex].correspondentRole = role
                    Self.removeCorrespondentsFromBroadPaths(
                        nextKeys.subtracting(previousKeys),
                        excluding: groupID,
                        in: &value.groups
                    )
                    if keepRemovedCorrespondentsSelected {
                        Self.restoreBroadCorrespondentPaths(
                            Dictionary(uniqueKeysWithValues: previousKeys
                                .subtracting(nextKeys)
                                .map { ($0, previousCondition.correspondentRole ?? role) }),
                            in: &value.groups
                        )
                    }
                }
            } else {
                guard values.isEmpty == false else { return }
                Self.removeCorrespondentsFromBroadPaths(
                    Set(values),
                    excluding: groupID,
                    in: &value.groups
                )
                value.groups[groupIndex].conditions.append(ProjectRuleConditionDraft(
                    facet: .correspondent,
                    values: values,
                    correspondentRole: role,
                    sortIndex: value.groups[groupIndex].conditions.count
                ))
            }
        } else {
            return
        }
        Self.normalizeGroupOrder(&value.groups)
        draft = value
        preview = nil
    }

    func addRuleGroup(kind: MailProjectRuleGroupKind) {
        guard var value = draft else { return }
        value.groups.append(ProjectRuleGroupDraft(
            kind: kind,
            sortIndex: value.groups.count
        ))
        draft = value
        preview = nil
    }

    func removeRuleGroup(_ groupID: UUID) {
        guard var value = draft else { return }
        value.groups.removeAll { $0.id == groupID }
        for index in value.groups.indices { value.groups[index].sortIndex = index }
        draft = value
        preview = nil
    }

    func addCondition(
        to groupID: UUID,
        facet: MailProjectRuleFacet,
        polarity: MailProjectConditionPolarity = .include
    ) {
        guard var value = draft,
              let groupIndex = value.groups.firstIndex(where: { $0.id == groupID }) else { return }
        let isKeyword = Self.keywordFacets.contains(facet)
        value.groups[groupIndex].conditions.append(ProjectRuleConditionDraft(
            facet: facet,
            polarity: polarity,
            values: [],
            correspondentRole: facet == .correspondent ? .involves : nil,
            keywordScopes: isKeyword ? [.subject, .body] : [],
            keywordOperator: isKeyword ? .containsPhrase : nil,
            sortIndex: value.groups[groupIndex].conditions.count
        ))
        draft = value
        preview = nil
    }

    func updateCondition(_ condition: ProjectRuleConditionDraft, in groupID: UUID) {
        guard var value = draft,
              let groupIndex = value.groups.firstIndex(where: { $0.id == groupID }),
              let conditionIndex = value.groups[groupIndex].conditions.firstIndex(where: {
                  $0.id == condition.id
              }) else { return }
        value.groups[groupIndex].conditions[conditionIndex] = condition
        draft = value
        preview = nil
    }

    func removeCondition(_ conditionID: UUID, from groupID: UUID) {
        guard var value = draft,
              let groupIndex = value.groups.firstIndex(where: { $0.id == groupID }) else { return }
        value.groups[groupIndex].conditions.removeAll { $0.id == conditionID }
        for index in value.groups[groupIndex].conditions.indices {
            value.groups[groupIndex].conditions[index].sortIndex = index
        }
        draft = value
        preview = nil
    }

    func clearInvalidValue(_ valueToRemove: String, conditionID: UUID, groupID: UUID) {
        guard var value = draft,
              let groupIndex = value.groups.firstIndex(where: { $0.id == groupID }),
              let conditionIndex = value.groups[groupIndex].conditions.firstIndex(where: {
                  $0.id == conditionID
              }) else { return }
        value.groups[groupIndex].conditions[conditionIndex].values.removeAll { $0 == valueToRemove }
        draft = value
        preview = nil
    }

    var selectedSemanticTagKeys: Set<String> {
        Set((draft?.groups ?? [])
            .filter { $0.kind == .sharedCriteria }
            .flatMap(\.conditions)
            .filter { $0.facet == .semanticTag && $0.polarity == .include }
            .flatMap(\.values))
    }

    func addSharedSemanticTag(_ stableKey: String) {
        let key = stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false, selectedSemanticTagKeys.contains(key) == false else { return }
        let existing = (draft?.groups ?? [])
            .filter { $0.kind == .sharedCriteria }
            .flatMap(\.conditions)
            .first { condition in
                condition.facet == .semanticTag
                    && condition.polarity == .include
                    && condition.quantifier == .any
            }
        if var existing {
            existing.values.append(key)
            upsertSharedCondition(existing)
        } else {
            upsertSharedCondition(ProjectRuleConditionDraft(
                facet: .semanticTag,
                polarity: .include,
                quantifier: .any,
                values: [key],
                sortIndex: (draft?.groups ?? [])
                    .filter { $0.kind == .sharedCriteria }
                    .flatMap(\.conditions)
                    .count
            ))
        }
    }

    func refreshTagRecommendations() async {
        guard let fingerprint = tagRecommendationFingerprint,
              let catalog else {
            tagRecommendations = []
            return
        }
        tagRecommendationGeneration &+= 1
        let generation = tagRecommendationGeneration
        let recommendations = await tagRecommendationClient.recommendations(
            fingerprint.projectTitle,
            fingerprint.selectedTagKeys,
            catalog
        )
        guard generation == tagRecommendationGeneration,
              fingerprint == tagRecommendationFingerprint else { return }
        tagRecommendations = recommendations
    }

    func searchableValues(
        for section: ProjectRuleValuePickerSection,
        query: String
    ) -> [ProjectRuleValueOption] {
        guard let catalog else { return [] }
        if section == .accounts {
            return ManualProjectRuleCatalog.search(query, in: catalog.accounts)
                .map(ProjectRuleValueOption.init)
        }
        if section == .correspondents {
            let values = catalog.correspondents.map { correspondent in
                ProjectRuleValueOption(
                    stableKey: correspondent.id.uuidString,
                    canonicalStableKey: correspondent.canonicalID.uuidString,
                    displayName: correspondent.displayName,
                    detail: correspondent.resolvedAddresses.joined(separator: " · "),
                    resolvedAddresses: correspondent.resolvedAddresses,
                    currentMatchCount: correspondent.currentMatchCount,
                    isValid: true
                )
            }
            let normalized = Self.normalizedSearchText(query)
            guard normalized.isEmpty == false else { return values }
            return values.filter { value in
                Self.normalizedSearchText(value.stableKey).contains(normalized)
                    || Self.normalizedSearchText(value.displayName).contains(normalized)
                    || Self.normalizedSearchText(value.detail ?? "").contains(normalized)
            }
        }
        if section == .mailingLists {
            return ManualProjectRuleCatalog.search(
                query,
                in: catalog.valuesByFacet[.mailingList] ?? []
            ).map(ProjectRuleValueOption.init)
        }
        if ProjectRuleValuePickerSection.tagCases.contains(section) {
            return ManualProjectRuleCatalog.search(
                query,
                in: catalog.valuesByFacet[section.facet] ?? []
            ).map(ProjectRuleValueOption.init)
        }
        return ManualProjectRuleCatalog.search(
            query,
            in: catalog.valuesByFacet[section.facet] ?? []
        ).map(ProjectRuleValueOption.init)
    }

    func searchHistoricalMail(query: String) async {
        historicalSearchQuery = query
        historicalSearchGeneration &+= 1
        let generation = historicalSearchGeneration
        let normalized = Self.normalizedSearchText(query)
        guard normalized.isEmpty == false, let draft else {
            historicalSearchResults = []
            return
        }
        let accountIDs = draft.accountIDs
        do {
            let results = try await historicalSearch.search(query, accountIDs)
            guard generation == historicalSearchGeneration,
                  historicalSearchQuery == query,
                  self.draft?.accountIDs == accountIDs else { return }
            historicalSearchResults = results
        } catch is CancellationError {
            return
        } catch {
            guard generation == historicalSearchGeneration else { return }
            saveStatus = .failed(Self.message(for: error))
            historicalSearchResults = []
        }
    }

    func includeHistoricalMessage(_ messageID: UUID) {
        replaceDecision(targetKind: .message, targetID: messageID, decision: .include)
    }

    func excludeHistoricalMessage(_ messageID: UUID) {
        replaceDecision(targetKind: .message, targetID: messageID, decision: .exclude)
    }

    func followHistoricalThread(_ threadID: UUID) {
        replaceThreadDecision(threadID, decision: .include)
    }

    func excludeHistoricalThread(_ threadID: UUID) {
        replaceThreadDecision(threadID, decision: .exclude)
    }

    func removeDecision(_ decisionID: UUID) {
        draft?.manualDecisions.removeAll { $0.id == decisionID }
        preview = nil
    }

    func prepareReview() async {
        guard let draft, completedSave == nil else { return }
        cancelAutosave()
        let snapshot = draft.snapshot
        let fingerprint = ProjectConfigurationDraftFingerprint(draft: draft)
        reviewGeneration &+= 1
        let generation = reviewGeneration
        preview = nil
        validationReport = nil
        saveStatus = .autosaving
        do {
            guard Self.isLegacyUnnamedNewProject(snapshot) == false else {
                throw ProjectConfigurationDraftNameError.reservedPlaceholder
            }
            _ = try MailProject.normalizedName(snapshot.displayName)
            try await service.saveDraft(snapshot)
            guard reviewRequestIsCurrent(generation, fingerprint: fingerprint) else {
                finishStaleReviewRequestIfNeeded(generation)
                return
            }
            let refreshedCatalog = try loadCatalog(
                selectedValuesByFacet: selectedValuesByFacet(snapshot)
            )
            catalog = refreshedCatalog
            let report = ManualProjectConfigurationValidator.validate(
                configuration: snapshot,
                catalog: refreshedCatalog
            )
            validationReport = report
            guard report.isValid else {
                preview = nil
                reviewKind = .configuration
                stage = .review
                saveStatus = .idle
                return
            }
            saveStatus = .previewing
            let candidate = try await service.preview(snapshot)
            guard reviewRequestIsCurrent(generation, fingerprint: fingerprint) else {
                finishStaleReviewRequestIfNeeded(generation)
                return
            }
            installPreview(candidate, kind: .configuration)
        } catch {
            guard reviewGeneration == generation else { return }
            guard draftFingerprint == fingerprint, completedSave == nil else {
                finishStaleReviewRequestIfNeeded(generation)
                return
            }
            stage = .configure
            saveStatus = .failed(Self.message(for: error))
        }
    }

    func reviewChanges() async {
        if stage == .review,
           saveStatus == .reviewRequired,
           preview != nil {
            saveStatus = .idle
            return
        }

        if stage == .review,
           case .includeEarlierMail = reviewKind {
            await prepareIncludeEarlierMail()
            return
        }

        await prepareReview()
    }

    func prepareIncludeEarlierMail() async {
        guard let draft,
              completedSave == nil,
              let projectID = draft.existingProjectID,
              draft.automaticIntakeStartAt != nil else { return }
        saveStatus = .previewing
        do {
            let outcome = try await service.includeEarlierMail(projectID, nil, "")
            handle(
                outcome,
                reviewKind: .includeEarlierMail(projectID: projectID, proposedBoundary: nil)
            )
        } catch {
            saveStatus = .failed(Self.message(for: error))
        }
    }

    func saveReviewedConfiguration() async {
        guard completedSave == nil, let draft, let preview else { return }
        saveStatus = .saving
        do {
            let outcome: MailProjectSaveOutcome
            switch reviewKind {
            case .configuration:
                outcome = try await service.save(draft.snapshot, preview.fingerprint)
            case let .includeEarlierMail(projectID, proposedBoundary):
                outcome = try await service.includeEarlierMail(
                    projectID,
                    proposedBoundary,
                    preview.fingerprint
                )
            }
            handle(outcome, reviewKind: reviewKind)
        } catch {
            saveStatus = .failed(Self.message(for: error))
        }
    }

    func retrySave() async {
        await saveReviewedConfiguration()
    }

    func returnToConfigure() {
        guard canNavigateAway else { return }
        stage = .configure
        selectedSection = .projectName
        saveStatus = .idle
    }

    func previewMessage(_ messageID: UUID) -> ProjectHistoricalSearchResult? {
        previewMessagesByID[messageID]
    }

    func decisionPresentation(
        for decision: MailProjectDecisionSnapshot
    ) -> ProjectDecisionPresentation? {
        let context = ModelContext(container)
        do {
            switch decision.targetKind {
            case .message:
                let targetID = decision.targetID
                var descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate<Message> { $0.id == targetID }
                )
                descriptor.fetchLimit = 1
                guard let message = try context.fetch(descriptor).first else { return nil }
                return ProjectDecisionPresentation(
                    title: message.subject.isEmpty ? "No Subject" : message.subject,
                    detail: message.fromName?.isEmpty == false
                        ? message.fromName ?? message.fromAddress
                        : message.fromAddress
                )
            case .thread:
                let targetID = decision.targetID
                var descriptor = FetchDescriptor<MessageThread>(
                    predicate: #Predicate<MessageThread> { $0.id == targetID }
                )
                descriptor.fetchLimit = 1
                guard let thread = try context.fetch(descriptor).first else { return nil }
                return ProjectDecisionPresentation(
                    title: thread.subjectRoot.isEmpty ? "Untitled Thread" : thread.subjectRoot,
                    detail: "Thread"
                )
            }
        } catch {
            return nil
        }
    }

    private func activateInitialDraft(for route: ProjectConfigurationRoute) throws {
        let configuration: MailProjectConfigurationSnapshot
        switch route {
        case .newProject:
            configuration = MailProjectConfigurationSnapshot(
                projectID: UUID(),
                existingProjectID: nil,
                displayName: "",
                accountIDs: [],
                automaticIntakeStartAt: .distantPast,
                baseConfigurationRevision: 0,
                groups: [],
                manualDecisions: []
            )
        case .existingProject(let projectID):
            configuration = try loadLiveConfiguration(projectID: projectID)
        case .projectDraft:
            throw ProjectConfigurationOpenError.draftNoLongerExists
        }
        activate(configuration, route: route)
    }

    private func activate(
        _ configuration: MailProjectConfigurationSnapshot,
        route: ProjectConfigurationRoute
    ) {
        activeRoute = route
        reviewGeneration &+= 1
        completedSave = nil
        let activatedDraft = ProjectConfigurationDraftValue(configuration)
        draft = activatedDraft
        activationDraftFingerprint = ProjectConfigurationDraftFingerprint(draft: activatedDraft)
        stage = .configure
        selectedSection = .projectName
        preview = nil
        validationReport = nil
        saveStatus = .idle
        loadState = .ready
        catalog = try? loadCatalog(
            selectedValuesByFacet: selectedValuesByFacet(configuration)
        )
    }

    private static func shouldPersistDraft(
        _ snapshot: MailProjectConfigurationSnapshot
    ) -> Bool {
        isLegacyUnnamedNewProject(snapshot) == false
            && (try? MailProject.normalizedName(snapshot.displayName)) != nil
    }

    private static func isLegacyUnnamedNewProject(
        _ configuration: MailProjectConfigurationSnapshot
    ) -> Bool {
        guard configuration.existingProjectID == nil else { return false }
        let title = configuration.displayName
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return title.localizedCaseInsensitiveCompare("Untitled Project") == .orderedSame
    }

    private static func replacingDisplayName(
        in configuration: MailProjectConfigurationSnapshot,
        with displayName: String
    ) -> MailProjectConfigurationSnapshot {
        MailProjectConfigurationSnapshot(
            projectID: configuration.projectID,
            existingProjectID: configuration.existingProjectID,
            displayName: displayName,
            accountIDs: configuration.accountIDs,
            automaticIntakeStartAt: configuration.automaticIntakeStartAt,
            baseConfigurationRevision: configuration.baseConfigurationRevision,
            groups: configuration.groups,
            manualDecisions: configuration.manualDecisions
        )
    }

    private func installPreview(
        _ candidate: MailProjectPreview,
        kind: ProjectConfigurationReviewKind
    ) {
        preview = candidate
        reviewKind = kind
        stage = .review
        saveStatus = .idle
        loadPreviewMessages(candidate)
    }

    private func handle(
        _ outcome: MailProjectSaveOutcome,
        reviewKind: ProjectConfigurationReviewKind
    ) {
        switch outcome {
        case let .saved(projectID, configurationRevision):
            cancelAutosave()
            reviewGeneration &+= 1
            completedSave = ProjectConfigurationSaveCompletion(
                projectID: projectID,
                configurationRevision: configurationRevision
            )
            draft = nil
            activationDraftFingerprint = nil
            preview = nil
            saveStatus = .idle
        case .reviewRequired(let refreshed):
            installPreview(refreshed, kind: reviewKind)
            saveStatus = .reviewRequired
        }
    }

    private func replaceDecision(
        targetKind: MailProjectDecisionTargetKind,
        targetID: UUID,
        decision: MailProjectDecisionValue
    ) {
        guard var value = draft else { return }
        value.manualDecisions.removeAll {
            $0.targetKind == targetKind && $0.targetID == targetID
        }
        value.manualDecisions.append(MailProjectDecisionSnapshot(
            id: UUID(),
            projectID: value.projectID,
            targetKind: targetKind,
            targetID: targetID,
            decision: decision,
            updatedAt: now()
        ))
        value.manualDecisions.sort { lhs, rhs in
            if lhs.targetKind.rawValue != rhs.targetKind.rawValue {
                return lhs.targetKind.rawValue < rhs.targetKind.rawValue
            }
            return lhs.targetID.uuidString < rhs.targetID.uuidString
        }
        draft = value
        preview = nil
    }

    private func replaceThreadDecision(
        _ threadID: UUID,
        decision: MailProjectDecisionValue
    ) {
        guard var value = draft else { return }
        value.manualDecisions.removeAll { existing in
            existing.targetKind == .thread && existing.targetID == threadID
        }
        value.manualDecisions.append(MailProjectDecisionSnapshot(
            id: UUID(),
            projectID: value.projectID,
            targetKind: .thread,
            targetID: threadID,
            decision: decision,
            updatedAt: now()
        ))
        value.manualDecisions.sort { lhs, rhs in
            if lhs.targetKind.rawValue != rhs.targetKind.rawValue {
                return lhs.targetKind.rawValue < rhs.targetKind.rawValue
            }
            return lhs.targetID.uuidString < rhs.targetID.uuidString
        }
        draft = value
        preview = nil
    }

    private func loadCatalog(
        selectedValuesByFacet: [MailProjectRuleFacet: Set<String>]
    ) throws -> MailProjectRuleCatalogSnapshot {
        try ManualProjectRuleCatalog(
            modelContext: ModelContext(container)
        ).snapshot(selectedValuesByFacet: selectedValuesByFacet)
    }

    private func loadLiveConfiguration(
        projectID: UUID
    ) throws -> MailProjectConfigurationSnapshot {
        let context = ModelContext(container)
        guard let project = try context.fetch(FetchDescriptor<MailProject>())
            .first(where: { $0.id == projectID }) else {
            throw ManualProjectConfigurationServiceError.projectNotFound(projectID)
        }
        let groups = try project.ruleGroups.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.id.uuidString < rhs.id.uuidString
        }.map { group in
            MailProjectRuleGroupSnapshot(
                id: group.id,
                kind: group.kind,
                sortIndex: group.sortIndex,
                conditions: try group.conditions.sorted { lhs, rhs in
                    if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                    return lhs.id.uuidString < rhs.id.uuidString
                }.map { condition in
                    MailProjectRuleConditionSnapshot(
                        id: condition.id,
                        facet: condition.facet,
                        polarity: condition.polarity,
                        quantifier: condition.quantifier,
                        values: try condition.values(),
                        correspondentRole: condition.correspondentRole,
                        keywordScopes: Set(try condition.keywordScopes()),
                        keywordOperator: condition.keywordOperator,
                        sortIndex: condition.sortIndex
                    )
                }
            )
        }
        let decisions = try context.fetch(FetchDescriptor<MailProjectDecision>())
            .filter { $0.projectID == projectID }
            .map { decision in
                MailProjectDecisionSnapshot(
                    id: decision.id,
                    projectID: decision.projectID,
                    targetKind: decision.targetKind,
                    targetID: decision.targetID,
                    decision: decision.decision,
                    updatedAt: decision.updatedAt
                )
            }
        return MailProjectConfigurationSnapshot(
            projectID: project.id,
            existingProjectID: project.id,
            displayName: project.displayName,
            accountIDs: Set(try project.accountIDs()),
            automaticIntakeStartAt: project.automaticIntakeStartAt,
            baseConfigurationRevision: project.configurationRevision,
            groups: groups,
            manualDecisions: decisions,
        )
    }

    private func decodeDraft(
        _ snapshot: MailProjectConfigurationDraftSnapshot
    ) throws -> MailProjectConfigurationSnapshot {
        guard snapshot.payloadVersion == 1,
              let data = snapshot.payloadJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                  MailProjectConfigurationSnapshot.self,
                  from: data
              ) else {
            throw ManualProjectConfigurationServiceError.malformedDraft
        }
        return decoded
    }

    private func route(
        for configuration: MailProjectConfigurationSnapshot
    ) -> ProjectConfigurationRoute {
        configuration.existingProjectID.map(ProjectConfigurationRoute.existingProject)
            ?? .newProject
    }

    private func selectedValuesByFacet(
        _ configuration: MailProjectConfigurationSnapshot
    ) -> [MailProjectRuleFacet: Set<String>] {
        var result: [MailProjectRuleFacet: Set<String>] = [
            .account: Set(configuration.accountIDs.map(\.uuidString))
        ]
        for condition in configuration.groups.flatMap(\.conditions) {
            result[condition.facet, default: []].formUnion(condition.values)
        }
        return result
    }

    private func loadPreviewMessages(_ preview: MailProjectPreview) {
        let ids = Set(
            preview.willBeAdded.map(\.messageID)
                + preview.willBeRemoved.map(\.messageID)
                + preview.unchangedExceptions.map(\.messageID)
        )
        guard ids.isEmpty == false else {
            previewMessagesByID = [:]
            return
        }
        do {
            let context = ModelContext(container)
            previewMessagesByID = Dictionary(uniqueKeysWithValues: try context
                .fetch(FetchDescriptor<Message>())
                .filter { ids.contains($0.id) }
                .map { message in
                    let result = ProjectHistoricalSearchService.result(for: message)
                    return (result.messageID, result)
                })
        } catch {
            previewMessagesByID = [:]
        }
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func isMalformedDraft(_ error: any Error) -> Bool {
        guard let error = error as? ManualProjectConfigurationServiceError else { return false }
        if case .malformedDraft = error { return true }
        return false
    }

    private static func message(for error: any Error) -> String {
        if let error = error as? ProjectConfigurationOpenError {
            switch error {
            case .draftMustBeOpenedFromProjects:
                return "A project draft is already saved. Return to Projects and open or delete it from the Drafts section."
            case .draftNoLongerExists:
                return "This project draft no longer exists. Return to Projects and choose another project."
            case .legacyUnnamedDraftMustBeOpenedAsNewProject:
                return "Unnamed project work is already saved. Return to Projects and choose New Project to continue it."
            }
        }
        if let error = error as? ProjectConfigurationDraftNameError {
            switch error {
            case .reservedPlaceholder:
                return "Replace “Untitled Project” with a specific project name before continuing."
            }
        }
        if let error = error as? MailProjectNameError {
            switch error {
            case .emptyName: return "Enter a project name before continuing."
            }
        }
        if let error = error as? ManualProjectConfigurationServiceError {
            switch error {
            case .projectNotFound:
                return "This project no longer exists."
            case .projectIdentityMismatch:
                return "The draft no longer matches this project. Reopen configuration and try again."
            case .nameCollision(let name):
                return "A project named “\(name)” already exists. Choose a different name."
            case .invalidEarlierBoundary:
                return "The earlier-mail boundary is no longer valid. Refresh the review and try again."
            case .invalidConfiguration:
                return "Repair the highlighted rule conditions before continuing."
            case .invalidAccountScope:
                return "One or more selected accounts no longer exist."
            case .invalidManualDecision, .missingManualDecisionTarget:
                return "A selected message or thread no longer exists. Remove it and try again."
            case .duplicateManualDecision:
                return "The draft contains conflicting manual membership choices."
            case .unstableSourceSnapshot:
                return "Mail changed while the preview was being prepared. Try refreshing again."
            case .malformedDraft:
                return "The saved project draft could not be read. Discard it and continue."
            case .malformedProvenance:
                return "Membership details could not be prepared. Retry the preview."
            }
        }
        return error.localizedDescription
    }

    private static func broadCorrespondentGroup(
        stableKey: String,
        role: MailProjectCorrespondentRole,
        sortIndex: Int
    ) -> ProjectRuleGroupDraft {
        correspondentGroup(
            stableKey: stableKey,
            role: role,
            localConditions: [],
            sortIndex: sortIndex
        )
    }

    private static func correspondentGroup(
        stableKey: String,
        role: MailProjectCorrespondentRole,
        localConditions: [ProjectRuleConditionDraft],
        sortIndex: Int
    ) -> ProjectRuleGroupDraft {
        ProjectRuleGroupDraft(
            kind: .match,
            sortIndex: sortIndex,
            conditions: [
                ProjectRuleConditionDraft(
                    facet: .correspondent,
                    values: [stableKey],
                    correspondentRole: role,
                    sortIndex: 0
                ),
            ] + localConditions.enumerated().map { index, condition in
                ProjectRuleConditionDraft(
                    facet: condition.facet,
                    polarity: condition.polarity,
                    quantifier: condition.quantifier,
                    values: condition.values,
                    correspondentRole: condition.correspondentRole,
                    keywordScopes: condition.keywordScopes,
                    keywordOperator: condition.keywordOperator,
                    sortIndex: index + 1
                )
            }
        )
    }

    private static func correspondentPathTemplates(
        for stableKey: String,
        in groups: [ProjectRuleGroupDraft]
    ) -> [CorrespondentPathTemplate] {
        var seen: Set<String> = []
        var result: [CorrespondentPathTemplate] = []
        for group in groups where group.kind == .match {
            guard let correspondentCondition = group.conditions.first(where: {
                $0.facet == .correspondent
                    && $0.polarity == .include
                    && $0.values.contains(stableKey)
            }) else { continue }
            let local = group.conditions.filter { $0.facet != .correspondent }
            let storedRole = correspondentCondition.correspondentRole ?? .involves
            let roles = storedRole == .involves ? visibleCorrespondentRoles : [storedRole]
            for role in roles {
                let fingerprint = ([role.rawValue]
                    + local.sorted(by: conditionSemanticOrder).map(conditionSemanticKey))
                    .joined(separator: "|")
                if seen.insert(fingerprint).inserted {
                    result.append(CorrespondentPathTemplate(
                        role: role,
                        localConditions: local
                    ))
                }
            }
        }
        return result
    }

    private static func correspondentCategoryRestrictions(
        for stableKey: String,
        in groups: [ProjectRuleGroupDraft]
    ) -> [ProjectRuleConditionDraft] {
        var excluded: [MailProjectRuleFacet: Set<String>] = [:]
        for template in correspondentPathTemplates(for: stableKey, in: groups) {
            for condition in template.localConditions
                where categoryFacets.contains(condition.facet)
                    && condition.polarity == .exclude {
                excluded[condition.facet, default: []].formUnion(condition.values)
            }
        }
        return excluded.keys.sorted(by: { $0.rawValue < $1.rawValue }).map { facet in
            ProjectRuleConditionDraft(
                facet: facet,
                polarity: .exclude,
                quantifier: .any,
                values: excluded[facet, default: []].sorted(),
                sortIndex: 0
            )
        }
    }

    private struct CorrespondentPathTemplate {
        let role: MailProjectCorrespondentRole
        let localConditions: [ProjectRuleConditionDraft]
    }

    private static func conditionSemanticKey(_ condition: ProjectRuleConditionDraft) -> String {
        [
            condition.facet.rawValue,
            condition.polarity.rawValue,
            condition.quantifier.rawValue,
            condition.values.sorted().joined(separator: ","),
            condition.correspondentRole?.rawValue ?? "",
            condition.keywordScopes.map(\.rawValue).sorted().joined(separator: ","),
            condition.keywordOperator?.rawValue ?? "",
        ].joined(separator: "#")
    }

    private static func conditionSemanticOrder(
        _ lhs: ProjectRuleConditionDraft,
        _ rhs: ProjectRuleConditionDraft
    ) -> Bool {
        conditionSemanticKey(lhs) < conditionSemanticKey(rhs)
    }

    private static func categoryOnlyGroup(
        _ groups: [ProjectRuleGroupDraft],
        kind: MailProjectRuleGroupKind,
        facet: MailProjectRuleFacet,
        key: String
    ) -> Bool {
        groups.contains { group in
            group.kind == kind
                && group.conditions.count == 1
                && group.conditions[0].facet == facet
                && group.conditions[0].values.contains(key)
        }
    }

    private static func removeCategoryOnlyValue(
        _ key: String,
        facet: MailProjectRuleFacet,
        from groups: inout [ProjectRuleGroupDraft]
    ) {
        for groupIndex in groups.indices.reversed() {
            guard groups[groupIndex].conditions.count == 1,
                  groups[groupIndex].conditions[0].facet == facet,
                  groups[groupIndex].kind == .match
                    || groups[groupIndex].kind == .projectWideExclusion else { continue }
            groups[groupIndex].conditions[0].values.removeAll { $0 == key }
            if groups[groupIndex].conditions[0].values.isEmpty {
                groups.remove(at: groupIndex)
            }
        }
    }

    private static func isBroadCorrespondentGroup(_ group: ProjectRuleGroupDraft) -> Bool {
        guard group.kind == .match,
              group.conditions.count == 1,
              let condition = group.conditions.first else { return false }
        return condition.facet == .correspondent
            && condition.polarity == .include
    }

    private static func matchGroups(
        in groups: [ProjectRuleGroupDraft],
        contain stableKey: String
    ) -> Bool {
        groups.contains { group in
            group.kind == .match
                && group.conditions.contains { condition in
                    condition.facet == .correspondent
                        && condition.polarity == .include
                        && condition.values.contains(stableKey)
                }
        }
    }

    private static func removeCorrespondent(
        _ stableKey: String,
        from groups: inout [ProjectRuleGroupDraft]
    ) {
        for groupIndex in groups.indices.reversed() where groups[groupIndex].kind == .match {
            var removedFromGroup = false
            for conditionIndex in groups[groupIndex].conditions.indices.reversed()
                where groups[groupIndex].conditions[conditionIndex].facet == .correspondent
                    && groups[groupIndex].conditions[conditionIndex].polarity == .include {
                let countBefore = groups[groupIndex].conditions[conditionIndex].values.count
                groups[groupIndex].conditions[conditionIndex].values.removeAll { $0 == stableKey }
                removedFromGroup = removedFromGroup
                    || groups[groupIndex].conditions[conditionIndex].values.count != countBefore
                if groups[groupIndex].conditions[conditionIndex].values.isEmpty {
                    groups[groupIndex].conditions.remove(at: conditionIndex)
                }
            }
            if removedFromGroup,
               groups[groupIndex].conditions.contains(where: {
                   $0.facet == .correspondent && $0.polarity == .include
               }) == false {
                groups.remove(at: groupIndex)
            }
        }
    }

    private static func removeCorrespondentsFromBroadPaths(
        _ stableKeys: Set<String>,
        excluding excludedGroupID: UUID? = nil,
        in groups: inout [ProjectRuleGroupDraft]
    ) {
        for groupIndex in groups.indices.reversed()
            where groups[groupIndex].id != excludedGroupID
                && isBroadCorrespondentGroup(groups[groupIndex]) {
            groups[groupIndex].conditions[0].values.removeAll { stableKeys.contains($0) }
            if groups[groupIndex].conditions[0].values.isEmpty {
                groups.remove(at: groupIndex)
            }
        }
    }

    private static func correspondentRoles(
        in group: ProjectRuleGroupDraft
    ) -> [String: MailProjectCorrespondentRole] {
        group.conditions
            .filter { $0.facet == .correspondent && $0.polarity == .include }
            .reduce(into: [:]) { result, condition in
                for key in condition.values {
                    result[key] = condition.correspondentRole ?? .involves
                }
            }
    }

    private static func restoreBroadCorrespondentPaths(
        _ rolesByKey: [String: MailProjectCorrespondentRole],
        in groups: inout [ProjectRuleGroupDraft]
    ) {
        for key in rolesByKey.keys.sorted()
            where matchGroups(in: groups, contain: key) == false {
            groups.append(broadCorrespondentGroup(
                stableKey: key,
                role: rolesByKey[key] ?? .involves,
                sortIndex: groups.count
            ))
        }
    }

    private static func coalesceSharedCriteriaGroups(
        in groups: inout [ProjectRuleGroupDraft]
    ) {
        let sharedIndices = groups.indices.filter { groups[$0].kind == .sharedCriteria }
        guard let first = sharedIndices.first else { return }
        groups[first].conditions = sharedIndices.flatMap { groups[$0].conditions }
        for index in sharedIndices.dropFirst().reversed() {
            groups.remove(at: index)
        }
    }

    private func reviewRequestIsCurrent(
        _ generation: Int,
        fingerprint: ProjectConfigurationDraftFingerprint
    ) -> Bool {
        reviewGeneration == generation
            && draftFingerprint == fingerprint
            && completedSave == nil
    }

    private func finishStaleReviewRequestIfNeeded(_ generation: Int) {
        guard reviewGeneration == generation, completedSave == nil else { return }
        stage = .configure
        saveStatus = .idle
    }

    private static func normalizeGroupOrder(_ groups: inout [ProjectRuleGroupDraft]) {
        for groupIndex in groups.indices {
            groups[groupIndex].sortIndex = groupIndex
            for conditionIndex in groups[groupIndex].conditions.indices {
                groups[groupIndex].conditions[conditionIndex].sortIndex = conditionIndex
                groups[groupIndex].conditions[conditionIndex].values = Array(Set(
                    groups[groupIndex].conditions[conditionIndex].values
                )).sorted()
            }
        }
    }

    private static let keywordFacets: Set<MailProjectRuleFacet> = [
        .subject, .body, .attachmentFilename, .attachmentText,
    ]

    private static let categoryFacets: Set<MailProjectRuleFacet> = [
        .fixedCategory, .customCategory,
    ]

    private static let visibleCorrespondentRoles: [MailProjectCorrespondentRole] = [
        .from, .to, .cc, .bcc,
    ]
}
