// Ohia/ConstellationMode/ConstellationModeView.swift
import SwiftUI
import AppKit
import Combine
import SwiftData
import simd
import os
import OhiaCore
import OhiaIngest
import OhiaMail
import OhiaML
import OhiaScheduler

private enum ConstellationLog {
    nonisolated static let logger = Logger(subsystem: "com.ohia.app", category: "Constellation")
}

@MainActor
struct CompletedMailboxVisibilityDeparture: Equatable {
    let messageIDs: Set<UUID>
    let action: MessageStatusGestureAction

    static func resolve(
        event: JobCompletionEvent,
        context: ModelContext
    ) -> CompletedMailboxVisibilityDeparture? {
        let completedMessageIDs = CompletionMailboxVisibilityRefresh.messageIDs(
            in: event
        )
        let completionContext = ModelContext(context.container)
        guard completedMessageIDs.isEmpty == false,
              let mutations = try? completionContext.fetch(
                  FetchDescriptor<MailboxMutation>()
              ) else {
            return nil
        }
        let junkMessageIDs = mutations.reduce(into: Set<UUID>()) {
            messageIDs, mutation in
            guard completedMessageIDs.contains(mutation.messageID),
                  mutation.kind == .moveToJunk,
                  mutation.status == .succeeded,
                  mutation.localFinalizedAt != nil else {
                return
            }
            messageIDs.insert(mutation.messageID)
        }
        guard junkMessageIDs.isEmpty == false else { return nil }
        return CompletedMailboxVisibilityDeparture(
            messageIDs: junkMessageIDs,
            action: .ignore
        )
    }

    func begin(
        on coordinator: MessageStatusGestureCoordinator,
        now: Date = .now
    ) -> Double {
        coordinator.begin(
            action,
            for: messageIDs.sorted { $0.uuidString < $1.uuidString },
            now: now
        )
        return coordinator.remainingDepartingHold(now: now)
    }
}

/// Selects the hard message boundary for Search and Ask while a lens is in
/// its focused reading state. Focused retrieval deliberately carries none of
/// the constellation's account, time, status, category, or attachment gates.
enum FocusedRetrievalScopePolicy {
    enum Kind: Sendable, Equatable {
        case thread
        case correspondent
        case project
    }

    nonisolated static func kind(
        for frame: FrameKey,
        hasMetalFocus: Bool,
        hasFrontPageFocus: Bool,
        hasTimelineFocus: Bool,
        hasProjectFocus: Bool
    ) -> Kind? {
        switch frame.spatialLens {
        case .frontPage:
            return hasFrontPageFocus ? .thread : nil
        case .timeline:
            return hasTimelineFocus ? .thread : nil
        case .meaning:
            return hasMetalFocus ? .thread : nil
        case .people:
            return hasMetalFocus ? .correspondent : nil
        case .projects:
            return hasProjectFocus ? .project : nil
        default:
            return nil
        }
    }

    nonisolated static func filterSpec(
        messageIDs: Set<String>,
        collections: Set<VectorCollection>
    ) -> FilterSpec {
        FilterSpec(
            collections: collections.sorted { $0.rawValue < $1.rawValue },
            allowedMessageIds: messageIDs.sorted()
        )
    }

    nonisolated static func constrain(
        expansion: AskThreadExpansion,
        to messageIDs: Set<String>
    ) -> AskThreadExpansion {
        let additionalSources = expansion.additionalSources.filter {
            messageIDs.contains($0.record.messageId)
        }
        let contexts = expansion.contexts.compactMap { context -> AskThreadContext? in
            let messages = context.messages.filter { messageIDs.contains($0.messageId) }
            guard messages.isEmpty == false else { return nil }
            return AskThreadContext(
                threadId: context.threadId,
                subject: context.subject,
                anchorMessageIds: context.anchorMessageIds.filter(messageIDs.contains),
                messages: messages
            )
        }
        return AskThreadExpansion(
            additionalSources: additionalSources,
            contexts: contexts,
            visualEvidence: expansion.visualEvidence.filter { messageIDs.contains($0.messageId) }
        )
    }
}

/// Preserves the selected Front Page card's thread semantics after its
/// representative ID is expanded into the concrete emails moved to Trash.
struct FrontPageThreadDeleteTarget: Equatable {
    struct Confirmation: Equatable {
        let messageText: String
        let informativeText: String
    }

    let messageIDs: [UUID]
    let confirmation: Confirmation?

    static func resolve(
        requested: [UUID],
        selectedCardIDs: Set<UUID>,
        composition: FrontPageComposition?,
        hasFocusedArticle: Bool
    ) -> FrontPageThreadDeleteTarget {
        let unchanged = FrontPageThreadDeleteTarget(messageIDs: requested, confirmation: nil)
        guard hasFocusedArticle == false,
              selectedCardIDs.count == 1,
              let selectedCardID = selectedCardIDs.first,
              let composition else {
            return unchanged
        }

        let composed = [composition.lead].compactMap { $0 }
            + composition.features
            + composition.sections.flatMap(\.articles)
        guard let selectedArticle = composed.first(where: { $0.id == selectedCardID }),
              let thread = selectedArticle.thread else {
            return unchanged
        }

        var seen = Set<UUID>()
        let memberIDs = thread.members.map(\.id).filter { seen.insert($0).inserted }
        let requestedSet = Set(requested)
        guard requestedSet == [selectedCardID] || requestedSet == Set(memberIDs) else {
            return unchanged
        }

        let count = memberIDs.count
        let noun = count == 1 ? "email" : "emails"
        let pronoun = count == 1 ? "It" : "They"
        return FrontPageThreadDeleteTarget(
            messageIDs: memberIDs,
            confirmation: Confirmation(
                messageText: "Delete this thread?",
                informativeText: "This thread contains \(count) \(noun). \(pronoun) will be moved to the account Trash mailbox."
            )
        )
    }
}

struct FrontPageThreadReadTarget {
    static func messageIDs(
        representativeID: UUID,
        composition: FrontPageComposition?
    ) -> [UUID] {
        guard let composition else { return [representativeID] }
        let composed = [composition.lead].compactMap { $0 }
            + composition.features
            + composition.sections.flatMap(\.articles)
        guard let thread = composed.first(where: { $0.id == representativeID })?.thread else {
            return [representativeID]
        }

        var seen = Set<UUID>()
        return thread.members.map(\.id).filter { seen.insert($0).inserted }
    }
}

@MainActor
enum SendAgainDraftFactory {
    private enum BodyLoad {
        case absent
        case loaded(String)
        case unavailable

        var value: String? {
            guard case .loaded(let value) = self else { return nil }
            return value
        }

        var isAbsent: Bool {
            if case .absent = self { return true }
            return false
        }
    }

    struct PreparedDraft {
        let draft: Draft
        let account: Account
        let identity: Identity
    }

    enum Error: Swift.Error, LocalizedError {
        case accountUnavailable
        case identityUnavailable(String)
        case bodyUnavailable
        case attachmentUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .accountUnavailable:
                "The account used to send this message is no longer available."
            case .identityUnavailable(let address):
                "The sending identity \(address) is no longer available."
            case .bodyUnavailable:
                "The original message body is no longer available."
            case .attachmentUnavailable(let filename):
                "The attachment \(filename) is no longer available."
            }
        }
    }

    static func prepare(
        from message: Message,
        context: ModelContext,
        inlinePhotoStore: ComposerInlinePhotoStore = ComposerInlinePhotoStore()
    ) async throws -> PreparedDraft {
        guard let account = resolvedAccount(for: message, context: context) else {
            throw Error.accountUnavailable
        }
        guard let identity = resolvedIdentity(for: message, account: account) else {
            throw Error.identityUnavailable(message.fromAddress)
        }

        async let plainBodyLoad = loadBody(at: message.bodyTextPath)
        async let htmlBodyLoad = loadBody(at: message.bodyHtmlPath)
        let (plainResult, htmlResult) = await (plainBodyLoad, htmlBodyLoad)
        let plainBody = plainResult.value
        var htmlBody = htmlResult.value
        let isGenuinelyBodyless = plainResult.isAbsent && htmlResult.isAbsent
        guard plainBody != nil || htmlBody != nil || isGenuinelyBodyless else {
            throw Error.bodyUnavailable
        }

        let draft = Draft.userCompose(
            fromAccountID: account.id,
            identityID: identity.id
        )
        var inlinePhotos: [ComposerInlinePhotoAsset] = []
        var ordinaryAttachmentPaths: [String] = []

        do {
            for attachment in message.attachments {
                guard let path = attachment.filePath,
                      FileManager.default.fileExists(atPath: path) else {
                    throw Error.attachmentUnavailable(attachment.filename)
                }

                let contentID = attachment.contentId?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let hasReplaceableInlineSource = contentID.map { contentID in
                    htmlBody.map { htmlContainsReplaceableInlineSource($0, contentID: contentID) } == true
                } ?? false
                let isReferencedInlineImage = attachment.mimeType.lowercased()
                    .hasPrefix("image/")
                    && contentID?.isEmpty == false
                    && hasReplaceableInlineSource

                if isReferencedInlineImage, let contentID {
                    let photo = try await inlinePhotoStore.importPhoto(
                        from: URL(fileURLWithPath: path),
                        sourceFileName: attachment.filename,
                        ownerID: draft.id
                    )
                    inlinePhotos.append(photo)
                    htmlBody = htmlBody.map {
                        replacingInlineImageSource(
                            in: $0,
                            contentID: contentID,
                            token: ComposerInlinePhotoToken.url(
                                ownerID: draft.id,
                                assetID: photo.id
                            )
                        )
                    }
                } else {
                    ordinaryAttachmentPaths.append(path)
                }
            }

            let recipients = recipientsByRole(message.participants)
            draft.composeSubject = message.subject.isEmpty ? nil : message.subject
            draft.composeToJSON = ComposeAddressEncoding.encode(recipients[.to] ?? [])
            draft.composeCcJSON = ComposeAddressEncoding.encode(recipients[.cc] ?? [])
            draft.composeBccJSON = ComposeAddressEncoding.encode(recipients[.bcc] ?? [])
            draft.replyText = plainBody ?? htmlBody.map(plainProjection(of:)) ?? ""
            draft.bodyHTML = htmlBody
            draft.messageFormatRaw = htmlBody == nil
                ? ComposerMessageFormat.plainText.rawValue
                : ComposerMessageFormat.richText.rawValue
            draft.deliverablesJSON = ComposeAddressEncoding.encode(ordinaryAttachmentPaths)
            draft.inlinePhotosJSON = ComposerInlinePhotoAssetCoding.encode(inlinePhotos)
            draft.signatureSlotID = nil
            draft.stageRaw = DraftStage.drafted

            context.insert(draft)
            try ComposerDraftSyncScheduler.stageDraftSync(draft: draft, context: context)
            try context.save()
            return PreparedDraft(draft: draft, account: account, identity: identity)
        } catch {
            context.rollback()
            inlinePhotoStore.deletePhotos(ownerID: draft.id)
            throw error
        }
    }

    private static func resolvedAccount(for message: Message, context: ModelContext) -> Account? {
        if let account = message.account { return account }
        guard let accountID = message.accountID else { return nil }
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == accountID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func resolvedIdentity(for message: Message, account: Account) -> Identity? {
        let sender = message.fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = account.identities.first(where: {
            $0.address.caseInsensitiveCompare(sender) == .orderedSame
        }) {
            return exact
        }
        guard account.emailAddress.caseInsensitiveCompare(sender) == .orderedSame else {
            return nil
        }
        return account.primaryIdentity
    }

    @concurrent
    private static func loadBody(at path: String?) async -> BodyLoad {
        guard let path else { return .absent }
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .unavailable
        }
        return .loaded(body)
    }

    private static func recipientsByRole(
        _ links: [MessageParticipant]
    ) -> [ParticipantRole: [String]] {
        let indexed = Array(links.enumerated())
        return Dictionary(uniqueKeysWithValues: [ParticipantRole.to, .cc, .bcc].map { role in
            let addresses = indexed
                .filter { $0.element.role == role }
                .sorted { lhs, rhs in
                    switch (lhs.element.headerPosition, rhs.element.headerPosition) {
                    case let (left?, right?):
                        left == right ? lhs.offset < rhs.offset : left < right
                    case (_?, nil):
                        true
                    case (nil, _?):
                        false
                    case (nil, nil):
                        lhs.offset < rhs.offset
                    }
                }
                .compactMap { $0.element.participant?.emailAddress }
            return (role, addresses)
        })
    }

    private static func plainProjection(of html: String) -> String {
        let content = ComposerRichTextCodec.content(
            plainText: "",
            html: html,
            format: .richText
        )
        return ComposerRichTextCodec.plainBodyProjection(of: content)
    }

    private static func htmlContainsReplaceableInlineSource(
        _ html: String,
        contentID: String
    ) -> Bool {
        guard let regex = inlineImageSourceRegex(contentID: contentID) else { return false }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.firstMatch(in: html, range: range) != nil
    }

    private static func replacingInlineImageSource(
        in html: String,
        contentID: String,
        token: String
    ) -> String {
        guard let regex = inlineImageSourceRegex(contentID: contentID) else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.stringByReplacingMatches(
            in: html,
            range: range,
            withTemplate: "$1\(token)$2$3"
        )
    }

    private static func inlineImageSourceRegex(
        contentID: String
    ) -> NSRegularExpression? {
        let escapedID = NSRegularExpression.escapedPattern(for: contentID)
        let pattern = #"(?i)(<img\b[^>]*\bsrc\s*=\s*[\"'])cid:"#
            + escapedID
            + #"([\"'][^>]*)(>)"#
        return try? NSRegularExpression(pattern: pattern)
    }
}

private struct SceneRenderProgress: Equatable {
    let sequence: Int
    let reason: SceneRenderProgressReason
}

/// Bundles the per-message context needed to file a list-ignore directly — the
/// target message, its optional locked-overlay vector id to release, and the
/// post-mutation callbacks. Consumed by `confirmListIgnoreRule`.
private struct ListIgnoreDispatch {
    let messageID: UUID
    let vectorIdForOverlayRelease: Int64?
    let onAfterMessageMutation: (() -> Void)?
    let onAfterDelete: (() -> Void)?
}

private struct LensReadinessKey: Equatable {
    let onboardingMode: Bool
    let activeFrame: FrameKey
    let renderPacketFrame: FrameKey
    let renderPacketFilter: VectorFilter?
    let renderPacketGeneratedAt: TimeInterval
    let timelineSignature: TimelineLayoutSignature?
    let timelineExpectedSignature: TimelineLayoutSignature?
    let projectsSignature: ProjectsSnapshotSignature?
    let frontPageSignature: FrontPageSnapshotSignature?
}

private struct LiveInboundPresentationObservationKey: Equatable {
    let activeFrame: FrameKey
    let pendingMessageIDs: [String]
    let renderedMessageIDs: [String]
    let surfaceMarker: TimeInterval
}

private struct FocusedArrivalBadgeObservationKey: Equatable {
    let focusedMessageIDs: Set<String>
    let unvisitedArrivalIDs: Set<String>

    var messageIDsToRetire: Set<String> {
        focusedMessageIDs.intersection(unvisitedArrivalIDs)
    }
}

private struct LiveInboundPresentationGroup: Hashable {
    let accountID: UUID
    let folder: String
    let observedAt: Date
}

private struct PeopleLiveFocusGeometrySignature: Equatable {
    let hubMessageCount: Int
    let hubMessageChecksum: Int64
    let ringCount: Int
    let outerRingEdgeBucket: Int
    let hubXBucket: Int
    let hubYBucket: Int
    let hubZBucket: Int
}

private struct PeopleLiveFocusReframeKey: Equatable {
    let activeFrame: FrameKey
    let renderPacketFrame: FrameKey
    let lockedVectorId: Int64?
    let liveFocusEmail: String?
    let currentFilter: VectorFilter
    let renderedFilter: VectorFilter?
    let geometry: PeopleLiveFocusGeometrySignature
}

private struct MeaningClusterRecoveryKey: Equatable {
    let activeFrame: FrameKey
    let renderPacketFrame: FrameKey
    let displayCount: Int
    let visibleHubCount: Int
    let cachedClusterCount: Int
    let lockedVectorId: Int64?
    let onboardingMode: Bool
    let coldFirstPaintPending: Bool
}

private struct MeaningClusterStoreObservationKey: Equatable {
    let activeFrame: FrameKey
    let displayCount: Int
    let lockedVectorId: Int64?
    let onboardingMode: Bool
    let coldFirstPaintPending: Bool
}

struct MeaningClusterPublicationIdentity: Equatable, Sendable {
    let frame: FrameKey
    let clusters: [ClusterIdentity]

    init(frame: FrameKey, clusters: [ClusterRecord]) {
        self.frame = frame.spatialLens
        self.clusters = clusters
            .map(ClusterIdentity.init)
            .sorted { lhs, rhs in
                lhs.id < rhs.id
            }
    }

    var clusterCount: Int {
        clusters.count
    }

    struct ClusterIdentity: Equatable, Sendable {
        let id: Int64
        let frame: FrameKey
        let centroid: SIMD3<Float>
        let memberCount: Int
        let detectedAt: TimeInterval
        let label: String?

        init(cluster: ClusterRecord) {
            id = cluster.id
            frame = cluster.frameKey.spatialLens
            centroid = cluster.centroid
            memberCount = cluster.memberCount
            detectedAt = cluster.detectedAt.timeIntervalSince1970
            label = cluster.label
        }
    }
}

private struct DyingPersonWormholeItem: Identifiable {
    let id: String
    let anchor: CGPoint
    let startedAt: Date
}

private struct FrontPageSnapshotObservationKey: Equatable {
    let signature: FrontPageSnapshotSignature?
    let builtAt: Date?

    init(snapshot: FrontPageSnapshot?) {
        signature = snapshot?.signature
        builtAt = snapshot?.builtAt
    }
}

/// A display-ready completion value. Constructed in the background fetch so
/// publishing to the live UI map never parses or tokenizes summary prose.
nonisolated struct CompletedMessageSummary: Sendable {
    let messageID: String
    let summary: String?

    init(messageID: String, rawSummary: String?) {
        self.messageID = messageID
        summary = SummaryTextSanitizer.cleaned(rawSummary)
    }
}

private struct ProjectsSnapshotObservationKey: Equatable {
    let signature: ProjectsSnapshotSignature?
    let builtAt: Date?
    let hasRefreshInFlight: Bool

    init(snapshot: ProjectsSnapshot?, hasRefreshInFlight: Bool) {
        signature = snapshot?.signature
        builtAt = snapshot?.builtAt
        self.hasRefreshInFlight = hasRefreshInFlight
    }
}

private struct NotificationFocusCommandObserver: ViewModifier {
    let onRequest: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .ohiaShowConstellation)
        ) { _ in
            onRequest()
        }
    }
}

private struct ConstellationShortcutCommandObserver: ViewModifier {
    let onCommand: @MainActor (ConstellationShortcutCommand) -> Void

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .ohiaConstellationShortcut)
        ) { notification in
            guard let command = notification.object as? ConstellationShortcutCommand else {
                return
            }
            onCommand(command)
        }
    }
}

private struct NewProjectCommandObserver: ViewModifier {
    let onRequest: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .ohiaCreateNewProject)
        ) { _ in
            onRequest()
        }
    }
}

private struct ProcessPowerStateObserver: ViewModifier {
    let onChange: @MainActor (Bool) -> Void

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
        ) { _ in
            onChange(ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
    }
}

private struct ComposerQueueRailTarget: Equatable {
    let messageID: UUID
    let isInQueue: Bool
    let isEnabled: Bool
}

private enum SceneRenderProgressReason: Equatable {
    case frame(FrameKey)
    case filter
    case timeRange
    case search
    case clearSearch
}

enum SelectedNodeFocusCommitResult: Sendable, Equatable {
    case committed
    case unavailable
    case superseded
}

struct ConstellationFilterCameraResetRequest {
    let frame: FrameKey
    let filter: VectorFilter
    let meaningClusterDisplayLimit: Int?
    let peopleFocusExpandsToOneHop: Bool?
}

enum MeaningAutoReadTrigger {
    case hover
    case focusedMode
}

private struct ConstellationScenePreferenceObservationKey: Equatable {
    let vectorCollectionPrefsFingerprint: Int
    let peopleFocusExpandsToOneHop: Bool
}

/// One-shot alert content for custom-category lifecycle events that have no
/// other user-visible confirmation. See `ConstellationModeView`'s
/// `customCategoryTaggingNotice` and its `.alert` presentation.
struct CustomCategoryTaggingNotice: Identifiable {
    enum Kind {
        case created(displayName: String)
        case reachedThresholdWithoutDiversity(displayName: String)
        case activated(displayNames: [String])
    }

    let id = UUID()
    let kind: Kind

    var title: String {
        switch kind {
        case .created:
            return "Category Created"
        case .reachedThresholdWithoutDiversity:
            return "Needs a Second Correspondent"
        case .activated(let displayNames):
            return displayNames.count > 1 ? "Categories Active" : "Category Active"
        }
    }

    var message: String {
        switch kind {
        case .created(let displayName):
            let threshold = CustomMailCategory.activationExampleThreshold
            return "Tag \(threshold) emails with “\(displayName)” before it can be applied to future email automatically."
        case .reachedThresholdWithoutDiversity(let displayName):
            return "“\(displayName)” has enough tagged examples, but they're all from the same correspondent. Tag one from someone else to activate it."
        case .activated(let displayNames):
            let names = displayNames.map { "“\($0)”" }.joined(separator: " and ")
            let verb = displayNames.count > 1 ? "are" : "is"
            return "\(names) \(verb) now active and will be applied to matching future email automatically."
        }
    }
}

private struct CustomCategoryTaggingNoticeModifier: ViewModifier {
    @Binding var notice: CustomCategoryTaggingNotice?

    func body(content: Content) -> some View {
        content.alert(
            notice?.title ?? "",
            isPresented: Binding(
                get: { notice != nil },
                set: { isPresented in
                    if !isPresented { notice = nil }
                }
            )
        ) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice?.message ?? "")
        }
    }
}

@MainActor
final class ConstellationMetalRendererOwner: ObservableObject {
    private let makeRenderer: @MainActor () -> ConstellationMetalRenderer
    private lazy var storedRenderer = makeRenderer()

    var renderer: ConstellationMetalRenderer {
        storedRenderer
    }

    init() {
        self.makeRenderer = { ConstellationMetalRenderer() }
    }

    init(makeRenderer: @escaping @MainActor () -> ConstellationMetalRenderer) {
        self.makeRenderer = makeRenderer
    }
}

public struct ConstellationModeView: View {
    private static let lensLoadingFrameSentinel: FrameKey = "__loading__"

    // Custom Metal is the production Constellation renderer. The retired scene path is no
    // longer part of the active render path. The renderer is expensive to construct, so its
    // retained owner defers creation until SwiftUI mounts this view instead of rebuilding
    // every Metal pipeline for transient view values produced during body evaluation.
    @StateObject private var metalRendererOwner = ConstellationMetalRendererOwner()
    private var metalRenderer: ConstellationMetalRenderer {
        metalRendererOwner.renderer
    }
    /// The latest planner output, before any death-animation augmentation.
    /// `renderPacket` is `basePacket` plus any in-flight dying-node ghosts;
    /// holding them separately lets a camera move during a death animation
    /// re-plan the base while keeping the ghost stars alive in the render
    /// packet until their collapse completes.
    @State private var basePacket: ConstellationRenderPacket = .empty
    @State private var renderPacket: ConstellationRenderPacket = .empty
    @State private var renderPacketFrame: FrameKey = .defaultFrame
    @State private var renderPacketFilter: VectorFilter?
    @State private var renderPacketDisplayRequest: ConstellationMetalDisplayRequest?
    @State private var renderPacketGeneration: UInt64?
    @State private var renderPacketHydratedGeneration: UInt64?
    @State private var renderPacketFilterCameraResetSignature: ConstellationFilterCameraResetRequest?
    @State private var dyingSnapshots: [DyingNodeSnapshot] = []
    @State private var dyingPersonSnapshots: [DyingPersonSnapshot] = []
    @State private var birthingSnapshots: [BirthingNodeSnapshot] = []
    @State private var animationTickerTask: Task<Void, Never>?
    @State private var renderStats: ConstellationMetalFrameStats?
    @State private var adaptiveRenderBudget = AdaptiveRenderBudgetController()
    @State private var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var renderRefreshInFlight = false
    @State private var renderRefreshPending = false
    @State private var sceneRefreshGeneration: UInt64 = 0
    /// Non-observable process state: completion bursts mutate the accumulator
    /// without invalidating this very large SwiftUI view body.
    @State private var completionRefresh = CompletionRefreshCoordinator()
    @State private var retainedMetalSurfaces: [FrameKey: ConstellationRetainedMetalSurface] = [:]
    @State private var coldFirstPaintRequest: ConstellationMetalDisplayRequest?
    @State private var coldFirstPaintAwaitingFirstDraw: ConstellationMetalDisplayRequest?
    @State private var coldFirstPaintPacketGeneratedAts: Set<TimeInterval> = []
    @State private var coldFirstPaintStartedAt: UInt64?
    @State private var sceneRenderProgress: SceneRenderProgress?
    @State private var sceneRenderProgressVisible = false
    @State private var sceneRenderProgressRevealTask: Task<Void, Never>?
    @State private var sceneRenderSequence = 0
    @State private var lastPlannedCameraSignature = CameraPlanningSignature.unset
    @State private var lastPersistedCameraSignature = CameraPlanningSignature.unset
    @State private var framesWithSessionCameraState: Set<FrameKey> = []
    @State private var pendingCameraRestoreFrame: FrameKey?
    @State private var pendingFilterCameraReset: ConstellationFilterCameraResetRequest?
    @State private var visibleRecordCache: [Int64: VectorRecord] = [:]
    @State private var searchResultRecordCache: [Int64: VectorRecord] = [:]

    // CameraController and FlightInputHandler are ObservableObject only for
    // `@StateObject` identity — neither publishes (`state` / `currentCommand`
    // are plain `var`s). They're written from the Metal view frame callback
    // every frame, so publishing would trip SwiftUI's "Publishing changes
    // from within view updates" runtime warning. Constructed in init so the
    // shared CameraController instance is also passed to WarpAnimator.
    @StateObject private var cameraController: CameraController
    @StateObject private var flightInput: FlightInputHandler
    /// Drives the affinity-rank step navigator inside the locked-node overlay.
    /// Owned here so the outer `onKeyDown` chain can call `step(by:)` / `exit()`
    /// without the overlay having to grab first-responder.
    @State private var lockNeighbourRank = LockNeighbourRankController()

    // WarpAnimator is NOT ObservableObject — use plain @State.
    @State private var warpAnimator: WarpAnimator

    // Orbital clock + mouse-damping state machine for the People solar
    // system. Plain @State (not observable): the draw loop reads it every
    // frame; SwiftUI only needs the stable identity.
    @State private var peopleOrbitalMotion = PeopleOrbitalMotionController()
    // Persisted so the orbit-line visibility survives lens switches and
    // app restarts, like the other HUD display prefs below.
    @AppStorage("constellationHidesPeopleOrbitPaths") private var hidesPeopleOrbitPaths = false

    // Sun hover readout (the user's aggregate correspondence card).
    @State private var hoveredSunReadout = false

    // Bridges deletion notifications into the Metal render/cache pipeline.
    // Held as a non-observable cache: the bridge has no @Observable state of
    // its own — consumers subscribe to `deletions` via `.onReceive`.
    @State private var deletionEvents = ConstellationDeletionEventBridge.shared
    @State private var renderPlanner: ConstellationRenderPlanner

    // ConstellationState is @Observable @MainActor — use @State.
    @State private var state: ConstellationState
    /// Stable reference target for this window's native semantic Undo/Redo stack.
    /// Composer text editing continues to use the focused NSTextView's own stack.
    @State private var messageUndoTarget = OhiaMessageUndoTarget()

    // LexicalSearchController is @MainActor; use @State.
    @State private var lexicalController: LexicalSearchController
    // Last search result, active lane, and active match-navigator index.
    @State private var lexicalResult: LexicalSearchResult?
    @State private var selectedSearchLane: LexicalSearchLane?
    @State private var searchMatchIndex: Int = 0
    @State private var searchWarpNavigationActive = false
    @State private var semanticSearchPreparationTask: Task<Void, Never>?
    @State private var semanticSearchPendingQuery: String?
    @State private var semanticSearchPreparationSequence = 0

    // Q&A panel state.
    @State private var qaVM: QAViewModel
    @State private var highlighter = CitationHighlighter()
    /// One-shot send-to-Composer dispatch comets, keyed by message id; read by the
    /// lens overlays. Fired by every send path so the cue is uniform.
    @State private var composerDispatch = ComposerDispatchCoordinator()
    @State private var composerSoundPlayer = NewStarAlertSoundPlayer()

    // New inbound star queue and view size (for screen-space projection).
    @State private var newStarNavigator = NewStarNavigator()
    @State private var manualRefresh = ManualRefreshCoordinator()
    @State private var pendingMetalNewStar: PendingMetalNewStar?
    @State private var pendingTimelineNewStar: PendingTimelineNewStar?
    @State private var pendingProjectsNewStarMessageID: UUID?
    @State private var pendingFrontPageNewStarMessageID: UUID?
    @State private var pendingFrontPageNewStarHydrationTask: Task<Void, Never>?
    @State private var pendingFrontPageNewStarHydrationSequence = 0
    @State private var pendingLiveInboundPresentations: [String: IMAPLiveInboundPayload] = [:]
    @State private var renderedLiveInboundMessageIDs: Set<String> = []
    @State private var notificationFocusRefreshRequested = false
    @State private var queuedNotificationFocusMessageID: UUID?
    @State private var pendingTimelineAskCitation: PendingTimelineAskCitation?
    @State private var pendingProjectsAskCitationMessageID: UUID?
    @State private var pendingFrontPageAskCitationMessageID: UUID?

    // Mirrors the onboarding gate used for live IMAP work. The manual-refresh
    // affordance stays unavailable until the first-ingestion witness releases
    // provider synchronization.
    @AppStorage("hasCompletedFirstIngestion", store: OhiaSharedDefaults.store)
    private var hasCompletedFirstIngestion = false
    @AppStorage(
        OnboardingPipelineGate.hasReachedWitnessPanelKey,
        store: OhiaSharedDefaults.store
    )
    private var hasReachedOnboardingWitnessPanel = false
    @State private var viewSize: CGSize = .zero
    @State private var searchDetailFrameInTransitionSpace: CGRect = .zero
    @State private var withheldDetailFrameInTransitionSpace: CGRect = .zero
    @State private var selectedNodeFocusRestoreCamera: CameraState?
    @State private var selectedNodeFocusWorld: SIMD3<Float>?
    /// Camera captured the moment a Meaning-lens cluster filter is engaged, so
    /// removing the filter can reverse-warp back to exactly where the user was
    /// (mirroring node-focus enter/exit). `nil` when no cluster filter is active.
    @State private var clusterFilterRestoreCamera: CameraState?
    /// Meaning-cluster hub geometry from the broad scene that started the
    /// current cluster-filter session. Retained while filtered so switching
    /// A -> B can still frame B even after the live packet has contracted to A.
    @State private var clusterFilterSourceHubs: [MeaningClusterHubInstance] = []
    /// Invalidates delayed cluster-filter writes when another cluster action or
    /// a lens switch supersedes an in-flight focus-style transition.
    @State private var clusterFilterTransitionSequence = 0
    /// The transition sequence that currently owns `warpAnimator` for a
    /// cluster-filter enter/exit. Used to cancel that Meaning-specific flight
    /// if the user switches lenses before it settles.
    @State private var clusterFilterWarpSequence: Int?
    /// Cluster id of an engage whose filter write is still deferred to its
    /// warp's contraction point (~88% of a 2s+ flight). The cluster list's
    /// multi-select toggle folds this into the effective scope so a second
    /// toggle during the flight widens the selection instead of silently
    /// replacing it, and list rows can check themselves immediately.
    @State private var pendingMeaningClusterEngageId: Int64?
    /// Set true by the cluster-filter handlers right before they mutate
    /// `state.filter.clusterIds`, so the normal filter-change observer does
    /// not re-arm the reset. The cluster path queues the reset itself and
    /// applies it only after the focus-style warp settles.
    @State private var suppressFilterCameraReset = false
    @State private var lockedNodeSelectionFallbackPoint: CGPoint?
    @State private var lockedNodeSelectionTransitionPoint: CGPoint?
    /// Suppresses the generic node-lock reticle while a People correspondent
    /// lock is entering. That reticle is correct for email-node locks, but a
    /// correspondent lock uses the hub's representative message vector as an
    /// implementation detail; drawing a reticle there makes an unselected ring
    /// email look selected during the Saturn transition.
    @State private var suppressedPendingLockIndicatorVectorId: Int64?
    @State private var revealedLockedVectorId: Int64?
    @State private var lockRevealSequence = 0
    @State private var lockEntryEnrichmentToken: LockEntryEnrichmentToken?
    @State private var lockSummaryInFlightToken: LockEntryEnrichmentToken?
    @State private var relatedSummaryPrewarmTask: Task<Void, Never>?
    @State private var lockedOverlayProjectionDriver = LockedOverlayProjectionDriver()
    @State private var pendingFocusClick: PendingFocusClick?
    @State private var pendingFocusClickSequence = 0
    /// Mirror of the active LockedPersonFocus while the user is locked
    /// on a correspondent Saturn in the People lens. Drives both the
    /// renderer's `PeopleFrameFocus` narrowing (so the constellation
    /// renders just that one Saturn with its rings) and the live
    /// `LockedNodeOverlay`'s chrome-suppression / focal-pane mode. Set
    /// in `enterSelectedNodeFocus` for the People-correspondent path,
    /// cleared in `leaveSelectedNodeFocus`.
    @State private var liveLockPersonFocus: LockedPersonFocus?
    /// Message id of the People-lens ring satellite the user has click-selected
    /// inside a correspondent lock. Drives the selection highlight + the action
    /// disc group in `peopleFocusCloseButtonColumn`. Cleared on empty-click,
    /// Esc, and lock release. Only meaningful while `liveLockPersonFocus != nil`.
    @State private var lockedRingSelectionMessageId: String?
    /// Drives the lock-overlay shortcut legend popover hosted in the People
    /// correspondent-lock column (moved out of the CORRESPONDENT card).
    @State private var lockRingLegendPresented = false
    @State private var focusedTransitionSourceSnapshot: FocusTransitionSourceSnapshot?
    @State private var liveMetalFocusWarpEffect: LiveMetalFocusWarpEffect?
    @State private var liveMetalFocusWarpSequence = 0
    @State private var pendingLiveFocusReveal: LiveFocusRevealGate?
    @State private var pendingPeopleLiveFocusReveal: PeopleLiveFocusRevealGate?
    @State private var pendingLockedDeletionReturn: PendingLockedDeletionReturn?
    @State private var peopleContextDimRampSequence = 0
    @State private var peopleContextDimRampActive = false
    @State private var liveFocusExitInFlight = false
    @State private var peopleLiveFocusExitInFlight = false
    @State private var focusSourcePreview: FocusSourcePreview?

    /// Tick-able timestamp of the last aperture input; drives the transient
    /// readout's fade-out. Nil = no recent input, readout hidden.
    @State private var apertureReadoutTimer: Date? = nil
    @State private var searchScores: [Float] = []

    @AppStorage("constellationSidebarSide") private var sidebarSideRaw: String = "leading"
    // Persisted but currently has no user-facing toggle — the hide-sidebar
    // affordance (View menu / keyboard shortcut) is a follow-up. Default true
    // keeps the sidebar always visible until the toggle UI lands.
    @AppStorage("constellationSidebarVisible") private var sidebarVisible: Bool = true
    @AppStorage("constellationSidebarTab") private var sidebarTabRaw: String = "search"
    @AppStorage("constellationSidebarWidth") private var sidebarWidth: Double = 380
    @AppStorage("constellationSidebarWidthUserResized") private var sidebarWidthUserResized: Bool = false
    @AppStorage("timelineConversationModeEnabled") private var timelineConversationModeAppStorage: Bool = false

    // Withheld (Junk & Trash) drawer — slides in from the trailing edge opposite
    // the leading Ask/Search sidebar. Visibility persists as a View-menu chrome
    // toggle (peer to the sidebar), so the menu renders Show/Hide dynamically off
    // the same @AppStorage key.
    @State private var withheldModel = WithheldDrawerModel()
    @AppStorage("constellationWithheldVisible") private var withheldVisible = false
    /// User-adjustable Withheld drawer width (drag its inner border), persisted and
    /// clamped to [withheldMinWidth, withheldMaxWidth]. Mirrors the Search/Ask
    /// sidebar's resize behavior.
    @AppStorage("constellationWithheldWidth") private var withheldWidth: Double = 380
    @State private var withheldRestoreDropArmed = false
    @State private var withheldRestoreDropArmID = UUID()
    @State private var withheldRestoreDropTargeted = false
    @State private var customTimeRange: ClosedRange<Date>?

    // Non-observable reference cache for Constellation message snapshots. Mutating
    // the cache should not invalidate the SwiftUI tree; renderPacket changes are
    // the view-facing output of a refresh.
    @State private var snapshotCache = ConstellationSnapshotCache()
    /// Non-observable reuse of the arrival-gated index behind
    /// `currentMessageIndex`; see `GatedMessageIndexMemo`.
    @State private var gatedMessageIndexMemo = GatedMessageIndexMemo()
    /// Non-observable reuse of the hovered correspondent's card; see
    /// `hoveredPersonHubContext`.
    @State private var personHubHoverContextMemo = LastValueMemo<PersonHubHoverContextKey, PersonHubHoverContext>()

    // ConstellationActiveMonitor lives in OhiaScheduler; injected via .environment.
    @Environment(ConstellationActiveMonitor.self) private var activeMonitor: ConstellationActiveMonitor?

    @AppStorage("constellationAperture") private var aperturePref: Double = 1.0
    @AppStorage("constellationShortcutActiveFrame")
    private var shortcutActiveFrameRaw = FrameKey.frontPage.rawValue
    @AppStorage(
        ClusterDetectPayload.meaningTargetClustersDefaultsKey,
        store: OhiaSharedDefaults.store
    )
    private var meaningClusterDisplayCount: Double = Double(ClusterDetectPayload.defaultMeaningTargetClusters)
    /// People-lens Voices toggle: false = strict (only the matched
    /// correspondent's hub renders); true = ego-network (the match plus
    /// every co-recipient on a shared message). Defaults to strict so
    /// "filter to Sam" reads as "show me Sam."
    @AppStorage("constellationPeopleVoicesExpandsToOneHop") private var peopleFocusExpandsToOneHop: Bool = false
    @AppStorage("constellationShowClusterBillboards") private var showClusterBillboardsPref: Bool = false
    @AppStorage(VectorCollectionVisibilityPreferences.Keys.entity) private var showEntitiesPref: Bool = true
    // Vector-collection visibility bridged from Developer Settings.
    // Defaults mirror `LayoutState.swift`'s `VectorFilter.collections`
    // seed (`[.context, .attachment, .entity]`) — context and
    // attachment on, style off (style vectors are training-side
    // artifacts and rarely something a user wants in-scene).
    @AppStorage(VectorCollectionVisibilityPreferences.Keys.context) private var showContextPref: Bool = true
    @AppStorage(VectorCollectionVisibilityPreferences.Keys.attachment) private var showAttachmentPref: Bool = true
    @AppStorage(VectorCollectionVisibilityPreferences.Keys.style) private var showStylePref: Bool = false
    @AppStorage("constellationRenderDebugHUD") private var renderDebugHUDPref: Bool = false
    @AppStorage("constellationLockOverlayDimEnabled") private var lockOverlayDimEnabledPref: Bool = true

    // Mirrored locked-node identity + classification facets, used by the Edit
    // menu (OhiaMenuCommands) to enable / checkmark its locked-node
    // items. Both sides go through @AppStorage on the same key — see
    // `ConstellationDefaultsKey` — so SwiftUI's invalidation graph
    // stays tight and a typo in either site can't silently break
    // menu enablement.
    @AppStorage(ConstellationDefaultsKey.lockedNodeID) private var lockedNodeIDStorage: String = ""
    @AppStorage(ConstellationDefaultsKey.lockedNodeClassificationJSON) private var lockedNodeClassificationStorage: String = ""
    @AppStorage(ConstellationDefaultsKey.lockedNodeCustomCategoryKeysJSON) private var lockedNodeCustomKeysStorage: String = ""

    @Query private var accounts: [Account]
    /// User-pinned correspondent rows. Drives the `.people` frame's
    /// major-correspondent set: pinned addresses always count as major
    /// regardless of recency-weighted volume, so a user-flagged
    /// relationship stays vivid even when the algorithm would otherwise
    /// demote it. SwiftUI `@Query` ensures the set rebuilds the moment a
    /// row is inserted or deleted by the context menu / settings list.
    @Query private var pinnedCorrespondents: [PinnedCorrespondent]
    /// Optimistic mirror of the pinned-email set. `@Query` updates fire
    /// on the next runloop turn after a SwiftData save commits, which
    /// leaves a sub-frame window where the context menu label and the
    /// render request could read the pre-save state. `toggleSenderPinned`
    /// updates this mirror synchronously so the new state is visible in
    /// the same frame; the `.onChange(of:)` modifier reconciles it back
    /// against `@Query` once the persistent rebuild lands (also covers
    /// pin / unpin actions performed from a different window).
    @State private var pinnedEmailsMirror: Set<String> = []
    @State private var sendAgainInFlight = false
    @State private var focusedEmailPrintInFlight = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(IMAPSessionManager.self) private var sessionManager: IMAPSessionManager?
    /// Active system appearance — drives the Meaning-lens cluster ramp
    /// register (whitened in dark mode, deepened in light mode) via
    /// `MeaningClusterLensPalette.resolve(isDarkAppearance:)`.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.readingTextSize) private var readingTextSize

    /// Persisted set of Territory-hidden account UUIDs, mirrored from
    /// ConstellationTopBar's @AppStorage. Comma-separated UUID list. Read
    /// here so the manual-refresh button can scope to the displayed set.
    @AppStorage("constellationTerritoryHidden") private var territoryHiddenRaw: String = ""

    // Updated by the Metal view's continuous hover callback. `hoverNodePoint`
    // is the hovered star's screen position; `hoverPosition` is the popup
    // centre (horizontally aligned with the star, opening below when there
    // is room — see `HoverPopupPlacement`).
    @State private var hoverNodePoint: CGPoint = .zero
    @State private var hoverPosition: CGPoint = CGPoint(x: 200, y: 160)
    @State private var hoveredPersonEmail: String?
    @State private var hoveredMeaningClusterId: Int64?
    /// Measured heights of the rendered `MeaningClusterHoverCard`. The
    /// bordered card body is shorter than the default hover envelope; the
    /// leader terminates on the body's top edge, with the "Meaning" mark
    /// sitting above it.
    @State private var meaningClusterHoverHeight: CGFloat = 0
    @State private var meaningClusterHoverBodyHeight: CGFloat = 0
    @State private var projectedHoverTarget: ProjectedHoverTarget?

    // Live mirror for hover/lock summaries resolved after the active
    // snapshot was built. The unavailable set suppresses a loading shimmer
    // after a per-message summary request has already returned no result.
    @State private var summaryByMessageId: [String: String] = [:]
    /// Canonical manual-classification overrides used immediately while the
    /// snapshot cache catches up with the SwiftData write.
    @State private var classificationByMessageId: [String: MailClassification] = [:]
    /// Custom-key counterpart of `classificationByMessageId` — in-memory
    /// override for the user-defined category keys assigned to a message,
    /// so a fresh tag shows up before the snapshot rebuilds.
    @State private var summaryCustomKeysByMessageId: [String: Set<String>] = [:]
    /// Observable catalog of user-defined categories plus the create /
    /// remove / tag-example mutations. Attached to `modelContext` on
    /// appear; mirrors itself into defaults for the menu-bar Commands.
    @State private var customCategoryStore = CustomCategoryStore()
    /// One-shot informational alert for custom-category lifecycle events
    /// that would otherwise be silent: creation (what tagging is needed
    /// before the category can steer future mail) and a tag that reaches
    /// the example-count threshold without unlocking activation because
    /// every tagged example still shares one correspondent.
    @State private var customCategoryTaggingNotice: CustomCategoryTaggingNotice?
    /// Message identity of the category change currently at the top of the
    /// native Undo stack. Focused Projects checks this before offering its
    /// departure-banner Undo so it can never undo another message's edit.
    @State private var classificationUndoMessageID: UUID?
    @State private var classificationUndoOperationSucceeded: Bool?
    @State private var summaryUnavailableMessageIds: Set<String> = []
    @State private var summaryUnavailableReasonByMessageId: [String: String] = [:]
    @State private var summaryRegenerationTokensByMessageId: [String: UUID] = [:]
    @State private var didFrameInitialConstellationCamera = false
    @State private var didFrameOnboardingCameraToNodes = false
    @State private var onboardingRevealSchedule = OnboardingRevealSchedule()
    @State private var visibleNodeLifecycle = ConstellationVisibleNodeLifecycle()
    @State private var nextVisibilityTransition: ConstellationVisibilityTransition = .continuous
    @State private var lastPlacementSceneRefreshAt: Date = .distantPast
    @State private var lastObservedPlacement: PlacementObservation?
    @State private var hasReportedInitialSceneReady = false
    @State private var hasReportedLensSurfaceSettle = false
    @State private var hasReportedFirstVisibleNodeRendered = false
    @State private var legendPresented = false
    /// Recenter is one-shot — `recenterCamera()` doesn't expose progress we
    /// can mirror in the chrome. The rail disables the button for one second
    /// after a press so the camera move reads as in flight and repeated clicks
    /// cannot stack.
    @State private var recenterCooldownActive = false
    @State private var recenterCooldownSeq = 0

    // Active-frame clusters, refreshed by `refreshClusterLabels`.
    @State private var clusters: [ClusterRecord] = []
    /// Number of semantic clusters eligible to render in the installed
    /// Meaning packet's current Moments/filter scope. Nil until that scope
    /// has been measured from a packet, so persisted all-time clusters never
    /// leak into the HUD while a narrower packet is loading.
    @State private var scopedMeaningClusterAvailableCount: Int?
    @State private var meaningClusterPipelineStatus: MeaningClusterPipelineStatus = .processing
    // Meaning-lens hover metadata cache (TF-IDF evidence terms + Qwen-first
    // semantic titles). Driven by `refreshClusterLabels` whenever the active
    // frame's spatial lens is `.meaning`.
    @State private var meaningLabeler = MeaningClusterLabeler(
        appPrivateRoot: OhiaStorageRoot.requiredAppPrivateRoot()
    )
    @State private var meaningClusterDisplayRefreshTask: Task<Void, Never>?
    @State private var meaningClusterDisplayRefreshInFlight = false
    @State private var meaningClusterPublicationRefreshPending = false
    @State private var lastMeaningClusterStoreSignature: MeaningClusterPublicationIdentity?
    @State private var lastMeaningClusterActiveJobProbe: Bool?
    /// Exact message count behind the engaged cluster-filter chip, keyed by
    /// the filter it was counted for. See `meaningClusterFilteredMessageCount`.
    @State private var meaningClusterScopeMessageCount: MeaningClusterScopeMessageCount?
    @State private var meaningClusterScopeMessageCountTask: Task<Void, Never>?
    /// Every correspondent's filtered message scope for the People scene,
    /// built off the main actor during scene refreshes. See
    /// `currentPeopleScopeMessageIds(involving:)` and
    /// `schedulePeopleCorrespondentScope`.
    @State private var peopleCorrespondentScope: PeopleCorrespondentScopeSnapshot?
    @State private var peopleCorrespondentScopeTask: Task<Void, Never>?
    @State private var peopleCorrespondentScopeBuild: PeopleCorrespondentScopeBuild?
    @State private var correspondentSuggestions: [CorrespondentFilterSuggestion] = []
    /// Cached per-topic message counts surfaced after each Topics-filter row
    /// label. Refreshed by a `.task(id:)` whenever the live filter without
    /// category selection or the underlying snapshot timestamp changes — see
    /// `refreshTopicClassificationCounts` for the compute path.
    @State private var purposeCounts: [MailPurpose: Int] = [:]
    @State private var mailingListCategoryCount = 0
    /// Custom-category counterpart of `topicCategoryCounts`, keyed by
    /// `custom.<slug>`; refreshed by the same compute pass.
    @State private var topicCustomCategoryCounts: [String: Int] = [:]
    /// Cached per-account overall message totals shown after each account's
    /// display name in the Territory chip strip and pulldown. Independent
    /// of every live filter — refreshed only when the snapshot is
    /// repopulated (live ingestion / scene rebuild).
    @State private var accountMessageTotals: [UUID: Int] = [:]
    /// Cached per-preset hypothetical counts surfaced in the Moments
    /// pulldown and trigger pill. Refreshed when the live filter (sans
    /// `timeRange`), the configured `customTimeRange`, or the snapshot
    /// shifts — see `refreshTimeRangeCounts` for the compute path.
    @State private var timeRangeCounts: [TimeRangePreset: Int] = [:]
    /// Cached in-scope counts for the Voices autocomplete and Lists rows;
    /// nil until the first computation lands, so rows never show a
    /// placeholder zero. See `refreshVoicesCounts`.
    @State private var voicesCounts: ConstellationMessageFilter.VoicesCounts?

    // Single MessageGraphEdgeProvider threaded into every refresh call —
    // also used by FrameBurstWorker in OhiaApp.init, but the view has its
    // own instance to avoid a cross-target dep on the scheduler's worker.
    @State private var frameEdgeProvider: MessageGraphEdgeProvider?

    // Timeline lens — the NLE-style temporal workspace mounted in place of
    // the Metal scene when `state.activeFrame.spatialLens == .timeline`.
    // `timelineWorkspace` is lazy-init in `timelineScene()` so the rest of
    // the mode doesn't pay the cost when the user never visits Timeline.
    @State private var timelineWorkspace: TimelineWorkspaceState?
    @State private var timelineData = TimelineDataController()
    @State private var projectsWorkspace: ProjectsWorkspaceState?
    @State private var projectsData = ProjectsDataController()

    // Front Page lens — the newspaper reading workspace mounted in place of
    // the Metal scene when `state.activeFrame.spatialLens == .frontPage`. It is
    // also the default landing lens. `frontPageWorkspace` is eager-init in
    // `selectFrame(.frontPage)` and on initial mount (and lazily in
    // `frontPageScene()` as a fallback) so the rest of the mode never writes
    // `@State` from inside a view builder.
    @State private var frontPageWorkspace: FrontPageWorkspaceState?
    @State private var frontPageData = FrontPageDataController()

    // Focus-bridge callback: called with a Message UUID to exit Constellation and open Focus mode.
    private let onExitToFocus: (UUID) -> Void

    // Called once after the initial render packet has populated the Metal scene.
    private let onInitialSceneReady: () -> Void

    // Called once in onboarding after Metal has drawn a frame containing a visible node.
    private let onFirstVisibleNodeRendered: () -> Void

    // Called the first time the active lens clears its loading/empty surface
    // status — i.e. the lens has actually settled and its real content is on
    // screen. The shell uses this (not the much-earlier `onInitialSceneReady`,
    // which fires on first appear) to retire its night-sky launch backdrop, so
    // the backdrop survives the heavy first paint of the lens and the
    // splash → lens hand-off never flashes flat black.
    private let onLensSurfaceDidSettle: () -> Void

    // Stored so the frame-switch closure can reach
    // `services.vectorFrameLayoutStore` at refresh time (AppServices is
    // `@Observable`, not ObservableObject, so it's carried as a plain property
    // rather than via environment).
    private let services: AppServices
    private let meaningClusterTitleGenerator: any MeaningClusterTitleGenerating

    // True only when mounted from MainShellView during first-ingestion
    // onboarding. Hides HUD chrome (top bar / bottom bar / Q&A panel),
    // live-refreshes on .index events, and gates right-click exit-to-Focus
    // to a no-op. Default false preserves all existing behavior at the
    // post-onboarding mount site.
    private let onboardingMode: Bool

    // Shared CameraController instance passed to both @StateObject and WarpAnimator.
    // Services taken as explicit parameter (AppServices is @Observable, not ObservableObject).
    public init(
        services: AppServices,
        onExitToFocus: @escaping (UUID) -> Void,
        onInitialSceneReady: @escaping () -> Void = {},
        onFirstVisibleNodeRendered: @escaping () -> Void = {},
        onLensSurfaceDidSettle: @escaping () -> Void = {},
        onboardingMode: Bool = false
    ) {
        let restoredViewState = onboardingMode
            ? nil
            : ConstellationViewStatePersistence.restore()

        self.services = services
        self.meaningClusterTitleGenerator = QwenFirstMeaningClusterTitleGenerator(
            qwen: QwenMeaningClusterTitleGenerator(),
            apple: AppleMeaningClusterTitleGenerator.shared,
            activityPublisher: services.modelActivityStatusPublisher,
            displayLanguageGuard: services.displayLanguageGuard
        )
        self.onExitToFocus = onExitToFocus
        self.onInitialSceneReady = onInitialSceneReady
        self.onFirstVisibleNodeRendered = onFirstVisibleNodeRendered
        self.onLensSurfaceDidSettle = onLensSurfaceDidSettle
        self.onboardingMode = onboardingMode

        let cam = CameraController()
        let warp = WarpAnimator(cameraController: cam)
        _cameraController = StateObject(wrappedValue: cam)
        _warpAnimator = State(initialValue: warp)
        _flightInput = StateObject(wrappedValue: FlightInputHandler())
        _state = State(initialValue: restoredViewState?.state ?? (
            onboardingMode
                ? ConstellationState.makeOnboardingState()
                : ConstellationState()
        ))
        _customTimeRange = State(initialValue: restoredViewState?.customTimeRange)
        _framesWithSessionCameraState = State(initialValue: [])
        _didFrameInitialConstellationCamera = State(initialValue: false)
        _lastPersistedCameraSignature = State(initialValue: .unset)
        _renderPlanner = State(initialValue: ConstellationRenderPlanner(
            vectorStore: services.vectorStore,
            neighborsStore: services.vectorNeighborsStore
        ))
        _lexicalController = State(initialValue: LexicalSearchController(
            engine: LexicalSearchEngine(
                ftsIndex: services.messageFTSIndex,
                vectorStore: services.vectorStore,
                registry: services.embedderRegistry
            )
        ))
        _qaVM = State(initialValue: QAViewModel(
            service: ConstellationQAService(
                engine: WorkerGenerationEngine(),
                entityProfileResolver: EntityVectorEvidenceResolver(vectorStore: services.vectorStore),
                modelActivityStatusPublisher: services.modelActivityStatusPublisher
            ),
            hybridRetriever: services.hybridRetriever,
            askMemoryProvider: services.askMemoryProvider,
            displayLanguageGuard: services.displayLanguageGuard,
            prepareGeneration: {
                NotificationCenter.default.post(name: .ohiaEnsureGenerativeWorker, object: nil)
            }
        ))
    }

    public var body: some View {
        // The toolbar owns the full window width; the split view below it
        // gets the remaining space, so Search/Ask cannot squeeze the toolbar
        // on compact laptop displays.
        VStack(spacing: 0) {
            if shouldShowTopBar {
                constellationTopBar
            }

            constellationWindowEdgeLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Esc-as-cancel button installed at the body level so it's
        // active during BOTH regular lock and focused mode. Previously
        // it lived inside `lockedNodeOverlayLayer`, which only renders
        // after the regular-lock entry warp completes — meaning Esc had
        // no window-level handler in focused mode at all.
        .background(lockedNodeEscDismissButton)
        .modifier(CustomCategoryTaggingNoticeModifier(notice: $customCategoryTaggingNotice))
        // When the hovered node changes, request the generated summary
        // after a short dwell. The .task(id:) variant cancels any prior
        // request so a stale result can't land on the wrong popup.
        .task(id: state.hoveredVectorId) {
            guard state.lockedVectorId == nil else { return }
            guard let id = state.hoveredVectorId,
                  let rec = visibleRecordCache[id] ?? citationSourceRecord(vectorId: id) else {
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  state.lockedVectorId == nil,
                  state.hoveredVectorId == id else {
                return
            }
            meaningAutoMarkReadIfNeeded(record: rec, vectorId: id, trigger: .hover)
            await resolveOnDemandSummary(forMessageId: rec.messageId, scope: .hover)
        }
        .task(id: projectsMessageSummaryTaskToken) {
            guard state.activeFrame.spatialLens == .projects else { return }
            guard let workspace = projectsWorkspace,
                  let readout = workspace.messageReadout else { return }
            let messageId = readout.messageID.uuidString
            guard let row = workspace.currentSnapshot?.messageFilterRows[messageId] else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  state.activeFrame.spatialLens == .projects,
                  projectsWorkspace?.messageReadout?.messageID == readout.messageID else {
                return
            }
            await resolveOnDemandSummary(forMessageId: messageId, rowOverride: row, scope: .hover)
        }
        .task(id: lockEntryEnrichmentToken) {
            guard let token = lockEntryEnrichmentToken else { return }
            await resolveLockedSummaryAfterEntry(for: token)
        }
        .task(id: liveInboundPresentationObservationKey) {
            acknowledgeRenderedLiveInboundMessages()
        }
        .onChange(of: focusedArrivalBadgeObservationKey, initial: true) { previous, key in
            for messageID in previous.unvisitedArrivalIDs.subtracting(key.unvisitedArrivalIDs) {
                newStarNavigator.markVisited(messageId: messageID)
            }
            for messageID in key.messageIDsToRetire {
                markNewStarVisited(messageId: messageID)
            }
        }
        .onAppear {
            applySidebarDefaultWidthIfNeeded()
            // Set the activation callback before attaching so a definition
            // job that completes between attach and the next reload can't
            // slip through unannounced. `newlyActivated` never fires on the
            // first load (the previous snapshot is empty), so categories
            // already active at launch stay silent.
            customCategoryStore.onCategoriesActivated = { activated in
                customCategoryTaggingNotice = CustomCategoryTaggingNotice(
                    kind: .activated(displayNames: activated.map(\.displayName))
                )
            }
            customCategoryStore.attach(modelContext)
            // In onboarding, show any vectors already placed during Splash and
            // rely on the `.index` task below to live-refresh as new ones land.
            // A fresh mount-time `.now` cutoff would hide those early placements.
            prepareOnboardingCamera()
            if frameEdgeProvider == nil {
                frameEdgeProvider = MessageGraphEdgeProvider(
                    messageStoreURL: services.messageStoreURL,
                    vectorStore: services.vectorStore
                )
            }
            state.aperture = aperturePref
            state.lockOverlayDimEnabled = lockOverlayDimEnabledPref
            if state.activeFrame.spatialLens == .projects, projectsWorkspace == nil {
                projectsWorkspace = ProjectsWorkspaceState()
            }
            if state.activeFrame.spatialLens == .frontPage, frontPageWorkspace == nil {
                frontPageWorkspace = FrontPageWorkspaceState()
            }
            requestFrontPageRefreshForCurrentStateIfActive()
            VectorCollectionVisibilityPreferences.registerDefaults()
            applyShowEntitiesPreference()
            armColdFirstPaintIfNeeded(frame: state.activeFrame)
            // Guard activeMonitor before calling enter().
            activeMonitor?.enter()
            Task {
                guard Self.usesMetalScene(state.activeFrame) else { return }
                if state.activeFrame.spatialLens == .meaning {
                    await refreshMeaningSceneForEntry(frame: state.activeFrame)
                } else {
                    await refreshSceneData(updateColorLookup: true)
                    // Mode entry frames the current filtered constellation once,
                    // using the actual Metal view size. Time/filter/lens changes
                    // update visibility only; the reset-position control is the
                    // explicit way to return to a layer's default camera.
                    await refreshClusterLabels()
                }
            }
        }
        .modifier(EmailSummaryInvalidationObserver(onInvalidate: handleEmailSummaryInvalidation))
        .modifier(AccountColorInvalidationObserver(onInvalidate: invalidateAccountColors))
        .onAppear(perform: syncPinnedEmailsMirrorFromQuery)
        .onChange(of: pinnedCorrespondentsKey) { _, _ in
            handlePinnedCorrespondentsChange()
        }
        // Re-arm the lens-settled one-shot whenever the shell pushes this
        // (structurally preserved) view back into onboarding — e.g. a dev reset
        // that wipes first-ingestion without tearing the view down. The shell
        // re-arms its own launch backdrop (`launchSkyVisible`) on the same
        // transition; without this reset the one-shot would stay tripped and the
        // backdrop would never retire (its starfield loop ticking on, unseen
        // behind the painted lens) after the next onboarding completes. Kept as a
        // `ViewModifier` (not an inline `.onChange`) so it doesn't add to this
        // already-type-check-heavy body.
        .modifier(OnboardingReentryObserver(onboardingMode: onboardingMode) {
            hasReportedLensSurfaceSettle = false
        })
        .task(id: onboardingMode) {
            await observeJobCompletions()
        }
        .task(id: state.selectedTimeRange) {
            await observePlacementChangesForCurrentTimeRange()
        }
        // Refresh the Topics-pulldown counts whenever the live filter without
        // classification axes or the active lens snapshot marker shifts. Metal
        // lenses use `basePacket.generatedAt`; SwiftUI/Canvas lenses use
        // their workspace snapshot `builtAt` so toolbar counts stay alive
        // outside the Metal scene.
        .task(id: TopicCountsRefreshKey(
            filter: state.filter,
            frame: state.activeFrame,
            snapshotMarker: topBarCountSnapshotMarker
        )) {
            await refreshTopicClassificationCounts()
        }
        // Voices row counts follow every filter except the Voices selection
        // itself, so typing in the field never recomputes them. Scene lenses
        // key on the snapshot cache's content, not the packet stamp, so
        // camera replans and lock transitions do not recount.
        .task(id: VoicesCountsRefreshKey(
            filter: state.filter,
            selectedTimeRange: state.selectedTimeRange,
            frame: state.activeFrame,
            snapshotRevision: snapshotCache.contentRevision,
            workspaceMarker: Self.usesMetalScene(state.activeFrame) ? nil : topBarCountSnapshotMarker,
            gate: NewMailArrivalLedger.shared.visibilityGate(),
            isOnboarding: onboardingMode,
            now: Date.now
        )) {
            await refreshVoicesCounts()
        }
        // Account totals depend only on the snapshot's messageIndex — the
        // live filter is intentionally not consulted so a toggled-off
        // account still surfaces its overall population. Refresh whenever
        // the snapshot rebuilds.
        .task(id: TopBarCountSnapshotRefreshKey(
            frame: state.activeFrame,
            snapshotMarker: topBarCountSnapshotMarker
        )) {
            await refreshAccountMessageTotals()
        }
        // Voices autocomplete is top-bar data, not Metal-scene data. Refresh it
        // from the same full snapshot source used by the count caches so a
        // Timeline-first launch recognizes names before any lens switch.
        .task(id: CorrespondentSuggestionsRefreshKey(
            scopes: state.filter.correspondentScopes,
            accountIds: state.filter.accountIds,
            frame: state.activeFrame,
            snapshotMarker: topBarCountSnapshotMarker
        )) {
            await refreshCorrespondentSuggestions()
        }
        // Moments counts are population counts by time window within the
        // active Destination account scope. Other TopBar filters remain owned
        // by their controls and the lens render pipelines.
        // `now` is intentionally tied to lens snapshots rather than a
        // free-running clock so the task fires when rows are repopulated
        // rather than every wall-clock second.
        .task(id: TimeRangeCountsRefreshKey(
            accountIds: state.filter.accountIds,
            frame: state.activeFrame,
            customRange: customTimeRange,
            snapshotMarker: topBarCountSnapshotMarker
        )) {
            await refreshTimeRangeCounts()
        }
        .task(id: onboardingMode) {
            await runOnboardingRevealRefreshLoop()
        }
        .task {
            await persistCameraAfterIdleMotionLoop()
        }
        .onDisappear {
            persistConstellationViewState()
            if liveFocusExitInFlight
                || peopleLiveFocusExitInFlight
                || pendingLiveFocusReveal != nil
                || pendingPeopleLiveFocusReveal != nil
                || liveLockPersonFocus != nil {
                clearLiveMetalLockForFrameSwitch()
            }
            // Clear stale frame state so re-entering after the user has switched
            // to a different frame elsewhere doesn't flash the previous frame's
            // chips and billboard labels until refreshClusterLabels() runs.
            clusters = []
            scopedMeaningClusterAvailableCount = nil
            meaningClusterScopeMessageCountTask?.cancel()
            meaningClusterScopeMessageCountTask = nil
            meaningClusterScopeMessageCount = nil
            peopleCorrespondentScopeTask?.cancel()
            peopleCorrespondentScopeTask = nil
            peopleCorrespondentScopeBuild = nil
            peopleCorrespondentScope = nil
            onboardingRevealSchedule.reset()
            visibleNodeLifecycle.reset()
            basePacket = .empty
            renderPacket = .empty
            renderPacketFrame = .defaultFrame
            renderPacketFilter = nil
            renderPacketDisplayRequest = nil
            renderPacketGeneration = nil
            renderPacketHydratedGeneration = nil
            renderPacketFilterCameraResetSignature = nil
            coldFirstPaintRequest = nil
            coldFirstPaintAwaitingFirstDraw = nil
            coldFirstPaintPacketGeneratedAts.removeAll()
            coldFirstPaintStartedAt = nil
            dyingSnapshots = []
            dyingPersonSnapshots = []
            birthingSnapshots = []
            setHoveredMeaningCluster(nil)
            hoveredPersonEmail = nil
            animationTickerTask?.cancel()
            animationTickerTask = nil
            sceneRenderProgressRevealTask?.cancel()
            sceneRenderProgressRevealTask = nil
            sceneRenderProgress = nil
            sceneRenderProgressVisible = false
            visibleRecordCache = [:]
            cancelSemanticSearchPreparation()
            pendingFocusClick = nil
            pendingLiveInboundPresentations.removeAll()
            clearPendingAskCitationNavigation()
            pendingCameraRestoreFrame = nil
            pendingFilterCameraReset = nil
            meaningClusterDisplayRefreshTask?.cancel()
            meaningClusterDisplayRefreshTask = nil
            meaningClusterDisplayRefreshInFlight = false
            meaningClusterPublicationRefreshPending = false
            lastMeaningClusterStoreSignature = nil
            relatedSummaryPrewarmTask?.cancel()
            relatedSummaryPrewarmTask = nil
            liveFocusExitInFlight = false
            peopleLiveFocusExitInFlight = false
            focusedTransitionSourceSnapshot = nil
            activeMonitor?.leave()
        }
        .onChange(of: state.activeFrame) { _, frame in
            shortcutActiveFrameRaw = frame.spatialLens.rawValue
            if frame.spatialLens == .meaning {
                meaningClusterPipelineStatus = currentMeaningClusterPipelineStatus()
            }
            if frame.spatialLens == .timeline {
                // Genuine lens entry (not a transient transition re-mount):
                // rebaseline the Timeline ruler to the current Moments scope's
                // data extent on the next refresh, in case mail arrived or was
                // deleted while the lens was inactive.
                timelineData.invalidateMomentsFit()
            }
            if frame.spatialLens != .timeline {
                pendingTimelineNewStar = nil
                pendingTimelineAskCitation = nil
            }
            if frame.spatialLens != .projects {
                pendingProjectsNewStarMessageID = nil
                pendingProjectsAskCitationMessageID = nil
            }
            if frame.spatialLens != .frontPage {
                cancelPendingFrontPageNewStarHydration(clearPendingMessage: true)
                pendingFrontPageAskCitationMessageID = nil
            }
            if pendingMetalNewStar?.frame != frame {
                pendingMetalNewStar = nil
            }
            renderedLiveInboundMessageIDs.removeAll()
            persistConstellationViewState()
        }
        .onChange(of: lensReadinessKey) { _, _ in
            completeActiveFrameProgressIfReady()
            completePendingNotificationFocusNavigation()
        }
        .modifier(MeaningClusterDisplayLimitChangeObserver(
            value: meaningClusterDisplayCount,
            onChange: scheduleMeaningClusterDisplayRefresh
        ))
        .task(id: meaningClusterRecoveryKey) {
            await repairMissingMeaningClustersIfNeeded()
        }
        .task(id: meaningClusterStoreObservationKey) {
            await observeMeaningClusterStoreWhileActive()
        }
        .task(id: peopleLiveFocusReframeKey) {
            await handlePeopleLiveFocusReframeTask()
        }
        // Sync the filter predicate to whatever the TimeRangeMenu just set.
        // Every preset translates to a `message_received_at`
        // range (email date) — including `.now`, whose range is the last
        // five minutes of email arrivals.
        .onChange(of: state.selectedTimeRange) { _, preset in
            handleSelectedTimeRangeChange(preset)
        }
        .onChange(of: customTimeRange) { _, newRange in
            handleCustomTimeRangeChange(newRange)
        }
        .onChange(of: state.searchQuery) { _, query in
            handleSearchQueryChange(query)
        }
        .modifier(NotificationFocusCommandObserver(
            onRequest: beginPendingNotificationFocusNavigation
        ))
        .modifier(ConstellationShortcutCommandObserver(
            onCommand: handleConstellationShortcutCommand
        ))
        .modifier(NewProjectCommandObserver(
            onRequest: beginNewProjectConfiguration
        ))
        .modifier(ProcessPowerStateObserver { isEnabled in
            guard isEnabled != lowPowerModeEnabled else { return }
            lowPowerModeEnabled = isEnabled
            retainedMetalSurfaces.removeAll()
            guard Self.usesMetalScene(state.activeFrame) else { return }
            Task { await refreshSceneData() }
        })
        .onReceive(NotificationCenter.default.publisher(for: .ohiaScopeConstellationToList)) { notification in
            // Subscriptions ledger → "Show in Constellation": scope the
            // scene to one mailing list's messages. Replaces any prior list
            // scope; every other filter dimension is left as the user had
            // it. The standard filter-change pipeline below handles refresh.
            guard let listId = notification.userInfo?["listId"] as? String else { return }
            let accountID = notification.userInfo?["accountID"] as? UUID
            AppCommand.clearPendingConstellationListScope()
            state.filter.listIds = [listId]
            state.filter.accountIds = accountID.map { [$0] }
        }
        .onAppear {
            handleConstellationModeAppear()
        }
        // VectorFilter conforms to Equatable (added in OhiaCore/Models/LayoutState.swift).
        .onChange(of: state.filter) { _, newFilter in
            handleFilterChange(newFilter)
        }
        // When the Q&A citations change, reconcile the marked set to the new
        // list — stale marks would otherwise force-include retired citations
        // (and hold the shader-pulse redraw latch) for the lens's lifetime —
        // then refresh so the packet's citation signal channels re-light.
        .onChange(of: qaVM.citationVectorIds) { previous, ids in
            highlighter.remove(vectorIds: previous)
            highlighter.mark(vectorIds: ids)
            guard Self.usesMetalScene(state.activeFrame) else { return }
            Task { await refreshSceneData() }
        }
        .onChange(of: state.aperture) { _, _ in
            retainedMetalSurfaces.removeAll()
            guard Self.usesMetalScene(state.activeFrame) else { return }
            Task { await refreshSceneData() }
        }
        .onChange(of: state.searchResultIds) { _, _ in
            guard Self.usesMetalScene(state.activeFrame) else { return }
            Task { await refreshSceneData() }
        }
        .onReceive(sidebarTogglePublisher) { _ in
            withAnimation(Self.sidebarSpring) {
                setSidebarVisible(!sidebarVisible)
            }
        }
        .onReceive(withheldTogglePublisher) { _ in
            withAnimation(Self.sidebarSpring) {
                setWithheldVisible(!withheldVisible)
            }
        }
        .modifier(MessageAttentionInvalidationObserver(onInvalidate: invalidateSharedMessageAttentionSurfaces))
        .modifier(ContentRegenerationObserver(
            onRegenerateGeneratedText: regenerateVisibleGeneratedText,
            onRegenerateTranslation: regenerateVisibleTranslation
        ))
        .modifier(LockedNodeMenuObservers(
            onToggleRead: handleLockedNodeToggleReadFromMenu,
            onMarkAsSpam: handleLockedNodeMarkAsSpamFromMenu,
            onDelete: handleLockedNodeDeleteFromMenu,
            onEditClassificationFacet: handleLockedNodeClassificationFacetFromMenu
        ))
        .modifier(SendAgainFocusedValueModifier(target: sendAgainCommandTarget))
        .modifier(FocusedEmailPrintValueModifier(target: focusedEmailPrintCommandTarget))
        .onReceive(deletionEvents.deletions) { deletion in
            let removed = Set(deletion.vectorIDs)
            // The applier supplies message identity because its vectors have
            // already been deleted when this event arrives. Keep the lookup as
            // a compatibility fallback for any vector-only in-process sender.
            let deletedMessageIds = Set(deletion.messageIDs).union(
                ((try? services.vectorStore.messageIds(for: Array(removed))) ?? [:]).values
            )
            invalidateRetainedLensSurfacesForMutation(
                preservingFrontPageProjectDefinitions: false
            )
            snapshotCache.removeMessages(deletedMessageIds)
            onboardingRevealSchedule.remove(vectorIds: deletion.vectorIDs)
            guard Self.usesMetalScene(state.activeFrame) else {
                if state.activeFrame.spatialLens == .projects {
                    projectsData.invalidateAndRefresh()
                } else if state.activeFrame.spatialLens == .frontPage {
                    requestFrontPageRefreshForCurrentStateIfActive()
                } else if state.activeFrame.spatialLens == .timeline {
                    timelineData.invalidateAndRefreshIfBound()
                }
                return
            }
            let removedMessageIds = visibleMessageIds(forVectorIds: removed)
                .union(deletedMessageIds)

            // Capture the about-to-vanish stars + satellites from the live
            // packet so the Event Horizon collapse can keep playing even
            // after the planner refresh drops them. The capture happens
            // before any cache cleanup so we still have a coherent snapshot.
            let dyingPeople = captureDyingSnapshots(messageIds: removedMessageIds)
            let releasedPeopleFocus = releasePeopleFocusIfDyingHubWasLocked(
                dyingPeople,
                deletedMessageIds: removedMessageIds
            )

            let removedLockedVectorId = state.lockedVectorId.flatMap { locked in
                removed.contains(locked) ? locked : nil
            }
            let reanchoredPeopleFocus = !releasedPeopleFocus
                && reanchorSurvivingPeopleFocusIfNeeded(
                    removedVectorIds: removed,
                    deletedMessageIds: removedMessageIds
                )

            snapshotCache.removeMessages(removedMessageIds)
            if let hovered = state.hoveredVectorId, removed.contains(hovered) {
                state.hoveredVectorId = nil
            }
            if let pending = pendingFocusClick, removed.contains(pending.vectorId) {
                pendingFocusClick = nil
            }
            if let locked = removedLockedVectorId,
               !releasedPeopleFocus,
               !reanchoredPeopleFocus {
                scheduleLockedDeletionReturnAfterAnimation(
                    messageIds: removedMessageIds,
                    dyingPeople: dyingPeople,
                    lockedVectorId: locked
                )
            }
            state.searchResultIds.removeAll { removed.contains($0) }
            newStarNavigator.remove(vectorIds: removed, messageIds: removedMessageIds)
            visibleRecordCache = visibleRecordCache.filter { removed.contains($0.key) == false }
            Task { await refreshSceneData(updateColorLookup: true) }
        }
        .onChange(of: aperturePref) { _, newValue in
            // Equality guard — the in-app delta closure already writes
            // state.aperture before it writes aperturePref, so without this
            // we'd double-invalidate SwiftUI every pinch frame. This branch
            // only fires for genuine external writes (e.g. a future Settings
            // slider setting aperturePref directly).
            if state.aperture != newValue { state.aperture = newValue }
        }
        // Single observer over preference changes that feed scene rendering.
        // Keeping these behind one Equatable key avoids blowing SwiftUI's
        // body type-check budget with chained `.onChange` modifiers.
        .onChange(of: scenePreferenceObservationKey) { previous, current in
            handleScenePreferenceChange(previous: previous, current: current)
        }
        .onChange(of: lockOverlayDimEnabledPref) { _, newValue in
            state.lockOverlayDimEnabled = newValue
            guard state.lockedVectorId != nil else { return }
            Task { await refreshSceneData(updateColorLookup: false) }
        }
        // Clear apertureReadoutTimer ~1.3s after the last input so the
        // readout's TimelineView unmounts (the outer `if apertureReadoutTimer
        // != nil` gate then evaluates false). `.task(id:)` restarts cleanly
        // on every fresh stamp, cancelling the previous sleep.
        .task(id: apertureReadoutTimer) {
            await hideApertureReadoutAfterDelay()
        }
    }

    @MainActor
    private func hideApertureReadoutAfterDelay() async {
        guard apertureReadoutTimer != nil else { return }
        do {
            try await Self.sleepForApertureReadoutHideDelay()
            apertureReadoutTimer = nil
        } catch {
            // Task cancelled — a newer stamp started a fresh 1.3s window.
        }
    }

    private func handleConstellationModeAppear() {
        shortcutActiveFrameRaw = state.activeFrame.spatialLens.rawValue
        if state.activeFrame.spatialLens == .meaning {
            meaningClusterPipelineStatus = currentMeaningClusterPipelineStatus()
        }
        // The ledger's scope request is latched: when it fired while a
        // different mode was mounted, the notification reached nobody —
        // pick the pending scope up here instead of dropping it.
        if let pending = AppCommand.pendingConstellationListScope() {
            let accountID = AppCommand.pendingConstellationListScopeAccountID()
            AppCommand.clearPendingConstellationListScope()
            state.filter.listIds = [pending]
            state.filter.accountIds = accountID.map { [$0] }
        }
        // Seed the live-filter mirror so a Composer opened without any
        // subsequent filter change still scopes to the current view.
        AppCommand.publishConstellationFilter(state.filter)
        beginPendingNotificationFocusNavigation()
        if AppCommand.pendingNewProjectConfiguration() {
            beginNewProjectConfiguration()
        }
    }

    @MainActor
    private func beginNewProjectConfiguration() {
        AppCommand.clearPendingNewProjectConfiguration()
        if state.activeFrame.spatialLens != .projects {
            selectFrame(.projects)
        } else if projectsWorkspace == nil {
            projectsWorkspace = ProjectsWorkspaceState()
        }
        guard let workspace = projectsWorkspace else { return }
        workspace.switchLensTab(to: .projects)
        workspace.requestNewProjectConfiguration()
    }

    @MainActor
    private func handleConstellationShortcutCommand(
        _ command: ConstellationShortcutCommand
    ) {
        switch command {
        case .scope(let frame):
            selectFrame(frame)
        case .moment(let preset):
            customTimeRange = nil
            state.selectedTimeRange = preset
        case .action(let action):
            state.filter = ConstellationShortcutFilterMutation.applying(
                action: action,
                to: state.filter,
                activeFrame: state.activeFrame
            )
        case .status(let status):
            state.filter = ConstellationShortcutFilterMutation.applying(
                status: status,
                to: state.filter
            )
        }
    }

    private func handleFilterChange(_ newFilter: VectorFilter) {
        persistConstellationViewState()
        // Mirror the live filter so the Composer's separate window can scope
        // "Search Past Emails" to the user's current view.
        AppCommand.publishConstellationFilter(newFilter)
        nextVisibilityTransition = .filterChange
        clearPendingAskCitationNavigation()
        guard Self.usesMetalScene(state.activeFrame) else {
            if state.activeFrame.spatialLens == .projects {
                projectsData.invalidateAndRefresh()
            } else if state.activeFrame.spatialLens == .frontPage {
                requestFrontPageRefreshForCurrentStateIfActive()
            } else if state.activeFrame.spatialLens == .timeline {
                timelineData.invalidateAndRefreshIfBound()
            }
            return
        }
        armFilterCameraResetIfNeeded(filter: newFilter)
        if sceneRenderProgress?.reason != .timeRange {
            beginSceneRenderProgress(.filter)
        }
        Task {
            await refreshSceneData(updateColorLookup: true)
        }
    }

    @MainActor
    private func handlePeopleLiveFocusReframeTask() async {
        let expectedKey = peopleLiveFocusReframeKey
        await reframeLivePeopleFocusIfNeeded(expectedKey: expectedKey)
    }

    private func handleSelectedTimeRangeChange(_ preset: TimeRangePreset) {
        // Every preset filters on message_received_at — never arrival_time
        // (the layout-placement stamp is a system internal). Newly-arriving
        // messages with a recent received_at materialize automatically via
        // the .index live-refresh path below.
        if Self.usesMetalScene(state.activeFrame) {
            beginSceneRenderProgress(.timeRange)
        }
        nextVisibilityTransition = .filterChange
        state.filter.timeRange = preset.range()
        requestTimelineRefreshForCurrentStateIfActive()
        requestFrontPageRefreshForCurrentStateIfActive()
        persistConstellationViewState()
    }

    private func handleCustomTimeRangeChange(_ newRange: ClosedRange<Date>?) {
        // Only meaningful when the user is in the .custom preset; for any
        // other preset the range is derived from preset.range(), and we
        // proactively cleared customTimeRange in onSelectTimePreset.
        guard state.selectedTimeRange == .custom else { return }
        if Self.usesMetalScene(state.activeFrame) {
            beginSceneRenderProgress(.timeRange)
        }
        nextVisibilityTransition = .filterChange
        state.filter.timeRange = newRange
        requestTimelineRefreshForCurrentStateIfActive()
        requestFrontPageRefreshForCurrentStateIfActive()
        persistConstellationViewState()
    }

    private func handleSearchQueryChange(_ query: String) {
        // Clearing the search field returns the constellation to its
        // pre-search state — drops the pinned `searchResultIds`, the
        // surfaced scores, and any lingering hover-pair highlights.
        // Without this, deleting query chars leaves stale highlights
        // pinned outside aperture culling and stale stats in the
        // sidebar.
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let hadResultIds = !state.searchResultIds.isEmpty
        let hadSearchState = hadResultIds || !searchScores.isEmpty
        if hadSearchState {
            beginSceneRenderProgress(.clearSearch)
        }
        state.searchResultIds = []
        searchScores = []
        lexicalResult = nil
        selectedSearchLane = nil
        searchMatchIndex = 0
        cancelSemanticSearchPreparation()
        clearSearchWarpNavigation()
        if hadSearchState {
            refreshSceneAfterClearingSearchIfNeeded(hadResultIds: hadResultIds)
        }
    }

    @MainActor
    private func observeJobCompletions() async {
        resetCompletionRefreshCoordinator()
        defer { cancelCompletionRefreshCoordinator() }

        for await event in services.jobCompletionBroadcaster.events() {
            guard !Task.isCancelled else { return }
            let finalizedMailboxMessageIDs = CompletionMailboxVisibilityRefresh.messageIDs(
                in: event
            )
            var mailboxDepartureHold = 0.0
            if finalizedMailboxMessageIDs.isEmpty == false {
                mailboxDepartureHold = applyCompletedMailboxVisibilityMutation(
                    messageIDs: finalizedMailboxMessageIDs,
                    departure: CompletedMailboxVisibilityDeparture.resolve(
                        event: event,
                        context: modelContext
                    )
                )
            }
            let summaryMessageIDs = CompletionMessageSummaryRefresh.messageIDs(
                in: event
            )
            if summaryMessageIDs.isEmpty == false {
                await refreshCompletedMessageSummaries(
                    messageIDs: summaryMessageIDs
                )
            }

            switch CompletionRefreshDisposition.classify(event) {
            case .immediateExact:
                switch event.type {
                case .frameBurst:
                    guard Self.usesMetalScene(state.activeFrame) else {
                        continue
                    }
                    guard let data = event.payload?.data(using: .utf8),
                          let payload = try? JSONDecoder().decode(
                            FrameBurstPayload.self,
                            from: data
                          ),
                          payload.frame == state.activeFrame else {
                        continue
                    }
                    await refreshSceneData(frame: payload.frame)
                case .clusterDetect:
                    guard Self.usesMetalScene(state.activeFrame) else {
                        continue
                    }
                    // Only Meaning has a cluster runner.
                    guard let data = event.payload?.data(using: .utf8),
                          let payload = try? JSONDecoder().decode(
                            ClusterDetectPayload.self,
                            from: data
                          ),
                          payload.frame == state.activeFrame,
                          payload.frame.spatialLens == .meaning else {
                        continue
                    }
                    await refreshMeaningClustersIfStoreChanged()
                default:
                    continue
                }
            case .accumulate(let flushDelay):
                var intent = CompletionRefreshIntent()
                intent.merge(event)
                completionRefresh.enqueue(
                    intent,
                    flushDelay: mailboxDepartureHold > 0
                        && state.activeFrame.spatialLens == .timeline
                        ? .seconds(mailboxDepartureHold)
                        : flushDelay,
                    flush: { intent in
                        await flushCompletionRefresh(intent)
                    }
                )
            case .ignore:
                continue
            }
        }
    }

    @MainActor
    @discardableResult
    private func applyCompletedMailboxVisibilityMutation(
        messageIDs: Set<UUID>,
        departure: CompletedMailboxVisibilityDeparture?
    ) -> Double {
        let departureHold: Double
        if let departure,
           let coordinator = activeDepartingGestureCoordinator {
            let startedAt = Date()
            departureHold = departure.begin(on: coordinator, now: startedAt)
            scheduleActiveLensDepartingSettle(
                Array(departure.messageIDs),
                startedAt: startedAt
            )
            switch state.activeFrame.spatialLens {
            case .frontPage:
                frontPageData.invalidateAndRefresh(
                    holdingFor: departureHold
                )
            case .projects:
                projectsData.invalidateAndRefresh(
                    holdingFor: departureHold
                )
            default:
                break
            }
        } else {
            departureHold = 0
        }
        frontPageWorkspace?.removeDeletedArticles(messageIDs)
        if let lockedNodeMessageID, messageIDs.contains(lockedNodeMessageID) {
            releaseLockStateForRemovedNode()
            return departureHold
        }
        if let selected = lockedRingSelectionMessageId,
           messageIDs.contains(where: { $0.uuidString == selected }) {
            lockedRingSelectionMessageId = nil
        }
        return departureHold
    }

    /// Pulls only the summaries named by a successful Qwen completion. Cards,
    /// Projects readouts, and focused readers all observe this override map, so
    /// summary text updates without invalidating any lens snapshot.
    @MainActor
    private func refreshCompletedMessageSummaries(
        messageIDs: Set<UUID>
    ) async {
        guard messageIDs.isEmpty == false else { return }
        let container = modelContext.container
        let rows = await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let ids = messageIDs
            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    ids.contains(message.id)
                }
            )
            return ((try? context.fetch(descriptor)) ?? []).map { message in
                CompletedMessageSummary(
                    messageID: message.id.uuidString,
                    rawSummary: message.analysis?.bodySummary
                )
            }
        }.value
        guard Task.isCancelled == false else { return }
        for row in rows {
            if let summary = row.summary {
                summaryByMessageId[row.messageID] = summary
            } else {
                summaryByMessageId.removeValue(forKey: row.messageID)
            }
        }
    }

    @MainActor
    private func resetCompletionRefreshCoordinator() {
        completionRefresh.reset()
    }

    @MainActor
    private func cancelCompletionRefreshCoordinator() {
        completionRefresh.cancel()
    }

    @MainActor
    private func flushCompletionRefresh(
        _ intent: CompletionRefreshIntent
    ) async {
        let resolved = intent.resolve(
            refreshesOnNewPlacements:
                state.selectedTimeRange.refreshesOnNewPlacements,
            onboarding: onboardingMode
        )
        guard resolved.hasWork else { return }
        let frontPageRefreshPolicy = resolved.frontPageRefreshPolicy

        if resolved.invalidateInactiveLenses {
            markInactiveLensDataChanged(
                preservingFrontPageProjectDefinitions:
                    frontPageRefreshPolicy.preservingProjectDefinitions
            )
        }
        guard let dataMutation = resolved.dataMutation else {
            if resolved.summary {
                refreshNonMetalLensAfterIndexedMail(
                    resolveTimelineRollingWindow: false,
                    frontPageRefreshPolicy: frontPageRefreshPolicy
                )
            }
            return
        }

        if onboardingMode {
            await refreshSceneAfterVectorPlacement()
            return
        }

        guard Self.usesMetalScene(state.activeFrame) else {
            if dataMutation.refreshesNonMetalLenses {
                refreshNonMetalLensAfterIndexedMail(
                    resolveTimelineRollingWindow:
                        dataMutation.resolveTimelineRollingWindow,
                    frontPageRefreshPolicy: frontPageRefreshPolicy
                )
            }
            return
        }

        let isIndexOnly = dataMutation.hasIndex
            && !dataMutation.requiresImmediateMetalRefresh
        if isIndexOnly && shouldDeferPlacementSceneRefresh() {
            return
        }
        await refreshSceneData(
            updateColorLookup: dataMutation.updateColorLookup
        )
    }

    private func refreshNonMetalLensAfterIndexedMail(
        resolveTimelineRollingWindow: Bool,
        frontPageRefreshPolicy: CompletionFrontPageRefreshPolicy
    ) {
        if state.activeFrame.spatialLens == .projects {
            projectsData.invalidateAndRefresh()
            syncNewStarNavigatorWithCurrentMessageIndex()
        } else if state.activeFrame.spatialLens == .frontPage {
            frontPageData.invalidateAndRefresh(
                preservingProjectDefinitions:
                    frontPageRefreshPolicy.preservingProjectDefinitions,
                deferringIfRefreshInFlight:
                    frontPageRefreshPolicy.deferringIfRefreshInFlight
            )
            syncNewStarNavigatorWithCurrentMessageIndex()
        } else if state.activeFrame.spatialLens == .timeline {
            timelineData.invalidateAndRefreshIfBound(resolveRollingWindow: resolveTimelineRollingWindow)
            syncNewStarNavigatorWithCurrentMessageIndex()
        }
    }

    @MainActor
    private func observePlacementChangesForCurrentTimeRange() async {
        guard state.selectedTimeRange.refreshesOnNewPlacements || onboardingMode else { return }
        guard Self.usesMetalScene(state.activeFrame) || onboardingMode else { return }
        while !Task.isCancelled {
            await refreshIfPlacementObservationChanged()
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                break
            }
        }
    }

    @MainActor
    private func runOnboardingRevealRefreshLoop() async {
        guard onboardingMode else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                break
            }
            guard onboardingRevealSchedule.hasFutureReveals(now: Date.now) else {
                continue
            }
            await refreshSceneData()
        }
    }

    @MainActor
    private func persistCameraAfterIdleMotionLoop() async {
        var lastObservedCameraSignature = CameraPlanningSignature(cameraController.state)
        var lastCameraMotionAt = Date.distantPast
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
            guard shouldRefreshSceneForCameraMotion() else { continue }
            let now = Date.now
            let currentSignature = CameraPlanningSignature(cameraController.state)
            if currentSignature.isMeaningfullyDifferent(from: lastObservedCameraSignature) {
                lastObservedCameraSignature = currentSignature
                lastCameraMotionAt = now
                continue
            }
            guard now.timeIntervalSince(lastCameraMotionAt) >= Self.cameraReplanIdleDelay else { continue }
            persistCurrentCameraForActiveLensIfChanged(signature: currentSignature)
            guard currentSignature.needsReplan(comparedTo: lastPlannedCameraSignature) else { continue }
            lastPlannedCameraSignature = currentSignature
            await refreshSceneData()
        }
    }

    private var shouldShowTopBar: Bool {
        !onboardingMode
    }

    @ViewBuilder
    private var constellationTopBar: some View {
        ConstellationTopBar(
            activeFrame: $state.activeFrame,
            selectedTimeRange: $state.selectedTimeRange,
            customTimeRange: $customTimeRange,
            filter: $state.filter,
            accounts: accounts,
            correspondentSuggestions: correspondentSuggestions,
            purposeCounts: purposeCounts,
            mailingListCount: mailingListCategoryCount,
            customCategoryCounts: topicCustomCategoryCounts,
            customCategoryCatalog: customCategoryStore.descriptors,
            accountMessageTotals: accountMessageTotals,
            timeRangeCounts: timeRangeCounts,
            voicesAddressCounts: voicesCounts?.byAddress,
            voicesListCounts: voicesCounts?.byAccountList,
            leadingInset: 84,
            onSelectFrame: { frame in
                selectFrame(frame)
            },
            onSelectTimePreset: { preset in
                // Custom-range commits update state.filter.timeRange via
                // the customTimeRange binding; non-custom presets fall
                // through to the .onChange(of: state.selectedTimeRange)
                // observer which writes preset.range() into the filter.
                if preset != .custom {
                    customTimeRange = nil
                }
            },
            onCreateCustomCategory: { name in
                if let created = customCategoryStore.createCategory(named: name) {
                    customCategoryTaggingNotice = CustomCategoryTaggingNotice(
                        kind: .created(displayName: created.displayName)
                    )
                }
            },
            onRemoveCustomCategory: { key in
                removeCustomCategory(key: key)
            }
        )
        .zIndex(1_000)
    }

    @ViewBuilder
    private var constellationDetailContent: some View {
        lensSceneWithSurfaceStatus
    }

    @ViewBuilder
    private var lensSceneWithSurfaceStatus: some View {
        let status = activeLensSurfaceStatus
        let blocksScene = Self.lensSurfaceStatusBlocksInteraction(status)
        ZStack {
            activeLensScene
                .opacity(blocksScene ? 0 : 1)
                .allowsHitTesting(!blocksScene)
                .accessibilityHidden(blocksScene)

            // Mounted unconditionally (not inside `explorerScene`'s Metal-only
            // branch) so Front Page / Timeline / Projects — the non-Metal
            // lenses users actually live in — still receive the unified
            // arrival announcement. Previously this only existed inside the
            // Metal explorer scene, so a live arrival while on any other lens
            // rendered the node (embargo lifts unconditionally in the ledger)
            // but never reached `announce()`: no sound, no badge, no
            // notification, no new-arrival shimmer.
            liveInboundNotificationBridge

            if let status, blocksScene {
                // Terminal empty states replace the scene. Loading stays with
                // each mounted lens's existing progress renderer, avoiding a
                // second spinner and keeping this wrapper out of the redraw
                // path. Metal lenses carry the `NightSkyView` backdrop through
                // their transparent view, so preserve the same band-less sky.
                if activeLensUsesNightSky {
                    NightSkyView(
                        showsMilkyWay: false,
                        twinkles: false
                    )
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
                ConstellationLensSurfaceStatusView(
                    status: status,
                    paintsBackground: !activeLensUsesNightSky
                )
                .transition(.opacity)
            }
        }
        .background(lensSurfaceBackdrop)
        .overlay {
            if shouldShowWithheldRestoreDropReceiver {
                WithheldDropReceiverView(
                    isTargeted: $withheldRestoreDropTargeted,
                    onDrop: { payloads in
                        restoreWithheldRows(payloads: payloads)
                    },
                    onEnded: {
                        disarmWithheldRestoreDrop()
                    }
                )
                .transition(.opacity)
            }
        }
        .overlay {
            if withheldRestoreDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 2)
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: status)
        .animation(.easeInOut(duration: 0.12), value: withheldRestoreDropTargeted)
        // The first time the lens clears its surface status, tell the shell the
        // lens has settled so it can retire its night-sky launch backdrop. The
        // method is one-shot and self-guards on `status == nil`; `initial: true`
        // covers a warm-cache mount that is ready on first appearance.
        .onChange(of: status, initial: true) { _, _ in
            reportLensSurfaceSettledIfNeeded()
        }
    }

    private var shouldShowWithheldRestoreDropReceiver: Bool {
        withheldRestoreDropArmed
    }

    private var frontPageFocusedDetailIsActive: Bool {
        state.activeFrame.spatialLens == .frontPage
            && frontPageWorkspace?.focusedArticleID != nil
    }

    @ViewBuilder
    private var activeLensScene: some View {
        if state.activeFrame.spatialLens == .frontPage {
            // Non-Metal lenses never run `refreshSceneData`, so they must
            // report initial readiness themselves — otherwise the shell's
            // `BlankModeSurface` veil never lifts when the mode is entered
            // (or restored) on a non-Metal lens. `reportInitialSceneReady`
            // is idempotent, so a later Metal mount is unaffected.
            frontPageScene()
                .onAppear { reportInitialSceneReady() }
        } else if state.activeFrame.spatialLens == .timeline {
            timelineScene()
                .onAppear { reportInitialSceneReady() }
        } else if state.activeFrame.spatialLens == .projects {
            projectsScene()
                .onAppear { reportInitialSceneReady() }
        } else {
            liveMetalLensScene
        }
    }

    /// The live Metal lens scene must keep ONE structural identity whether
    /// or not a source-warp effect is running — an `if let effect` branch
    /// would give SwiftUI two subtree identities, so every effect set/clear
    /// dismantled and remounted the entire `explorerScene` including the
    /// MTKView (blank until its first draw: the constellation blinked out
    /// at each lock boundary). The scene is therefore mounted
    /// unconditionally, and the warp reaches the Metal host as a
    /// `ConstellationSourceWarpDrive` descriptor that changes only when a
    /// transition arms or clears: the draw loop derives the per-frame phase
    /// itself, so no SwiftUI re-evaluation runs per tick during a
    /// transition (the `TimelineView` that used to re-render this whole
    /// subtree at 60Hz for every lock entry/exit is deliberately gone).
    private var liveMetalLensScene: some View {
        let effect = activeLiveMetalFocusWarpEffect
        let lens = state.activeFrame.spatialLens
        return ZStack {
            explorerScene(sourceWarpDrive: effect?.sourceWarpDrive)
            // Sibling of the explorer scene so the comet re-renders the
            // instant a dispatch begins and drives its own clock.
            ComposerDispatchOverlay(
                coordinator: composerDispatch,
                renderPacket: renderPacket,
                cameraController: cameraController,
                enabled: lens == .meaning || lens == .people,
                displacedWorld: lens == .people
                    ? { [metalRenderer] messageId, base in
                        // People satellites orbit every frame — launch the comet
                        // from where the node is actually drawn right now.
                        metalRenderer.peopleLiveWorldPosition(messageId: messageId, basePosition: base)
                      }
                    : { _, base in base }
            )
            .allowsHitTesting(false)
        }
    }

    private var activeLiveMetalFocusWarpEffect: LiveMetalFocusWarpEffect? {
        guard let effect = liveMetalFocusWarpEffect,
              LiveMetalFocusTransitionPolicy.usesSourceWarp(
                activeFrame: state.activeFrame,
                effectFrame: effect.frame
              ) else {
            return nil
        }
        return effect
    }

    @MainActor
    private var lensReadinessKey: LensReadinessKey {
        LensReadinessKey(
            onboardingMode: onboardingMode,
            activeFrame: state.activeFrame.spatialLens,
            renderPacketFrame: renderPacketFrame.spatialLens,
            renderPacketFilter: renderPacketFilter,
            renderPacketGeneratedAt: renderPacket.generatedAt,
            timelineSignature: timelineWorkspace?.currentSnapshot?.signature,
            timelineExpectedSignature: timelineData.latestSignature,
            projectsSignature: projectsWorkspace?.currentSnapshot?.signature,
            frontPageSignature: frontPageWorkspace?.currentSnapshot?.signature
        )
    }

    /// Lenses whose settled scene sits on the `NightSkyView` starfield, so the
    /// loading / empty status must keep that starfield behind it rather than
    /// drop to flat black. This is every Metal-scene lens (People / Meanings —
    /// everything routed through `explorerScene`, whose transparent Metal view
    /// lets the starfield show through) plus the Front Page workspace, which
    /// paints its own `NightSkyView(showsMilkyWay: false)` backdrop
    /// (`FrontPageWorkspaceView`). Without Front Page here, entering it (from
    /// the splash hand-off or a lens switch) flashes the spinner over flat
    /// `spaceBackground` before the starfield-backed page fades in. Projects
    /// paints the same band-less starfield at its workspace root, so it joins
    /// the set; Timeline settles on `spaceBackground` and stays excluded.
    @MainActor
    private var activeLensUsesNightSky: Bool {
        Self.usesMetalScene(state.activeFrame)
            || state.activeFrame.spatialLens == .frontPage
            || state.activeFrame.spatialLens == .projects
    }

    /// A persistent backdrop that sits behind BOTH the loading status overlay
    /// and the settled lens scene. For Front Page it is the deterministic
    /// band-less starfield: when the snapshot lands, the loading overlay is
    /// removed *and* `FrontPageWorkspaceView` re-renders its whole card deck in
    /// one pass, so its first paint lags a frame or two. Without a static sky
    /// underneath, that lag exposed the flat `spaceBackground` fill — a brief
    /// black flash between the loading sky and the settled page. This sky never
    /// re-renders on the status/snapshot change (it is outside the `if let
    /// status` block and identity-stable), so it stays painted through the card
    /// re-render and the hand-off is seamless. The band-less loading overlay
    /// still draws on top during the gap and fades out as the cards settle in.
    /// Other lenses keep the flat fill they settle on
    /// (Metal lenses carry their own starfield; Timeline settles on
    /// `spaceBackground`). Projects paints the same starfield as Front Page,
    /// so it shares the seamless-sky hand-off.
    @ViewBuilder
    private var lensSurfaceBackdrop: some View {
        if state.activeFrame.spatialLens == .frontPage || state.activeFrame.spatialLens == .projects {
            NightSkyView(showsMilkyWay: false, twinkles: false)
                .ignoresSafeArea()
        } else {
            OhiaColors.spaceBackground
        }
    }

    @MainActor
    private var activeLensSurfaceStatus: ConstellationLensSurfaceStatus? {
        if isActiveFrameSwitchProgress {
            return .loading(accessibilityLabel: Self.sceneRenderProgressAccessibilityLabel(.frame(state.activeFrame.spatialLens)))
        }
        guard activeLensIsReady else {
            return .loading(accessibilityLabel: "Loading \(Self.frameTitle(state.activeFrame))")
        }
        if state.filter.accountIds?.isEmpty == true {
            return .noAccountsSelected
        }
        if Self.shouldPresentNoMessagesMeetFilterStatus(
            activeFrame: state.activeFrame,
            hasMessages: activeLensHasMessages
        ),
           !frontPageFocusedDetailIsActive,
           !suppressesNoMessagesMeetFilterStatusForPendingDeletionReturn,
           !(onboardingMode && state.activeFrame.spatialLens == .meaning) {
            return .noMessagesMeetFilter
        }
        return nil
    }

    nonisolated static func shouldPresentNoMessagesMeetFilterStatus(
        activeFrame: FrameKey,
        hasMessages: Bool
    ) -> Bool {
        !hasMessages && activeFrame.spatialLens != .projects
    }

    /// Loading represents an in-flight refresh over a structurally mounted
    /// lens. Only terminal empty states replace that lens and own its input.
    nonisolated static func lensSurfaceStatusBlocksInteraction(
        _ status: ConstellationLensSurfaceStatus?
    ) -> Bool {
        switch status {
        case .some(.noAccountsSelected), .some(.noMessagesMeetFilter):
            return true
        case .some(.loading), .none:
            return false
        }
    }

    @MainActor
    private var suppressesNoMessagesMeetFilterStatusForPendingDeletionReturn: Bool {
        Self.suppressesNoMessagesMeetFilterStatus(
            pendingDeletionReturn: pendingLockedDeletionReturn,
            activeFrame: state.activeFrame,
            lockRevealSequence: lockRevealSequence,
            lockedVectorId: state.lockedVectorId,
            livePersonEmail: liveLockPersonFocus?.email
        )
    }

    @MainActor
    private var isActiveFrameSwitchProgress: Bool {
        guard case .frame(let frame)? = sceneRenderProgress?.reason else { return false }
        return frame.spatialLens == state.activeFrame.spatialLens
    }

    @MainActor
    private var activeLensIsReady: Bool {
        switch state.activeFrame.spatialLens {
        case .frontPage:
            guard let snapshot = frontPageWorkspace?.currentSnapshot else { return false }
            return FrontPageDataController.signatureMatchesCurrentFilter(
                snapshot: snapshot,
                filter: state.filter,
                selectedTimeRange: state.selectedTimeRange,
                unreadOnly: frontPageWorkspace?.unreadOnly ?? false
            )
        case .timeline:
            guard let workspace = timelineWorkspace,
                  let snapshot = workspace.currentSnapshot else { return false }
            return Self.timelineSnapshotMatchesCurrentRequest(
                snapshot: snapshot,
                expectedSignature: timelineData.latestSignature,
                viewportRange: workspace.viewportRange
            )
        case .projects:
            guard let snapshot = projectsWorkspace?.currentSnapshot else { return false }
            return ProjectsDataController.signatureMatchesCurrentFilter(
                snapshot: snapshot,
                filter: state.filter
            )
        default:
            return Self.metalScenePacketMatchesActiveFilter(
                renderedFrame: renderPacketFrame,
                renderedFilter: renderPacketFilter,
                activeFrame: state.activeFrame,
                activeFilter: state.filter
            )
        }
    }

    @MainActor
    private var activeLensHasMessages: Bool {
        switch state.activeFrame.spatialLens {
        case .frontPage:
            return frontPageWorkspace?.currentSnapshot?.isEmpty == false
        case .timeline:
            return timelineWorkspace?.currentSnapshot?.sortedEligibleEntries.isEmpty == false
        case .projects:
            guard let workspace = projectsWorkspace,
                  let snapshot = workspace.currentSnapshot else { return false }
            return snapshot.displayedRows().isEmpty == false
        default:
            return renderPacket.totalMessageCount > 0
        }
    }

    @MainActor
    private func shouldDeferPlacementSceneRefresh(now: Date = Date.now) -> Bool {
        guard !onboardingMode else { return false }
        let minimumInterval: TimeInterval = 2
        guard now.timeIntervalSince(lastPlacementSceneRefreshAt) >= minimumInterval else {
            return true
        }
        lastPlacementSceneRefreshAt = now
        return false
    }

    @MainActor
    private func shouldRefreshSceneForCameraMotion() -> Bool {
        guard Self.usesMetalScene(state.activeFrame) else { return false }
        guard renderPacketFrame.spatialLens == state.activeFrame.spatialLens else { return false }
        guard pendingCameraRestoreFrame == nil else { return false }
        guard state.lockedVectorId == nil else { return false }
        guard didFrameInitialConstellationCamera else { return false }
        guard !warpAnimator.isWarping else { return false }
        return true
    }

    nonisolated static func usesMetalScene(_ frame: FrameKey) -> Bool {
        switch frame.spatialLens {
        case .timeline, .projects, .frontPage:
            return false
        default:
            return true
        }
    }

    nonisolated static func metalScenePacketMatchesActiveFilter(
        renderedFrame: FrameKey,
        renderedFilter: VectorFilter?,
        activeFrame: FrameKey,
        activeFilter: VectorFilter
    ) -> Bool {
        guard renderedFrame.spatialLens == activeFrame.spatialLens else { return false }
        return renderedFilter == activeFilter
    }

    nonisolated static func shouldArmFilterCameraReset(
        frame: FrameKey,
        lockedVectorId: Int64?,
        isOnboarding: Bool
    ) -> Bool {
        guard !isOnboarding else {
            return false
        }

        switch frame.spatialLens {
        case .people, .meaning:
            return true
        default:
            return false
        }
    }

    nonisolated static func shouldAutoMarkMeaningMessageRead(
        activeFrame: FrameKey,
        trigger: MeaningAutoReadTrigger,
        targetVectorId: Int64,
        hoveredVectorId: Int64?,
        lockedVectorId: Int64?,
        hasProjectedHoverTarget: Bool,
        isRead: Bool
    ) -> Bool {
        guard activeFrame.spatialLens == .meaning,
              !isRead else {
            return false
        }

        switch trigger {
        case .hover:
            return !hasProjectedHoverTarget
                && lockedVectorId == nil
                && hoveredVectorId == targetVectorId
        case .focusedMode:
            return lockedVectorId == nil || lockedVectorId == targetVectorId
        }
    }

    nonisolated static func shouldApplyPendingFilterCameraReset(
        activeFrame: FrameKey,
        renderPacketFrame: FrameKey,
        renderPacketFilter: VectorFilter?,
        currentFilter: VectorFilter,
        renderPacketSignature: ConstellationFilterCameraResetRequest?,
        currentSignature: ConstellationFilterCameraResetRequest,
        lockedVectorId: Int64?,
        isOnboarding: Bool,
        pending: ConstellationFilterCameraResetRequest?
    ) -> Bool {
        guard let pending,
              shouldArmFilterCameraReset(
                frame: activeFrame,
                lockedVectorId: lockedVectorId,
                isOnboarding: isOnboarding
              ),
              lockedVectorId == nil else {
            return false
        }
        let pendingFrame = pending.frame.spatialLens
        guard activeFrame.spatialLens == pendingFrame,
              renderPacketFrame.spatialLens == pendingFrame,
              renderPacketFilter == pending.filter,
              currentFilter == pending.filter,
              filterCameraResetSignature(renderPacketSignature, matches: pending),
              filterCameraResetSignature(currentSignature, matches: pending) else {
            return false
        }
        return true
    }

    nonisolated static func shouldDiscardPendingFilterCameraReset(
        activeFrame: FrameKey,
        isOnboarding: Bool,
        pending: ConstellationFilterCameraResetRequest?
    ) -> Bool {
        guard let pending else { return false }
        return pending.frame.spatialLens != activeFrame.spatialLens
            || isOnboarding
    }

    nonisolated private static func filterCameraResetSignature(
        _ signature: ConstellationFilterCameraResetRequest?,
        matches expected: ConstellationFilterCameraResetRequest
    ) -> Bool {
        guard let signature else { return false }
        return filterCameraResetSignature(signature, matches: expected)
    }

    nonisolated private static func filterCameraResetSignature(
        _ signature: ConstellationFilterCameraResetRequest,
        matches expected: ConstellationFilterCameraResetRequest
    ) -> Bool {
        signature.frame.spatialLens == expected.frame.spatialLens
            && signature.filter == expected.filter
            && signature.meaningClusterDisplayLimit == expected.meaningClusterDisplayLimit
            && signature.peopleFocusExpandsToOneHop == expected.peopleFocusExpandsToOneHop
    }

    nonisolated static func shouldApplyPendingCameraRestore(
        activeFrame: FrameKey,
        renderPacketFrame: FrameKey,
        pendingFrame: FrameKey?,
        hasStoredCamera: Bool,
        isOnboarding: Bool
    ) -> Bool {
        guard !isOnboarding,
              hasStoredCamera,
              let pendingFrame else {
            return false
        }
        let resolvedFrame = pendingFrame.spatialLens
        return activeFrame.spatialLens == resolvedFrame
            && renderPacketFrame.spatialLens == resolvedFrame
    }

    nonisolated static func shouldCompleteSceneRenderProgress(
        progressFrame: FrameKey,
        renderedFrame: FrameKey
    ) -> Bool {
        progressFrame.spatialLens == renderedFrame.spatialLens
    }

    nonisolated static func timelineSnapshotMatchesCurrentRequest(
        snapshot: TimelineLayoutSnapshot,
        expectedSignature: TimelineLayoutSignature?,
        viewportRange: ClosedRange<Date>
    ) -> Bool {
        guard snapshot.viewportRange == viewportRange else { return false }
        guard let expectedSignature else { return true }
        return snapshot.signature == expectedSignature
    }

    private nonisolated static func sleepForApertureReadoutHideDelay() async throws {
        try await Task.sleep(for: .milliseconds(1300))
    }

    @MainActor
    private func selectFrame(_ frame: FrameKey) {
        let resolvedFrame = frame.spatialLens
        let previousFrame = state.activeFrame
        let activeProgressFrame: FrameKey?
        if case .frame(let progressFrame)? = sceneRenderProgress?.reason {
            activeProgressFrame = progressFrame
        } else {
            activeProgressFrame = nil
        }
        guard state.activeFrame.spatialLens != resolvedFrame
                || activeProgressFrame?.spatialLens != resolvedFrame else {
            return
        }

        captureCurrentMetalSurfaceIfStable()

        let shouldClearLiveMetalLock = ConstellationFrameSwitchPolicy.shouldClearLiveMetalLock(
            from: state.activeFrame,
            to: resolvedFrame,
            lockedVectorId: state.lockedVectorId,
            hasLivePersonFocus: liveLockPersonFocus != nil
        )

        if shouldClearLiveMetalLock {
            clearLiveMetalLockForFrameSwitch()
        } else {
            recordCurrentCameraForActiveLens()
        }
        clearTransientHoverState()

        // Workspace state must exist before the destination view is evaluated,
        // and before its retained snapshot is checked below.
        if resolvedFrame == .timeline, timelineWorkspace == nil {
            let now = Date()
            let range = state.selectedTimeRange.range(relativeTo: now)
                ?? (now.addingTimeInterval(-30 * 24 * 60 * 60) ... now)
            timelineWorkspace = TimelineWorkspaceState(viewportRange: range)
        }
        if resolvedFrame == .projects, projectsWorkspace == nil {
            projectsWorkspace = ProjectsWorkspaceState()
        }
        if resolvedFrame == .frontPage, frontPageWorkspace == nil {
            frontPageWorkspace = FrontPageWorkspaceState()
        }

        state.prepareActionFilters(forEntering: resolvedFrame)
        var destinationFilter = state.filter
        if resolvedFrame.spatialLens != .meaning {
            destinationFilter.clusterIds = nil
        }
        let retentionLookupStartedAt = LensLoadPerformanceLog.start()
        let retainedMetalSurface = retainedMetalSurfaceForCurrentRequest(
            frame: resolvedFrame,
            filter: destinationFilter
        )
        if Self.usesMetalScene(resolvedFrame) {
            LensLoadPerformanceLog.record(
                lens: resolvedFrame,
                stage: "retention-lookup",
                startedAt: retentionLookupStartedAt,
                cache: retainedMetalSurface == nil ? "miss" : "hit"
            )
            if retainedMetalSurface == nil {
                armColdFirstPaintIfNeeded(
                    frame: resolvedFrame,
                    filter: destinationFilter
                )
            } else {
                coldFirstPaintRequest = nil
                coldFirstPaintAwaitingFirstDraw = nil
                coldFirstPaintPacketGeneratedAts.removeAll()
                coldFirstPaintStartedAt = nil
            }
        } else {
            coldFirstPaintRequest = nil
            coldFirstPaintAwaitingFirstDraw = nil
            coldFirstPaintPacketGeneratedAts.removeAll()
            coldFirstPaintStartedAt = nil
        }
        switch ConstellationFrameSwitchPolicy.frameRenderProgressAction(
            for: resolvedFrame,
            hasRetainedSurface: retainedMetalSurface != nil
        ) {
        case .begin:
            beginSceneRenderProgress(.frame(resolvedFrame))
        case .clear:
            clearSceneRenderProgress()
        }
        sceneRefreshGeneration &+= 1
        let retainedInstallStartedAt = retainedMetalSurface.map { _ in
            LensLoadPerformanceLog.start()
        }
        clearLensSurfaceForFrameSwitch(
            to: resolvedFrame,
            retainedMetalSurface: retainedMetalSurface
        )
        pendingCameraRestoreFrame = Self.usesMetalScene(resolvedFrame) ? resolvedFrame : nil
        nextVisibilityTransition = retainedMetalSurface == nil ? .frameSwitch : .continuous
        state.activeFrame = resolvedFrame
        if retainedMetalSurface != nil {
            applyPendingCameraRestoreIfReady(for: resolvedFrame)
            LensLoadPerformanceLog.record(
                lens: resolvedFrame,
                stage: "retained-install",
                startedAt: retainedInstallStartedAt,
                resultCount: retainedMetalSurface?.packet.stars.count ?? 0,
                cache: "hit"
            )
        }
        // The cluster scope is a Meaning-lens-only filter (the removable chip
        // and the engaging gestures both live there). Other lenses' rows carry
        // no `clusterId`, so a lingering `clusterIds` would silently empty their
        // scenes with no visible chip to clear it — drop it on the way out.
        // Cleared before `persistConstellationViewState()` so the saved snapshot
        // can't restore a non-Meaning frame with a stuck cluster scope.
        if resolvedFrame.spatialLens != .meaning {
            if Self.shouldCancelMeaningClusterFilterWarpForFrameSwitch(
                from: previousFrame,
                to: resolvedFrame,
                activeWarpSequence: clusterFilterWarpSequence,
                currentTransitionSequence: clusterFilterTransitionSequence,
                isWarping: warpAnimator.isWarping
            ) {
                warpAnimator.cancel()
            }
            clusterFilterTransitionSequence += 1
            clusterFilterWarpSequence = nil
            clusterFilterRestoreCamera = nil
            clusterFilterSourceHubs = []
        }
        if resolvedFrame.spatialLens != .meaning, state.filter.clusterIds != nil {
            applyMeaningClusterFilterIds(
                nil,
                suppressingFilterCameraReset: Self.usesMetalScene(resolvedFrame)
            )
        }
        requestTimelineRefreshForCurrentStateIfActive()
        requestFrontPageRefreshForCurrentStateIfActive()
        persistConstellationViewState()
        pendingFilterCameraReset = nil

        Task {
            // Timeline and Projects bypass the Metal scene pipeline entirely.
            // Skip the frame-burst / scene-data / cluster-label refreshes
            // for those lenses — they would only enqueue wasted jobs.
            guard Self.usesMetalScene(resolvedFrame) else { return }
            await enqueueFrameBurstIfNeeded(for: resolvedFrame)
            if resolvedFrame.spatialLens == .meaning {
                await refreshMeaningSceneForEntry(frame: resolvedFrame)
            } else {
                await refreshSceneData(frame: resolvedFrame)
                await refreshClusterLabels()
            }
        }
    }

    @MainActor
    private func clearLensSurfaceForFrameSwitch(
        to frame: FrameKey,
        retainedMetalSurface: ConstellationRetainedMetalSurface?
    ) {
        dyingSnapshots = []
        dyingPersonSnapshots = []
        birthingSnapshots = []
        pendingLockedDeletionReturn = nil

        if let retainedMetalSurface {
            installRetainedMetalSurface(retainedMetalSurface)
        } else {
            visibleRecordCache = [:]
            basePacket = .empty
            renderPacket = .empty
            renderPacketFrame = Self.lensLoadingFrameSentinel
            renderPacketFilter = nil
            renderPacketDisplayRequest = nil
            renderPacketGeneration = nil
            renderPacketHydratedGeneration = nil
            renderPacketFilterCameraResetSignature = nil
            lastMeaningClusterStoreSignature = nil
        }

        switch frame.spatialLens {
        case .frontPage:
            if let workspace = frontPageWorkspace,
               let snapshot = workspace.currentSnapshot,
               FrontPageDataController.signatureMatchesCurrentFilter(
                   snapshot: snapshot,
                   filter: state.filter,
                   selectedTimeRange: state.selectedTimeRange,
                   unreadOnly: workspace.unreadOnly
               ) == false {
                workspace.currentSnapshot = nil
            }
        case .timeline:
            if let workspace = timelineWorkspace,
               let snapshot = workspace.currentSnapshot,
               Self.timelineSnapshotMatchesCurrentRequest(
                   snapshot: snapshot,
                   expectedSignature: timelineData.latestSignature,
                   viewportRange: workspace.viewportRange
               ) == false {
                workspace.currentSnapshot = nil
            }
        case .projects:
            if let workspace = projectsWorkspace,
               let snapshot = workspace.currentSnapshot,
               ProjectsDataController.signatureMatchesCurrentFilter(
                   snapshot: snapshot,
                   filter: state.filter
               ) == false {
                workspace.currentSnapshot = nil
            }
        default:
            break
        }
    }

    @MainActor
    private func currentMetalDisplayRequest(
        frame: FrameKey,
        filter: VectorFilter? = nil,
        selectedTimeRange: TimeRangePreset? = nil,
        meaningClusterDisplayLimit: Int? = nil
    ) -> ConstellationMetalDisplayRequest {
        let resolvedFrame = frame.spatialLens
        return ConstellationMetalDisplayRequest(
            frame: resolvedFrame,
            filter: filter ?? state.filter,
            selectedTimeRange: selectedTimeRange ?? state.selectedTimeRange,
            meaningClusterDisplayLimit: resolvedFrame == .meaning
                ? (meaningClusterDisplayLimit ?? effectiveMeaningClusterDisplayCount)
                : nil
        )
    }

    @MainActor
    private var metalRetentionCaptureContext: ConstellationMetalRetentionContext {
        ConstellationMetalRetentionContext(
            hasLock: state.lockedVectorId != nil || liveLockPersonFocus != nil,
            hasHover: state.hoveredVectorId != nil || hoveredSunReadout,
            hasSearch: state.searchResultIds.isEmpty == false,
            hasCitations: qaVM.citationVectorIds.isEmpty == false,
            hasPendingFocus: pendingFocusClick != nil
                || queuedNotificationFocusMessageID != nil
                || pendingMetalNewStar != nil,
            hasTransitions: dyingSnapshots.isEmpty == false
                || dyingPersonSnapshots.isEmpty == false
                || birthingSnapshots.isEmpty == false
                || warpAnimator.isWarping
                || liveFocusExitInFlight
        )
    }

    @MainActor
    private var metalRetentionRestoreContext: ConstellationMetalRetentionContext {
        ConstellationMetalRetentionContext(
            hasLock: state.lockedVectorId != nil || liveLockPersonFocus != nil,
            hasSearch: state.searchResultIds.isEmpty == false,
            hasCitations: qaVM.citationVectorIds.isEmpty == false,
            hasPendingFocus: pendingFocusClick != nil
                || queuedNotificationFocusMessageID != nil
                || pendingMetalNewStar != nil
        )
    }

    @MainActor
    private func captureCurrentMetalSurfaceIfStable() {
        let frame = state.activeFrame.spatialLens
        guard Self.usesMetalScene(frame),
              renderPacketFrame.spatialLens == frame,
              let renderedRequest = renderPacketDisplayRequest,
              renderedRequest == currentMetalDisplayRequest(frame: frame),
              renderedRequest != coldFirstPaintRequest,
              renderedRequest != coldFirstPaintAwaitingFirstDraw,
              ConstellationMetalRetentionPolicy.canCapture(
                  context: metalRetentionCaptureContext,
                  renderedGeneration: renderPacketGeneration,
                  hydratedGeneration: renderPacketHydratedGeneration
              ) else {
            return
        }
        retainedMetalSurfaces[frame] = ConstellationRetainedMetalSurface(
            request: renderedRequest,
            packet: basePacket,
            filterCameraResetSignature: renderPacketFilterCameraResetSignature,
            visibleRecords: visibleRecordCache
        )
    }

    @MainActor
    private func retainedMetalSurfaceForCurrentRequest(
        frame: FrameKey,
        filter: VectorFilter? = nil
    ) -> ConstellationRetainedMetalSurface? {
        let resolvedFrame = frame.spatialLens
        guard Self.usesMetalScene(resolvedFrame),
              let retained = retainedMetalSurfaces[resolvedFrame],
              ConstellationMetalRetentionPolicy.canRestore(
                  retainedRequest: retained.request,
                  currentRequest: currentMetalDisplayRequest(
                      frame: resolvedFrame,
                      filter: filter
                  ),
                  context: metalRetentionRestoreContext
              ) else {
            return nil
        }
        return retained
    }

    @MainActor
    private func installRetainedMetalSurface(
        _ retained: ConstellationRetainedMetalSurface
    ) {
        basePacket = retained.packet
        renderPacket = retained.packet
        renderPacketFrame = retained.request.frame.spatialLens
        renderPacketFilter = retained.request.filter
        renderPacketDisplayRequest = retained.request
        renderPacketGeneration = sceneRefreshGeneration
        renderPacketHydratedGeneration = sceneRefreshGeneration
        renderPacketFilterCameraResetSignature = retained.filterCameraResetSignature
        visibleRecordCache = retained.visibleRecords
    }

    @MainActor
    private func invalidateRetainedLensSurfacesForMutation(
        preservingFrontPageProjectDefinitions: Bool
    ) {
        retainedMetalSurfaces.removeAll()
        if state.activeFrame.spatialLens != .frontPage {
            frontPageWorkspace?.currentSnapshot = nil
            if preservingFrontPageProjectDefinitions {
                frontPageData.invalidateMessageStateCacheForNextRequest()
            } else {
                frontPageData.invalidateCacheForNextRequest()
            }
        }
        if state.activeFrame.spatialLens != .timeline {
            timelineWorkspace?.currentSnapshot = nil
            timelineData.invalidateAll()
        }
        if state.activeFrame.spatialLens != .projects {
            projectsWorkspace?.currentSnapshot = nil
            projectsData.invalidateCacheForNextRequest()
        }
    }

    @MainActor
    private func markInactiveLensDataChanged(
        preservingFrontPageProjectDefinitions: Bool = false
    ) {
        if state.activeFrame.spatialLens != .frontPage {
            if preservingFrontPageProjectDefinitions {
                frontPageData.invalidateMessageStateCacheForNextRequest()
            } else {
                frontPageData.invalidateCacheForNextRequest()
            }
        }
        if state.activeFrame.spatialLens != .timeline {
            timelineData.invalidateAll()
        }
        if state.activeFrame.spatialLens != .projects {
            projectsData.invalidateCacheForNextRequest()
        }
    }

    @MainActor
    private func armColdFirstPaintIfNeeded(
        frame: FrameKey,
        filter: VectorFilter? = nil
    ) {
        let resolvedFrame = frame.spatialLens
        guard Self.usesMetalScene(resolvedFrame) else { return }
        let request = currentMetalDisplayRequest(
            frame: resolvedFrame,
            filter: filter
        )
        guard renderPacketDisplayRequest != request else { return }
        coldFirstPaintRequest = request
        coldFirstPaintAwaitingFirstDraw = nil
        coldFirstPaintPacketGeneratedAts.removeAll()
        coldFirstPaintStartedAt = LensLoadPerformanceLog.start()
    }

    @MainActor
    private func completeColdFirstPaintAfterFirstDrawIfNeeded(
        stats: ConstellationMetalFrameStats
    ) {
        let currentRequest = currentMetalDisplayRequest(frame: state.activeFrame)
        guard ConstellationColdFirstPaintPolicy.isFirstDrawOfColdPacket(
            awaitingFirstDraw: coldFirstPaintAwaitingFirstDraw,
            renderedRequest: renderPacketDisplayRequest,
            currentRequest: currentRequest,
            drawnPacketGeneratedAt: stats.packetGeneratedAt,
            coldPacketGeneratedAts: coldFirstPaintPacketGeneratedAts
        ) else {
            return
        }
        coldFirstPaintRequest = nil
        coldFirstPaintAwaitingFirstDraw = nil
        coldFirstPaintPacketGeneratedAts.removeAll()
        LensLoadPerformanceLog.record(
            lens: currentRequest.frame,
            stage: "first-draw",
            startedAt: coldFirstPaintStartedAt,
            resultCount: renderPacket.stars.count,
            cache: "miss"
        )
        coldFirstPaintStartedAt = nil
        guard AdaptiveRenderBudgetController.isUnderPressure(stats) == false else {
            return
        }
        nextVisibilityTransition = .continuous
        Task { await refreshSceneData() }
    }

    @MainActor
    private func recordColdFirstPaintPacketIfNeeded() {
        guard coldFirstPaintAwaitingFirstDraw == renderPacketDisplayRequest else { return }
        coldFirstPaintPacketGeneratedAts.insert(renderPacket.generatedAt)
    }

    @MainActor
    private func completeActiveFrameProgressIfReady() {
        guard isActiveFrameSwitchProgress,
              activeLensIsReady else {
            return
        }
        clearSceneRenderProgress()
    }

    /// Full lock-state release for a locked node that was just deleted from
    /// the scene. No exit warp is possible (the node is gone), so this is an
    /// immediate reset — same coverage as `clearLiveMetalLockForFrameSwitch`,
    /// plus the camera pullback to the pre-lock position. Covers correspondent
    /// locks whose hub survives the deletion (`liveLockPersonFocus` must clear
    /// even when `releasePeopleFocusIfDyingHubWasLocked` did not fire) and the
    /// Edit-menu mirror keys, which otherwise stay enabled for a deleted
    /// message.
    @MainActor
    private func releaseLockStateForRemovedNode() {
        lockRevealSequence += 1
        revealedLockedVectorId = nil
        pendingLiveFocusReveal = nil
        pendingPeopleLiveFocusReveal = nil
        lockEntryEnrichmentToken = nil
        lockSummaryInFlightToken = nil
        relatedSummaryPrewarmTask?.cancel()
        relatedSummaryPrewarmTask = nil
        suppressedPendingLockIndicatorVectorId = nil
        lockedNodeSelectionFallbackPoint = nil
        lockedNodeSelectionTransitionPoint = nil
        selectedNodeFocusWorld = nil
        focusedTransitionSourceSnapshot = nil
        liveFocusExitInFlight = false
        peopleLiveFocusExitInFlight = false
        pendingLockedDeletionReturn = nil
        warpAnimator.onComplete = nil
        warpAnimator.onProgress = nil
        // Reset the dim to 0 (background bodies + satellites visible), ring
        // BANDS pinned hidden: the still-installed packet may be a stale
        // portrait whose bands would otherwise flash until the follow-up
        // refresh lands — same reasoning as `finishLiveMetalLockRelease`.
        cancelPeopleContextDimRamp(resetPhase: 0, ringVisibility: 0)
        clearLiveMetalFocusWarp()
        state.lockedVectorId = nil
        liveLockPersonFocus = nil
        lockedRingSelectionMessageId = nil
        lockRingLegendPresented = false
        lockedNodeIDStorage = ""
        lockedNodeClassificationStorage = ""
        lockedNodeCustomKeysStorage = ""
        lockNeighbourRank.reset(rankedCount: 0)
        restoreSelectedNodeFocusCamera()
    }

    @MainActor
    private func clearLiveMetalLockForFrameSwitch() {
        lockRevealSequence += 1
        revealedLockedVectorId = nil
        pendingLiveFocusReveal = nil
        pendingPeopleLiveFocusReveal = nil
        lockEntryEnrichmentToken = nil
        lockSummaryInFlightToken = nil
        relatedSummaryPrewarmTask?.cancel()
        relatedSummaryPrewarmTask = nil
        suppressedPendingLockIndicatorVectorId = nil
        lockedNodeSelectionFallbackPoint = nil
        lockedNodeSelectionTransitionPoint = nil
        pendingFocusClick = nil
        focusSourcePreview = nil
        selectedNodeFocusWorld = nil
        selectedNodeFocusRestoreCamera = nil
        focusedTransitionSourceSnapshot = nil
        liveFocusExitInFlight = false
        peopleLiveFocusExitInFlight = false
        pendingLockedDeletionReturn = nil
        cancelPeopleContextDimRamp()
        clearLiveMetalFocusWarp()
        warpAnimator.cancel()
        clearTransientHoverState()
        state.lockedVectorId = nil
        liveLockPersonFocus = nil
        lockedRingSelectionMessageId = nil
        lockRingLegendPresented = false
        lockedNodeIDStorage = ""
        lockedNodeClassificationStorage = ""
        lockedNodeCustomKeysStorage = ""
        lockNeighbourRank.reset(rankedCount: 0)
    }

    @MainActor
    private func enqueueFrameBurstIfNeeded(for frame: FrameKey) async {
        guard frame != .defaultFrame,
              (try? services.vectorFrameLayoutStore.rowCount(frame: frame)) == 0 else {
            return
        }
        let payload = FrameBurstPayload(frame: frame)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        try? JobQueue().enqueue(
            type: .frameBurst,
            priority: 3,
            payload: json,
            context: modelContext
        )
    }

    @MainActor
    private func beginSceneRenderProgress(_ reason: SceneRenderProgressReason) {
        sceneRenderSequence += 1
        let sequence = sceneRenderSequence
        sceneRenderProgress = SceneRenderProgress(
            sequence: sequence,
            reason: reason
        )
        sceneRenderProgressVisible = false
        sceneRenderProgressRevealTask?.cancel()
        sceneRenderProgressRevealTask = Task { [sequence] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard sceneRenderProgress?.sequence == sequence else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    sceneRenderProgressVisible = true
                }
            }
        }
    }

    @MainActor
    private func completeSceneRenderProgressIfNeeded(for frame: FrameKey) {
        guard let progress = sceneRenderProgress else { return }
        switch progress.reason {
        case .frame(let targetFrame):
            guard Self.shouldCompleteSceneRenderProgress(
                progressFrame: targetFrame,
                renderedFrame: frame
            ) else { return }
            // This pill describes the foreground packet install, not the
            // background frame-burst persistence. During first ingestion the
            // People packet can render from live vector data before the
            // persisted frame layout arrives, and that worker completion may
            // not re-enter this view's clear path.
        case .filter, .timeRange, .search, .clearSearch:
            guard frame.spatialLens == state.activeFrame.spatialLens else { return }
        }
        clearSceneRenderProgress()
    }

    @MainActor
    private func clearSceneRenderProgress() {
        sceneRenderProgressRevealTask?.cancel()
        sceneRenderProgressRevealTask = nil
        withAnimation(.easeInOut(duration: 0.16)) {
            sceneRenderProgressVisible = false
        }
        sceneRenderProgress = nil
    }

    private static func sceneRenderProgressAccessibilityLabel(_ reason: SceneRenderProgressReason) -> String {
        switch reason {
        case .frame(let frame):
            return "Rendering \(frameTitle(frame)) frame"
        case .filter:
            return "Applying constellation filters"
        case .timeRange:
            return "Updating constellation time range"
        case .search:
            return "Applying constellation search"
        case .clearSearch:
            return "Clearing constellation search"
        }
    }

    @MainActor
    private func refreshSceneAfterClearingSearchIfNeeded(hadResultIds: Bool) {
        guard !hadResultIds else { return }
        Task { await refreshSceneData() }
    }

    @MainActor
    private func refreshMeaningSceneForEntry(frame: FrameKey) async {
        let resolvedFrame = frame.spatialLens
        guard resolvedFrame.spatialLens == .meaning else {
            await refreshSceneData(frame: resolvedFrame, updateColorLookup: true)
            return
        }

        meaningClusterPipelineStatus = currentMeaningClusterPipelineStatus()
        if meaningClusterPipelineStatus.isReadyForDisplay {
            await refreshClusterLabels(
                frame: resolvedFrame,
                forceSnapshotRefresh: false,
                refreshSceneOnGain: false
            )
            if let storedClusters = displayClusters(
                for: resolvedFrame,
                context: "meaning lens entry"
            ) {
                lastMeaningClusterStoreSignature = MeaningClusterPublicationIdentity(
                    frame: resolvedFrame,
                    clusters: storedClusters
                )
            }
        }
        await refreshSceneData(frame: resolvedFrame, updateColorLookup: true)
    }

    private static func frameTitle(_ frame: FrameKey) -> String {
        switch frame.spatialLens {
        case .meaning, .defaultFrame: return "Meanings"
        case .people:                 return "People"
        case .timeline:               return "Timeline"
        case .projects:               return "Projects"
        default:                      return frame.rawValue.capitalized
        }
    }

    private static func visualSceneFilter(frame: FrameKey, filter: VectorFilter) -> VectorFilter {
        PeopleFrameFilterPolicy.visualFilter(frame: frame, filter: filter)
    }

    private func peopleFrameFocus(frame: FrameKey, filter: VectorFilter) -> PeopleFrameFocus? {
        PeopleFrameFilterPolicy.focus(
            frame: frame,
            filter: filter,
            expandsToOneHop: peopleFocusExpandsToOneHop
        )
    }

    @MainActor
    private var peopleLiveFocusReframeKey: PeopleLiveFocusReframeKey {
        let normalizedEmail = liveLockPersonFocus.map {
            PeopleRingMessageScope.normalizedEmail($0.email)
        }
        return PeopleLiveFocusReframeKey(
            activeFrame: state.activeFrame.spatialLens,
            renderPacketFrame: renderPacketFrame.spatialLens,
            lockedVectorId: state.lockedVectorId,
            liveFocusEmail: normalizedEmail,
            currentFilter: state.filter,
            renderedFilter: renderPacketFilter,
            geometry: Self.peopleLiveFocusGeometrySignature(
                forEmail: normalizedEmail,
                in: renderPacket
            )
        )
    }

    private static func peopleLiveFocusGeometrySignature(
        forEmail email: String?,
        in packet: ConstellationRenderPacket
    ) -> PeopleLiveFocusGeometrySignature {
        guard let email,
              let hub = matchingPersonHub(forEmail: email, in: packet.personHubs) else {
            return PeopleLiveFocusGeometrySignature(
                hubMessageCount: 0,
                hubMessageChecksum: 0,
                ringCount: 0,
                outerRingEdgeBucket: 0,
                hubXBucket: 0,
                hubYBucket: 0,
                hubZBucket: 0
            )
        }
        return PeopleLiveFocusGeometrySignature(
            hubMessageCount: hub.messageIds.count,
            hubMessageChecksum: checksum(messageIds: hub.messageIds),
            ringCount: hub.rings.count,
            outerRingEdgeBucket: quantized(hub.rings.map { $0.radius + $0.thickness }.max() ?? 0),
            hubXBucket: quantized(hub.position.x),
            hubYBucket: quantized(hub.position.y),
            hubZBucket: quantized(hub.position.z)
        )
    }

    private static func matchingPersonHub(
        forEmail email: String,
        in hubs: [PersonHubInstance]
    ) -> PersonHubInstance? {
        let normalized = PeopleRingMessageScope.normalizedEmail(email)
        guard !normalized.isEmpty else { return nil }
        return hubs.first { PeopleRingMessageScope.normalizedEmail($0.email) == normalized }
    }

    private static func quantized(_ value: Float) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value * 10_000).rounded())
    }

    private static func checksum(messageIds: Set<String>) -> Int64 {
        messageIds.sorted().reduce(Int64(0)) { running, messageId in
            let scalarSum = messageId.unicodeScalars.reduce(Int64(0)) { partial, scalar in
                partial &+ Int64(scalar.value)
            }
            return (running &* 31) &+ scalarSum
        }
    }

    /// Email of the correspondent whose Saturn is live-locked, or nil
    /// when no Saturn is currently locked. Intentionally excludes
    /// `pendingFocusClick` — a pending click is not a lock. A committed
    /// correspondent lock installs `liveLockPersonFocus` synchronously
    /// with `lockedVectorId`, so from the click frame onward this returns
    /// the focused email and no refresh can classify the lock as an
    /// email-node lock.
    @MainActor
    private func lockedCorrespondentFocusEmail() -> String? {
        let raw = liveLockPersonFocus?.email
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    @MainActor
    private func correspondentHubColor(filter: VectorFilter) -> SIMD3<Float> {
        // Planet body uses the raw AccountColor so the orb's hue is the
        // user's account identity itself, not the `+3` desaturated
        // correspondent accent. The ring still uses the alternate-accent
        // palette via `correspondentRingColor(filter:)` so the body and
        // ring read as related-but-distinct members of the same system.
        let sourceColorIndex = correspondentAccentSourceColorIndex(filter: filter)
        let rgba = AccountColorPalette.rgb(
            for: AccountColorPalette.color(forIndex: sourceColorIndex),
            brightness: 1.0
        )
        return SIMD3<Float>(rgba.x, rgba.y, rgba.z)
    }

    @MainActor
    private func correspondentRingColor(filter: VectorFilter) -> SIMD3<Float> {
        let usedColorIndices = Set(accounts.map { AccountColorPalette.color(forIndex: $0.colorIndex).id })
        let sourceColorIndex = correspondentAccentSourceColorIndex(filter: filter)
        return AccountColorPalette.ringAccentRGB(
            forAccountColorIndex: sourceColorIndex,
            usedAccountColorIndices: usedColorIndices
        )
    }

    @MainActor
    private func correspondentRingTierColors(filter: VectorFilter) -> [SIMD3<Float>] {
        let usedColorIndices = Set(accounts.map { AccountColorPalette.color(forIndex: $0.colorIndex).id })
        let sourceColorIndex = correspondentAccentSourceColorIndex(filter: filter)
        return AccountColorPalette.tierBandColorsRGB(
            forAccountColorIndex: sourceColorIndex,
            usedAccountColorIndices: usedColorIndices
        )
    }

    @MainActor
    private func correspondentAccentSourceColorIndex(filter: VectorFilter) -> Int {
        let scopedAccounts: [Account]
        if let accountIds = filter.accountIds, !accountIds.isEmpty {
            scopedAccounts = accounts.filter { accountIds.contains($0.id) }
        } else {
            scopedAccounts = accounts
        }
        let account = scopedAccounts.sorted {
            let lhs = Self.accountSortKey($0)
            let rhs = Self.accountSortKey($1)
            if lhs != rhs { return lhs < rhs }
            return $0.id.uuidString < $1.id.uuidString
        }.first
        return AccountColorPalette.color(forIndex: account?.colorIndex).id
    }

    private static func accountSortKey(_ account: Account) -> String {
        let displayName = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let email = account.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(displayName)|\(email)"
    }

    @MainActor
    private func refreshSceneData(
        frame: FrameKey? = nil,
        baseFilter: VectorFilter? = nil,
        updateColorLookup: Bool = false,
        rebuildScene: Bool = true,
        revealCachedSnapshotFirst: Bool = false
    ) async {
        sceneRefreshGeneration &+= 1
        let requestedGeneration = sceneRefreshGeneration
        if renderRefreshInFlight {
            renderRefreshPending = true
            return
        }

        renderRefreshInFlight = true
        defer { renderRefreshInFlight = false }
        var explicitFrame = frame
        var passGeneration = requestedGeneration
        // Arrival reveal: the caller has just patched the snapshot cache
        // (announced live arrivals inserted synchronously in the announce
        // turn), so the first pass builds its packet from the cached
        // snapshot regardless of age — no store reload stands between the
        // alert and the rendered node. The canonical pass that reloads
        // from the store always follows (`renderRefreshPending` is forced
        // below). When no snapshot is cached for the frame there is
        // nothing patched to reveal; the single pass loads canonically.
        var revealPassRemaining = revealCachedSnapshotFirst
        repeat {
            renderRefreshPending = false
            passGeneration = sceneRefreshGeneration
            let visibilityTransition = nextVisibilityTransition
            nextVisibilityTransition = .continuous
            let resolvedFrame = explicitFrame ?? state.activeFrame
            explicitFrame = nil
            let signatureFilter = baseFilter ?? state.filter
            let passSelectedTimeRange = state.selectedTimeRange
            let passMeaningClusterDisplayLimit = resolvedFrame.spatialLens == .meaning
                ? effectiveMeaningClusterDisplayCount
                : nil
            let passDisplayRequest = currentMetalDisplayRequest(
                frame: resolvedFrame,
                filter: signatureFilter,
                selectedTimeRange: passSelectedTimeRange,
                meaningClusterDisplayLimit: passMeaningClusterDisplayLimit
            )
            let packetFilterCameraResetSignature = filterCameraResetSignature(
                frame: resolvedFrame,
                filter: signatureFilter
            )
            let resolvedFilter = ConstellationFilterResolver.effectiveSceneFilter(
                baseFilter: signatureFilter,
                selectedTimeRange: passSelectedTimeRange
            )
            let visualFilter = Self.visualSceneFilter(frame: resolvedFrame, filter: resolvedFilter)
            let shouldIncludeMeaningClusters = shouldRenderMeaningClusters(for: resolvedFrame)
            if shouldRefreshMeaningClustersBeforeRender(
                frame: resolvedFrame,
                shouldIncludeClusters: shouldIncludeMeaningClusters
            ) {
                await refreshClusterLabels(
                    frame: resolvedFrame,
                    forceSnapshotRefresh: true,
                    refreshSceneOnGain: false
                )
            }
            // When a Saturn is locked in the People lens, override the
            // filter-driven correspondent focus with the clicked
            // correspondent's email so the renderer narrows the People
            // graph layout to that one hub. Matches the user's spec:
            // "the locked-node overlay in the Peoples lens shows a
            // detailed, focused, and isolated view of this one
            // person's correspondent node or saturn." Falls back to
            // the filter-driven focus when no Saturn is locked.
            // When the user has clicked a Saturn in the People lens, the
            // live render narrows to that one correspondent's hub + ring
            // bands by synthesizing a `PeopleFrameFocus` from the locked
            // correspondent's email. `matchesAnyRole: true` is the key —
            // the Saturn's rings must show every exchanged email (both
            // messages from the correspondent and messages to them),
            // not just the half where they were the sender. Strict mode
            // (`expandsToOneHop: false`) keeps the portrait isolated to
            // exactly one correspondent Saturn, with no one-hop co-recipient
            // hubs added around it.
            // One consistent lock snapshot per pass. The vector id and the
            // correspondent focus MUST be read together, synchronously:
            // this pass suspends at `constellationSnapshot` below, and a
            // lock engaged during that suspension would otherwise let the
            // request mix a post-click `lockedVectorId` with the pre-click
            // nil correspondent — the planner then mis-classifies a
            // correspondent lock as an email-node lock (deep 0.18 people
            // dim, email-anchored context flags) for one packet. Reading
            // both here means a mid-pass lock produces a coherent pre-lock
            // packet, and the lock path's own refresh follows with the
            // coherent locked one.
            let passLockedVectorId = state.lockedVectorId
            let lockedCorrespondentEmail = lockedCorrespondentFocusEmail()
            let peopleFocus: PeopleFrameFocus? = {
                if resolvedFrame.spatialLens == .people,
                   let email = lockedCorrespondentEmail {
                    return PeopleFrameFocus(
                        query: email,
                        scope: .from,
                        displayName: liveLockPersonFocus?.displayName
                            ?? pendingFocusClick?.personFocus?.displayName,
                        expandsToOneHop: false,
                        matchesAnyRole: true,
                        pinnedHubWorldPosition: liveLockPersonFocus?.worldPosition
                    )
                }
                return peopleFrameFocus(frame: resolvedFrame, filter: resolvedFilter)
            }()
            let snapshotStartedAt = LensLoadPerformanceLog.start()
            let passIsReveal = revealPassRemaining
                && snapshotCache.snapshot(
                    for: resolvedFrame,
                    maxAge: .greatestFiniteMagnitude
                ) != nil
            revealPassRemaining = false
            if passIsReveal {
                // Set before any await/`continue`: the canonical follow-up
                // pass must run even if this reveal pass is superseded
                // mid-flight by the retention policy.
                renderRefreshPending = true
            }
            let snapshot = await constellationSnapshot(
                for: resolvedFrame,
                maxAge: passIsReveal ? .greatestFiniteMagnitude : 15,
                forceRefresh: updateColorLookup && !passIsReveal
            )
            LensLoadPerformanceLog.record(
                lens: resolvedFrame,
                stage: "snapshot",
                startedAt: snapshotStartedAt,
                resultCount: snapshot.messageIndex.count
            )
            // Arrival embargo, read AFTER the snapshot await so an
            // announcement that lands mid-refresh is reflected: live
            // arrivals stay invisible to the scene and new-star tracking until
            // their unified alert moment.
            let arrivalEmbargo = NewMailArrivalLedger.shared.embargoedMessageIds
            let effectiveMessageIndex = NewMailArrivalLedger.shared
                .filteredMessageIndex(snapshot.messageIndex)
            // Every correspondent's filtered scope, rebuilt on the concurrent
            // executor while the planner runs, so hover, ring, and
            // click-gate lookups need no per-view-update scan of the index.
            // Packet install never waits for it. A locked correspondent's
            // ring scope is a planner input, so it is scanned separately
            // (also off the main actor). That scan is a suspension point
            // after the lock snapshot above: the lock fields stay coherent,
            // and fields read later follow the same rules as after the
            // planner's own await.
            let passUserAddresses = userAddressSet
            schedulePeopleCorrespondentScope(
                frame: resolvedFrame,
                filter: signatureFilter,
                selectedTimeRange: passSelectedTimeRange,
                visualFilter: visualFilter,
                userAddresses: passUserAddresses
            )
            let lockedCorrespondentMessageIds: Set<String>
            if let lockedCorrespondentEmail {
                lockedCorrespondentMessageIds = await Self.concurrentPeopleScopedMessageIds(
                    involving: lockedCorrespondentEmail,
                    filter: visualFilter,
                    messageIndex: effectiveMessageIndex,
                    userAddresses: passUserAddresses
                )
            } else {
                lockedCorrespondentMessageIds = []
            }
            let searchScoreById = Dictionary(uniqueKeysWithValues:
                zip(state.searchResultIds, searchScores).map { ($0.0, $0.1) }
            )
            // Meaning lens swaps the timeline-dimmed account tint for the
            // raw AccountColor on every email node. Two reasons:
            //   - the user reads "what account is this from" as the primary
            //     identity of every node in the cacophony, and the timeline
            //     aging muddies that signal;
            //   - tinting every node by its cluster would imply that every
            //     email fits neatly into one of the discovered clusters,
            //     which is the *opposite* of what a cluster orb is meant
            //     to communicate. The orb is the cluster signal; the
            //     nodes underneath remain account-coloured.
            let resolvedColorByMessageId = snapshot.colorByMessageId
            let accountColorLookup = accountColorIndexByAccountId()
            let assignedPaletteIndices = Set(accountColorLookup.values.map {
                AccountColorPalette.color(forIndex: $0).id
            })
            // Meaning-lens cluster ramp: one fixed blue → violet → rose
            // spectral family, appearance-resolved here at the SwiftUI
            // boundary. The planner hands the top-ranked clusters distinct
            // stops; ambient clusters take the anchor base.
            let meaningClusterPalette = MeaningClusterLensPalette.resolve(
                isDarkAppearance: colorScheme == .dark
            )
            let planningCameraState = pendingCameraRestoreState(for: resolvedFrame)
                ?? cameraController.state
            let request = ConstellationRenderRequest(
                filter: visualFilter,
                lens: ConstellationLens(
                    frame: resolvedFrame,
                    aperture: state.aperture,
                    viewSize: viewSize,
                    camera: planningCameraState
                ),
                frameLayoutStore: services.vectorFrameLayoutStore,
                frameEdgeProvider: frameEdgeProvider,
                messageIndex: effectiveMessageIndex,
                clusters: shouldIncludeMeaningClusters ? clusters : [],
                colorByMessageId: resolvedColorByMessageId,
                activeVectorIds: buildAlwaysInclude(),
                citationVectorIds: Set(qaVM.citationVectorIds),
                searchScores: searchScoreById,
                hoveredVectorId: state.hoveredVectorId,
                lockedVectorId: passLockedVectorId,
                fieldDimFactor: ConstellationLockDimFactor.resolve(
                    lockedVectorId: passLockedVectorId,
                    dimEnabled: state.lockOverlayDimEnabled,
                    spatialLens: resolvedFrame.spatialLens,
                    hasPersonFocus: lockedCorrespondentEmail != nil
                ),
                budget: renderBudgetForCurrentState(request: passDisplayRequest),
                pinnedCorrespondents: pinnedEmailsMirror,
                peopleFocus: peopleFocus,
                lockedCorrespondentEmail: lockedCorrespondentEmail,
                lockedCorrespondentMessageIds: lockedCorrespondentMessageIds,
                accountColorIndexByAccountId: accountColorLookup,
                correspondentHubColor: correspondentHubColor(filter: resolvedFilter),
                correspondentRingColor: correspondentRingColor(filter: resolvedFilter),
                correspondentRingTierColors: correspondentRingTierColors(filter: resolvedFilter),
                userAddresses: passUserAddresses,
                meaningClusterPalette: meaningClusterPalette,
                meaningClusterDisplayLimit: passMeaningClusterDisplayLimit
                    ?? effectiveMeaningClusterDisplayCount,
                embargoedMessageIds: arrivalEmbargo,
                // The sun claims an unused palette slot (the `+3` system,
                // preferring Capella Gold) so the user's body reads as its
                // own identity — never an account color, never the hub
                // planets' correspondent accent. Body, hot-center glow, and
                // granulation all derive from this one color shader-side.
                personSunColor: AccountColorPalette.personSunAccentRGB(
                    usedAccountColorIndices: assignedPaletteIndices,
                    isDarkAppearance: colorScheme == .dark
                ),
                personOrbitPathColor: AccountColorPalette.personOrbitPathRGB(
                    isDarkAppearance: colorScheme == .dark
                ),
                // Orbital epoch: hub base positions bake at the motion
                // controller's current clock, so a frozen clock (locks,
                // stopped system) yields zero renderer displacement and
                // fully settled geometry for every downstream consumer.
                peopleOrbitalClock: peopleOrbitalMotion.clock
            )
            let plannerStartedAt = LensLoadPerformanceLog.start()
            let plannedPacket = await renderPlanner.makePacket(request)
            LensLoadPerformanceLog.record(
                lens: resolvedFrame,
                stage: "planner",
                startedAt: plannerStartedAt,
                candidateCount: effectiveMessageIndex.count,
                resultCount: plannedPacket.stars.count,
                cache: passDisplayRequest == coldFirstPaintRequest ? "cold" : "warm"
            )
            let revealNow = Date.now
            syncOnboardingRevealSchedule(with: plannedPacket, now: revealNow)
            let scenePacket = onboardingMode
                ? revealedOnboardingPacket(from: plannedPacket, now: revealNow)
                : plannedPacket
            let packet = peopleLevelOfDetailPacketIfNeeded(
                scenePacket,
                frame: resolvedFrame,
                camera: planningCameraState
            )
            guard ConstellationMetalRetentionPolicy.shouldInstallPlannedPacket(
                passGeneration: passGeneration,
                currentGeneration: sceneRefreshGeneration,
                plannedRequest: passDisplayRequest,
                currentRequest: currentMetalDisplayRequest(frame: state.activeFrame)
            ) else {
                continue
            }
            // Detect freshly-arrived stars. In normal mode, seed the lifecycle
            // from the full snapshot message universe so filter changes do not
            // make old, newly-visible nodes look newly added. Onboarding uses
            // its staged reveal packet as the observation universe so each
            // reveal can still bloom as it appears. Embargoed live arrivals
            // are excluded (`effectiveMessageIndex`) so the lifecycle never
            // "observes" them early — their birth bloom must trigger at the
            // refresh that follows the arrival announcement.
            let birthObservationMessageIds = onboardingMode
                ? Set(packet.stars.map(\.messageId))
                : Set(effectiveMessageIndex.keys)
            captureBirthingNodes(
                from: packet,
                observedMessageIds: birthObservationMessageIds,
                now: revealNow,
                transition: visibilityTransition
            )
            pruneCompletedDyingPersonSnapshots(for: packet, now: revealNow)
            basePacket = packet
            renderPacketFrame = resolvedFrame.spatialLens
            renderPacketFilter = signatureFilter
            renderPacketDisplayRequest = passDisplayRequest
            renderPacketGeneration = passGeneration
            renderPacketHydratedGeneration = nil
            if passDisplayRequest == coldFirstPaintRequest {
                coldFirstPaintAwaitingFirstDraw = passDisplayRequest
            } else if coldFirstPaintRequest != nil {
                coldFirstPaintRequest = nil
                coldFirstPaintAwaitingFirstDraw = nil
                coldFirstPaintPacketGeneratedAts.removeAll()
                coldFirstPaintStartedAt = nil
            }
            renderPacketFilterCameraResetSignature = packetFilterCameraResetSignature
            renderPacket = Self.combinePacket(
                base: packet,
                dying: dyingSnapshots,
                dyingPeople: dyingPersonSnapshots,
                birthing: birthingSnapshots,
                now: revealNow
            )
            if resolvedFrame.spatialLens == .meaning, !onboardingMode {
                let availableCount = Self.meaningClusterAvailableCount(
                    clusters: clusters,
                    visibleStars: packet.stars,
                    messageIndex: effectiveMessageIndex
                )
                let adjustedDisplayLimit = min(
                    configuredMeaningClusterDisplayLimit,
                    availableCount
                )
                if scopedMeaningClusterAvailableCount != availableCount {
                    scopedMeaningClusterAvailableCount = availableCount
                }
                scheduleMeaningClusterScopeMessageCount(
                    filter: signatureFilter,
                    selectedTimeRange: passSelectedTimeRange,
                    visualFilter: visualFilter,
                    messageIndex: effectiveMessageIndex
                )
                // A Moments/filter change can move the scoped ceiling across
                // the user's configured request. Repeat only when the packet
                // was planned with a now-stale limit; the count itself never
                // invokes clustering, storage, or model work.
                if passMeaningClusterDisplayLimit != adjustedDisplayLimit {
                    renderRefreshPending = true
                }
                meaningLabeler.scheduleUpdate(
                    clusters: clusters,
                    messageIndex: snapshot.messageIndex,
                    titleGenerator: meaningClusterTitleGenerator,
                    titleGenerationClusterIds: Set(
                        packet.meaningClusterHubs.map(\.clusterId)
                    )
                )
            }
            recordColdFirstPaintPacketIfNeeded()
            LensLoadPerformanceLog.record(
                lens: resolvedFrame,
                stage: "packet-install",
                resultCount: packet.stars.count,
                cache: passDisplayRequest == coldFirstPaintRequest ? "cold" : "warm"
            )
            refreshLiveFocusAnchorIfAvailable(
                frame: resolvedFrame,
                packet: packet
            )
            completeLiveFocusRevealIfFocusedPacketInstalled(
                frame: resolvedFrame,
                packet: packet
            )
            completePeopleLiveFocusRevealIfFocusedPacketInstalled(
                frame: resolvedFrame,
                packet: packet
            )
            applyPendingCameraRestoreIfReady(for: resolvedFrame)
            await applyPendingFilterCameraResetIfReady(for: resolvedFrame)
            await applyDefaultConstellationCameraIfNeeded(frame: resolvedFrame, reason: .startup)
            completeSceneRenderProgressIfNeeded(for: resolvedFrame)
            lastPlannedCameraSignature = CameraPlanningSignature(cameraController.state)
            let visibleIds = Array(Set(packet.hitProxies.map(\.vectorId).filter { $0 > 0 }))
            // The cache serves messageId / layout / collection lookups only,
            // so the display-metadata hydrate (no embedding BLOBs, no text
            // payloads) suffices — and it runs detached so the
            // thousands-of-rows SQLite read never blocks the main thread
            // mid-transition. The pass still awaits the result here because
            // `syncNewStarNavigator` consumes the records directly below.
            let visibleRecordStore = services.vectorStore
            let visibleRecords = await Task.detached(priority: .userInitiated) {
                (try? visibleRecordStore.hydrateDisplayMetadata(vectorIds: visibleIds)) ?? []
            }.value
            guard passGeneration == sceneRefreshGeneration,
                  passDisplayRequest == currentMetalDisplayRequest(frame: state.activeFrame) else {
                continue
            }
            visibleRecordCache = Dictionary(
                uniqueKeysWithValues: visibleRecords.map { ($0.vectorId, $0) }
            )
            renderPacketHydratedGeneration = passGeneration
            syncNewStarNavigator(
                availableRecords: visibleRecords,
                messageIndex: effectiveMessageIndex,
                includesUntrackedArrivals: true
            )
            completePendingMetalNewStarNavigation(requestRefreshIfUnavailable: false)
            completePendingNotificationFocusNavigation()
            frameOnboardingCameraIfNeeded(for: plannedPacket)
            reportInitialSceneReadyIfReady(packet)
            captureCurrentMetalSurfaceIfStable()
            _ = rebuildScene
        } while renderRefreshPending
    }

    private var sidebarTogglePublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: .ohiaToggleSidebar)
    }

    private var withheldTogglePublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: .ohiaToggleWithheld)
    }

    /// The scene MUST keep one structural identity whether or not the
    /// window-edge control column is present. Branching between an
    /// HStack-wrapped scene and a bare scene gives SwiftUI two different
    /// subtree identities, so every `showsWindowEdgeControlColumn` flip —
    /// which happens twice per lock cycle in the People and Meaning
    /// lenses — dismantled and remounted the entire scene including the
    /// MTKView (blank until its first draw: the "all nodes disappear then
    /// reappear" flash). The HStack is therefore permanent; only the
    /// column slots toggle, which never changes the scene child's
    /// identity.
    private var constellationWindowEdgeLayout: some View {
        let onLeading = windowEdgeControlColumnOnLeading
        return HStack(spacing: 0) {
            if showsWindowEdgeControlColumn, onLeading {
                windowEdgeControlColumn(onLeading: true)
            }

            constellationSplitLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsWindowEdgeControlColumn, !onLeading {
                windowEdgeControlColumn(onLeading: false)
            }
        }
    }

    private var windowEdgeControlColumnOnLeading: Bool {
        // The rail is window-edge chrome: if the Search/Ask sidebar moves to the
        // trailing edge, the rail flips to the far leading border.
        sidebarSideRaw == "trailing"
    }

    @MainActor
    private var showsWindowEdgeControlColumn: Bool {
        ConstellationEdgeColumnPolicy.showsColumn(
            activeLens: state.activeFrame,
            isOnboarding: onboardingMode,
            lensSurfaceStatus: activeLensSurfaceStatus,
            peopleLockColumnActive: peopleLockColumnActive,
            hasActiveWorkspace: activeLensWorkspacePresent,
            lockedVectorId: state.lockedVectorId
        )
    }

    @MainActor
    private var activeLensWorkspacePresent: Bool {
        switch state.activeFrame.spatialLens {
        case .frontPage:
            return frontPageWorkspace != nil
        case .timeline:
            return timelineWorkspace != nil
        case .projects:
            return projectsWorkspace != nil
        default:
            return true
        }
    }

    /// Both the close column and the unlocked corner column are 70pt, so
    /// the content swap at the lock-lifecycle boundaries is width-neutral;
    /// the lifecycle gating itself lives in `ConstellationEdgeColumnPolicy`.
    @MainActor
    private var peopleLockColumnActive: Bool {
        ConstellationEdgeColumnPolicy.peopleLockColumnActive(
            activeLens: state.activeFrame,
            lockedVectorId: state.lockedVectorId,
            hasLivePersonFocus: liveLockPersonFocus != nil
        )
    }

    @MainActor
    private var peopleLiveFocusControlsVisible: Bool {
        guard state.activeFrame.spatialLens == .people,
              liveLockPersonFocus != nil,
              !peopleLiveFocusExitInFlight,
              pendingPeopleLiveFocusReveal == nil,
              let lockedVectorId = state.lockedVectorId else {
            return false
        }
        return revealedLockedVectorId == lockedVectorId
    }

    @ViewBuilder
    @MainActor
    private func windowEdgeControlColumn(onLeading: Bool) -> some View {
        if peopleLockColumnActive {
            peopleFocusCloseButtonColumn(onLeading: onLeading)
        } else {
            switch state.activeFrame.spatialLens {
            case .frontPage:
                if let workspace = frontPageWorkspace {
                    FrontPageRightControlColumn(
                        workspace: workspace,
                        onLeading: onLeading,
                        newStarNavigator: newStarNavigator,
                        manualRefresh: manualRefresh,
                        onStarburstClick: handleStarburstClick,
                        onBeaconMenuCommand: handleBeaconMenuCommand,
                        actions: frontPageMessageActions.beginningStatusGestures(
                            with: workspace.statusGestureCoordinator
                        )
                    )
                }
            case .timeline:
                if let workspace = timelineWorkspace {
                    TimelineRightControlColumn(
                        workspace: workspace,
                        conversationModeOn: $timelineConversationModeAppStorage,
                        onLeading: onLeading,
                        newStarNavigator: newStarNavigator,
                        manualRefresh: manualRefresh,
                        onStarburstClick: handleStarburstClick,
                        onBeaconMenuCommand: handleBeaconMenuCommand,
                        actions: timelineMessageActions(workspace: workspace)
                    )
                }
            case .projects:
                if let workspace = projectsWorkspace {
                    projectsWindowEdgeControlColumn(workspace: workspace, onLeading: onLeading)
                }
            case .meaning:
                MeaningRightControlColumn(
                    onLeading: onLeading,
                    newStarNavigator: newStarNavigator,
                    manualRefresh: manualRefresh,
                    onStarburstClick: handleStarburstClick,
                    onBeaconMenuCommand: handleBeaconMenuCommand,
                    onRecenter: recenterCamera,
                    recenterEnabled: !liveFocusExitInFlight && LockedRecenterControlPolicy.isEnabled(
                        lockedVectorId: state.lockedVectorId,
                        revealedLockedVectorId: revealedLockedVectorId
                    ),
                    hasSearch: state.searchResultIds.isEmpty == false,
                    hasCitations: qaVM.citationVectorIds.isEmpty == false,
                    hasSelection: LiveFocusExitPolicy.shouldExposeReleaseControls(
                        lockedVectorId: state.lockedVectorId,
                        exitInFlight: liveFocusExitInFlight
                    ),
                    hasNebulae: renderPacket.nebulae.isEmpty == false,
                    hasFibers: renderPacket.fibers.isEmpty == false,
                    clusterValue: meaningClusterDisplayBinding,
                    clusterStatus: meaningClusterPipelineStatus,
                    clusterAvailableCount: scopedMeaningClusterAvailableCount ?? 0,
                    // One hub represents one complete semantic cluster, so
                    // the visible hub count matches the slider's cluster cap.
                    clusterVisibleCount: meaningClusterDisplayLimit == 0
                        ? 0
                        : Set(renderPacket.meaningClusterHubs.map(\.clusterId)).count,
                    activeClusterFilter: activeMeaningClusterFilter,
                    onClearClusterFilter: clearMeaningClusterFilter,
                    onClusterChipHover: handleMeaningClusterChipHover,
                    clusterListEntries: meaningClusterListEntries,
                    onToggleClusterInScope: toggleMeaningClusterScopeMembership,
                    onClusterRowHover: handleMeaningClusterRowHover,
                    onClusterListClosed: dismissMeaningClusterHover,
                    showsMessageActions: LiveFocusExitPolicy.shouldExposeReleaseControls(
                        lockedVectorId: state.lockedVectorId,
                        exitInFlight: liveFocusExitInFlight
                    ),
                    messageActionTarget: meaningLockedMainEmailActionTarget,
                    actions: meaningLockedMessageActions,
                    onReleaseLock: leaveSelectedNodeFocus
                )
            default:
                cornerControlsColumn(onLeading: onLeading)
            }
        }
    }

    @MainActor
    private func projectsWindowEdgeControlColumn(
        workspace: ProjectsWorkspaceState,
        onLeading: Bool
    ) -> some View {
        let sendToComposer: @MainActor @Sendable ([UUID]) -> Void = { ids in
            frontPageSendToComposer(ids, openComposer: ComposerOpenOnQueuePreference.opensComposer(optionHeld: NSEvent.modifierFlags.contains(.option)))
        }
        return ProjectsRightControlColumn(
            workspace: workspace,
            onLeading: onLeading,
            newStarNavigator: newStarNavigator,
            manualRefresh: manualRefresh,
            onStarburstClick: handleStarburstClick,
            onBeaconMenuCommand: handleBeaconMenuCommand,
            clearMessageFiltersActive: ProjectsMessageFilterScope.isActive(
                filter: state.filter,
                restFilter: ConstellationState.projectsLensMessageFilterRestState()
            ),
            onClearMessageFilters: {
                state.clearProjectsLensMessageFilters()
            },
            onSetPinned: { row, pinned in
                let repository = MailProjectRepository(modelContext: modelContext)
                performProjectsLifecycleMutation(
                    workspace: workspace,
                    action: pinned ? .pin : .unpin
                ) {
                    try repository.setPinned(projectID: row.projectID, pinned)
                }
            },
            onSetResolved: { row, resolved in
                let repository = MailProjectRepository(modelContext: modelContext)
                performProjectsLifecycleMutation(
                    workspace: workspace,
                    action: resolved ? .resolve : .reopen
                ) {
                    try repository.setResolved(projectID: row.projectID, resolved)
                }
            },
            deadlineDisposition: { entryID in
                DeadlineGuideStateStore(modelContext: modelContext)
                    .disposition(entryID: entryID)
            },
            onSetDeadlinePinned: { entry, pinned in
                let store = DeadlineGuideStateStore(modelContext: modelContext)
                performDeadlineLifecycleMutation(
                    workspace: workspace,
                    action: pinned ? .pinDeadline : .unpinDeadline
                ) {
                    try store.setPinned(pinned, entryID: entry.id)
                }
            },
            onSetDeadlineHidden: { entry, hidden in
                let store = DeadlineGuideStateStore(modelContext: modelContext)
                performDeadlineLifecycleMutation(
                    workspace: workspace,
                    action: hidden ? .hideDeadline : .unhideDeadline
                ) {
                    try store.setHidden(hidden, entryID: entry.id)
                }
            },
            onConfigureProject: { row in
                workspace.requestProjectConfiguration(projectID: row.projectID)
            },
            onSendToComposer: sendToComposer,
            ignoreTargetMessageID: projectListIgnoreTargetMessageID(workspace: workspace),
            onIgnoreMessage: { id in beginListIgnore(messageID: id) },
            messageActions: frontPageMessageActions
        )
    }

    @MainActor
    private func performProjectsLifecycleMutation(
        workspace: ProjectsWorkspaceState,
        action: ProjectMutationAction,
        _ mutation: () throws -> Void
    ) {
        do {
            try mutation()
            workspace.clearProjectMutationFailure()
            workspace.bumpActionRevision()
            projectsData.invalidateAndRefresh()
        } catch {
            workspace.reportProjectMutationFailure(action: action, error: error)
        }
    }

    @MainActor
    private func performDeadlineLifecycleMutation(
        workspace: ProjectsWorkspaceState,
        action: ProjectMutationAction,
        _ mutation: () throws -> Void
    ) {
        do {
            try mutation()
            workspace.clearProjectMutationFailure()
            workspace.bumpDeadlineDispositionRevision()
        } catch {
            workspace.reportProjectMutationFailure(action: action, error: error)
        }
    }

    @MainActor
    private func projectListIgnoreTargetMessageID(workspace: ProjectsWorkspaceState) -> UUID? {
        let id: UUID
        if workspace.selectedMode.isLinks,
           let expanded = workspace.workroomExpandedMessageID {
            id = expanded
        } else if let readoutID = workspace.messageReadout?.messageID {
            id = readoutID
        } else {
            return nil
        }
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == id })
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first,
              MailingListIgnoreRuleService.isEligibleListMessage(message) else {
            return nil
        }
        return id
    }

    @ViewBuilder
    private var constellationSplitLayout: some View {
        ConstellationSidebarContainer(
            placement: sidebarPlacement,
            isVisible: shouldShowSidebar,
            sidebarWidth: $sidebarWidth,
            minSidebarWidth: Self.minSidebarWidth,
            maxSidebarWidth: Self.maxSidebarWidth,
            onDetailFrameChange: { frame in
                searchDetailFrameInTransitionSpace = frame
            },
            onSidebarWidthCommit: { width in
                noteSidebarWidthUserResize(width)
            }
        ) {
            sidebar(clearsWindowControls: !shouldShowTopBar)
        } detail: {
            withheldSplitLayout
        }
    }

    @ViewBuilder
    private var withheldSplitLayout: some View {
        ConstellationSidebarContainer(
            placement: withheldSidebarPlacement,
            isVisible: shouldShowWithheldSidebar,
            sidebarWidth: $withheldWidth,
            minSidebarWidth: CGFloat(Self.withheldMinWidth),
            maxSidebarWidth: CGFloat(Self.withheldMaxWidth),
            onDetailFrameChange: { frame in
                withheldDetailFrameInTransitionSpace = frame
            },
            onSidebarWidthCommit: { width in
                noteWithheldWidthCommit(width)
            }
        ) {
            withheldDrawerPanel
        } detail: {
            constellationDetailContent
        }
    }

    private var withheldDrawerPanel: some View {
        WithheldDrawerView(
            model: withheldModel,
            onPromote: { row in restoreWithheldRows([row]) },
            actions: WithheldMessageActionHandlers(
                restore: { rows in restoreWithheldRows(rows) },
                setRead: { rows, value in setWithheldRowsRead(rows, value: value) },
                deletePermanently: { rows in deleteWithheldRowsPermanently(rows) }
            ),
            onDragBegan: { armWithheldRestoreDrop() },
            onClose: { withAnimation(Self.sidebarSpring) { setWithheldVisible(false) } },
            allowsEscapeBack: !frontPageFocusedDetailIsActive,
            onLoad: {
                // Live, read-only fetch of Junk/Trash when the drawer opens — never ingested.
                await withheldModel.load(
                    accounts: accounts,
                    oauthStore: OAuthTokenStore(allowKeychainInteraction: false),
                    modelContext: modelContext
                )
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func makeMessageLocalDeletionCascade() -> MessageLocalDeletionCascade {
        MessageLocalDeletionCascade(appServices: services)
    }

    @MainActor
    private func makeMailboxMutationDispatcher(
        jobQueue: JobQueue = JobQueue()
    ) -> MailboxMutationDispatcher {
        let sessionManager = sessionManager
        return MailboxMutationDispatcher(
            context: modelContext,
            jobQueue: jobQueue,
            localDeletionCascade: makeMessageLocalDeletionCascade(),
            providerTrashRestorer: { accountID, messageIDHeader in
                guard let session = sessionManager?.sessionForWork(accountID: accountID) else {
                    throw IMAPError.notConnected
                }
                try await session.restoreMessageFromTrash(
                    messageIDHeader: messageIDHeader
                )
            }
        )
    }

    @MainActor
    private func makeMailingListIgnoreRuleService(
        jobQueue: JobQueue = JobQueue()
    ) -> MailingListIgnoreRuleService {
        MailingListIgnoreRuleService(
            context: modelContext,
            jobQueue: jobQueue,
            localDeletionCascade: makeMessageLocalDeletionCascade()
        )
    }

    @MainActor
    private func restoreWithheldRows(_ rows: [WithheldRow]) {
        Task { @MainActor in
            _ = await restoreWithheldRowsAndWait(rows)
        }
    }

    @MainActor
    private func restoreWithheldRowsAndWait(_ rows: [WithheldRow]) async -> Set<UUID> {
        let uniqueRows = uniqueWithheldRows(rows)
        guard !uniqueRows.isEmpty else { return [] }
        // Promotion writes to the corpus + enqueues the server move. All three
        // collaborators share `modelContext` so the ingester's save commits the
        // orchestrator's insert and the dispatcher sees it (Task 5b contract).
        let orchestrator = IngestionOrchestrator(
            context: modelContext,
            canonicalStore: services.canonicalStore
        )
        let ingester = OrchestratorPromotionIngester(
            orchestrator: orchestrator,
            context: modelContext
        )
        let moveQueue = DispatcherPromotionMoveQueue(
            dispatcher: makeMailboxMutationDispatcher()
        )
        let dispatcher = makeMailboxMutationDispatcher()
        var restoredMessageIDs = Set<UUID>()
        for row in uniqueRows {
            if let localMessageID = row.localMessageID {
                do {
                    switch try await dispatcher.restoreFromTrash(messageID: localMessageID) {
                    case .restoredLocally:
                        withheldModel.removeRows(rowIDs: [row.id])
                        restoredMessageIDs.insert(localMessageID)
                        invalidateSharedMessageAttentionSurfaces()
                        continue
                    case .requiresRemotePromotion:
                        guard WithheldRestoreRoutingPolicy.canAttemptRemotePromotion(row) else {
                            withheldModel.promoteErrors[row.id] =
                                "The provider Trash copy is not available yet. Refresh Junk/Trash and try again."
                            continue
                        }
                    }
                } catch {
                    withheldModel.promoteErrors[row.id] = error.localizedDescription
                    continue
                }
            }
            await withheldModel.promote(row, ingester: ingester, moveQueue: moveQueue)
            if let localMessageID = row.localMessageID,
               isMessageTrashed(localMessageID) == false {
                restoredMessageIDs.insert(localMessageID)
            }
        }
        return restoredMessageIDs
    }

    @MainActor
    private func isMessageTrashed(_ messageID: UUID) -> Bool? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first?.isTrashed
    }

    @MainActor
    private func armWithheldRestoreDrop() {
        let armID = UUID()
        withheldRestoreDropArmID = armID
        withAnimation(.easeInOut(duration: 0.12)) {
            withheldRestoreDropArmed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard withheldRestoreDropArmID == armID else { return }
            disarmWithheldRestoreDrop()
        }
    }

    @MainActor
    private func disarmWithheldRestoreDrop() {
        withAnimation(.easeInOut(duration: 0.12)) {
            withheldRestoreDropTargeted = false
            withheldRestoreDropArmed = false
        }
    }

    @MainActor
    private func restoreWithheldRows(payloads: [WithheldRowDragPayload]) {
        let rowIDs = payloads.flatMap(\.rowIDs)
        restoreWithheldRows(rowIDs: rowIDs)
    }

    @MainActor
    private func restoreWithheldRows(rowIDs: [String]) {
        let rows = withheldModel.rows(matching: rowIDs)
        restoreWithheldRows(rows)
    }

    @MainActor
    private func setWithheldRowsRead(_ rows: [WithheldRow], value: Bool) {
        let uniqueRows = uniqueWithheldRows(rows)
        guard !uniqueRows.isEmpty else { return }
        let dispatcher = makeMailboxMutationDispatcher()
        var changedIDs = Set<String>()
        for row in uniqueRows {
            do {
                if let localMessageID = row.localMessageID,
                   row.folderPath.isEmpty || row.uid == 0 || row.uidValidity == 0 {
                    _ = try dispatcher.setRead(messageID: localMessageID, value: value)
                    changedIDs.insert(row.id)
                } else {
                    let outcome = try dispatcher.setRead(
                        accountID: row.accountID,
                        sourceFolder: row.folderPath,
                        uid: row.uid,
                        uidValidity: row.uidValidity,
                        value: value
                    )
                    if outcome.propagatedToServer {
                        changedIDs.insert(row.id)
                    }
                }
            } catch {
                print("[Constellation] withheld mark read failed: \(String(reflecting: type(of: error)))")
            }
        }
        withheldModel.applyReadState(rowIDs: changedIDs, isRead: value)
    }

    @MainActor
    private func deleteWithheldRowsPermanently(_ rows: [WithheldRow], confirm: Bool = true) {
        let uniqueRows = uniqueWithheldRows(rows)
        guard !uniqueRows.isEmpty else { return }
        if confirm {
            guard confirmDeleteWithheldRowsPermanently(count: uniqueRows.count) else { return }
        }

        let dispatcher = makeMailboxMutationDispatcher()
        var deletedIDs = Set<String>()
        for row in uniqueRows {
            do {
                if let localMessageID = row.localMessageID,
                   row.folderPath.isEmpty || row.uid == 0 || row.uidValidity == 0 {
                    _ = try dispatcher.deletePermanently(messageID: localMessageID)
                    deletedIDs.insert(row.id)
                } else {
                    let outcome = try dispatcher.delete(
                        accountID: row.accountID,
                        sourceFolder: row.folderPath,
                        uid: row.uid,
                        uidValidity: row.uidValidity,
                        rfcMessageIDHeader: row.messageId,
                        retainedMessageID: row.localMessageID
                    )
                    if outcome.propagatedToServer {
                        deletedIDs.insert(row.id)
                    }
                }
            } catch {
                print("[Constellation] withheld permanent delete failed: \(String(reflecting: type(of: error)))")
            }
        }
        withheldModel.removeRows(rowIDs: deletedIDs)
    }

    /// Keyboard-delete target for the Withheld (Junk/Trash) drawer: the open
    /// detail row, else the list multi-selection. Returns false when the
    /// drawer is closed or nothing is selected, so the Delete key can fall
    /// through. `confirm == false` (⌘⌫) deletes without the alert.
    @MainActor
    private func deleteSelectedWithheldRowsIfDrawerActive(confirm: Bool) -> Bool {
        guard shouldShowWithheldSidebar else { return false }
        let rows: [WithheldRow]
        if let selected = withheldModel.selectedRow {
            rows = [selected]
        } else if !withheldModel.selectedRowIDs.isEmpty {
            rows = withheldModel.visibleRows.filter { withheldModel.selectedRowIDs.contains($0.id) }
        } else {
            return false
        }
        guard !rows.isEmpty else { return false }
        deleteWithheldRowsPermanently(rows, confirm: confirm)
        return true
    }

    @MainActor
    private func confirmDeleteWithheldRowsPermanently(count: Int) -> Bool {
        guard DeletionConfirmationPreference.showsPermanentDeleteConfirmation() else {
            return true
        }

        let noun = count == 1 ? "email" : "emails"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Permanently delete \(count) \(noun)?"
        alert.informativeText = "This will remove the selected Junk or Trash \(noun) from the IMAP server. This cannot be undone."
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        if let firstButton = alert.buttons.first {
            // Make the Delete button the default so Return/Enter confirms. We must
            // NOT set hasDestructiveAction here: it deliberately suppresses the
            // Return key equivalent (that is its whole purpose) and NSAlert re-applies
            // that suppression during layout, which is exactly why Return wasn't
            // confirming. Cancel keeps Escape via NSAlert's automatic assignment.
            firstButton.keyEquivalent = "\r"
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func uniqueWithheldRows(_ rows: [WithheldRow]) -> [WithheldRow] {
        var seen = Set<String>()
        var unique: [WithheldRow] = []
        for row in rows where seen.insert(row.id).inserted {
            unique.append(row)
        }
        return unique
    }

    // Top-trailing affordance that opens the drawer; hidden while it's open (the
    // drawer's own close button takes over). Phase C adds a high-signal badge here.
    @MainActor
    private func reportInitialSceneReady() {
        guard !hasReportedInitialSceneReady else { return }
        hasReportedInitialSceneReady = true
        onInitialSceneReady()
    }

    /// Fired the first time the active lens *resolves* its surface — its real
    /// content (`nil` status) or a terminal empty-state (no accounts / no
    /// messages), but NOT while still `.loading`. Drives the shell's night-sky
    /// launch-backdrop retirement, so that backdrop outlives the lens's heavy
    /// first paint and the splash → lens hand-off never exposes flat black.
    /// Keying on "not loading" rather than "content present" matters: an empty
    /// mailbox never reaches a `nil` status, so a `== nil` test would pin the
    /// launch backdrop (and its animation loop) on screen forever. One-shot.
    @MainActor
    private func reportLensSurfaceSettledIfNeeded() {
        guard !hasReportedLensSurfaceSettle else { return }
        if case .loading? = activeLensSurfaceStatus { return }
        hasReportedLensSurfaceSettle = true
        onLensSurfaceDidSettle()
    }

    @MainActor
    private func reportInitialSceneReadyIfReady(_ packet: ConstellationRenderPacket) {
        guard !hasReportedInitialSceneReady else { return }
        if onboardingMode {
            reportInitialSceneReady()
            return
        }
        guard didFrameInitialConstellationCamera || packet.totalVectorCount == 0 else {
            return
        }
        reportInitialSceneReady()
    }

    @MainActor
    private func reportFirstVisibleNodeRenderedIfNeeded(_ stats: ConstellationMetalFrameStats) {
        guard onboardingMode, !hasReportedFirstVisibleNodeRendered else { return }
        guard stats.hitProxyCount > 0 else { return }
        hasReportedFirstVisibleNodeRendered = true
        onFirstVisibleNodeRendered()
    }

    private var shouldShowSidebar: Bool {
        !onboardingMode && sidebarVisible
    }

    private var sidebarPlacement: ConstellationSidebarPlacement {
        sidebarSideRaw == "trailing" ? .trailing : .leading
    }

    /// Withheld stays on the opposite edge from Search/Ask.
    private var shouldShowWithheldSidebar: Bool {
        !onboardingMode && withheldVisible
    }

    private var withheldSidebarPlacement: ConstellationSidebarPlacement {
        sidebarSideRaw == "leading" ? .trailing : .leading
    }

    private func applySidebarDefaultWidthIfNeeded() {
        let clampedWidth = Self.clampedSidebarWidth(CGFloat(sidebarWidth))
        guard !sidebarWidthUserResized else {
            if abs(sidebarWidth - Double(clampedWidth)) > 0.5 {
                sidebarWidth = Double(clampedWidth)
            }
            return
        }

        if abs(clampedWidth - Self.legacyDefaultSidebarWidth) <= 0.5
            || abs(sidebarWidth - Double(clampedWidth)) > 0.5 {
            sidebarWidth = Double(Self.minSidebarWidth)
        } else {
            sidebarWidth = Double(clampedWidth)
        }
    }

    private func noteSidebarWidthUserResize(_ width: CGFloat) {
        sidebarWidthUserResized = true
        let clampedWidth = Self.clampedSidebarWidth(width)
        if abs(sidebarWidth - Double(clampedWidth)) > 0.5 {
            sidebarWidth = Double(clampedWidth)
        }
    }

    private static func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return minSidebarWidth }
        return min(max(width, minSidebarWidth), maxSidebarWidth)
    }

    private func noteWithheldWidthCommit(_ width: CGFloat) {
        let clampedWidth = Self.clampedWithheldWidth(width)
        if abs(withheldWidth - Double(clampedWidth)) > 0.5 {
            withheldWidth = Double(clampedWidth)
        }
    }

    private static func clampedWithheldWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return CGFloat(withheldMinWidth) }
        return min(max(width, CGFloat(withheldMinWidth)), CGFloat(withheldMaxWidth))
    }

    private func setSidebarVisible(_ visible: Bool) {
        if !visible {
            searchDetailFrameInTransitionSpace = .zero
        }
        sidebarVisible = visible
    }

    private func setWithheldVisible(_ visible: Bool) {
        if !visible {
            withheldDetailFrameInTransitionSpace = .zero
        }
        withheldVisible = visible
    }

    @MainActor
    private func persistConstellationViewState(capturingCurrentCamera: Bool = true) {
        guard !onboardingMode else { return }
        let capturedSignature = capturingCurrentCamera
            ? recordCurrentCameraForActiveLens()
            : nil
        ConstellationViewStatePersistence.save(
            state: state,
            customTimeRange: customTimeRange
        )
        if let capturedSignature {
            lastPersistedCameraSignature = capturedSignature
        }
    }

    @MainActor
    @discardableResult
    private func recordCurrentCameraForActiveLens() -> CameraPlanningSignature? {
        guard canStoreCurrentCameraForActiveLens else { return nil }
        return updateStoredCameraState(cameraController.state, for: state.activeFrame)
    }

    @MainActor
    private func persistCurrentCameraForActiveLensIfChanged(signature: CameraPlanningSignature) {
        guard canStoreCurrentCameraForActiveLens else { return }
        let changed = lastPersistedCameraSignature == .unset
            || signature.isMeaningfullyDifferent(from: lastPersistedCameraSignature)
        guard changed else { return }
        let capturedSignature = updateStoredCameraState(cameraController.state, for: state.activeFrame)
        ConstellationViewStatePersistence.save(
            state: state,
            customTimeRange: customTimeRange
        )
        lastPersistedCameraSignature = capturedSignature
    }

    @MainActor
    private var canStoreCurrentCameraForActiveLens: Bool {
        !onboardingMode
            && didFrameInitialConstellationCamera
            && renderPacketFrame.spatialLens == state.activeFrame.spatialLens
            && pendingCameraRestoreFrame == nil
            && framesWithSessionCameraState.contains(state.activeFrame.spatialLens)
            && state.lockedVectorId == nil
            && !warpAnimator.isWarping
    }

    @MainActor
    private func pendingCameraRestoreState(for frame: FrameKey) -> CameraState? {
        let resolvedFrame = frame.spatialLens
        guard pendingCameraRestoreFrame?.spatialLens == resolvedFrame,
              framesWithSessionCameraState.contains(resolvedFrame) else {
            return nil
        }
        return state.cameraState(for: resolvedFrame)
    }

    @MainActor
    private func applyPendingCameraRestoreIfReady(for frame: FrameKey) {
        let resolvedFrame = frame.spatialLens
        guard pendingCameraRestoreFrame?.spatialLens == resolvedFrame else { return }
        let hasStoredCamera = framesWithSessionCameraState.contains(resolvedFrame)
            && state.cameraState(for: resolvedFrame) != nil
        guard Self.shouldApplyPendingCameraRestore(
            activeFrame: state.activeFrame,
            renderPacketFrame: renderPacketFrame,
            pendingFrame: pendingCameraRestoreFrame,
            hasStoredCamera: hasStoredCamera,
            isOnboarding: onboardingMode
        ) else {
            if state.activeFrame.spatialLens == resolvedFrame,
               renderPacketFrame.spatialLens == resolvedFrame {
                pendingCameraRestoreFrame = nil
            }
            return
        }
        pendingCameraRestoreFrame = nil
        restoreCameraForActiveLensIfAvailable(resolvedFrame)
    }

    @MainActor
    private func armFilterCameraResetIfNeeded(filter: VectorFilter? = nil) {
        // A cluster-filter engage/remove drives its own focus-style warp and
        // queues the delayed reset at the mutation site. Let that pending
        // request survive; the warp completion applies it when safe.
        if suppressFilterCameraReset {
            suppressFilterCameraReset = false
            return
        }
        let frame = state.activeFrame.spatialLens
        guard Self.shouldArmFilterCameraReset(
            frame: frame,
            lockedVectorId: state.lockedVectorId,
            isOnboarding: onboardingMode
        ) else {
            return
        }
        pendingFilterCameraReset = filterCameraResetSignature(
            frame: frame,
            filter: filter ?? state.filter
        )
    }

    nonisolated static func shouldDelayPendingFilterCameraResetForMeaningClusterWarp(
        activeWarpSequence: Int?,
        pending: ConstellationFilterCameraResetRequest?
    ) -> Bool {
        activeWarpSequence != nil
            && pending?.frame.spatialLens == .meaning
    }

    @MainActor
    private func filterCameraResetSignature(
        frame: FrameKey,
        filter: VectorFilter
    ) -> ConstellationFilterCameraResetRequest {
        let resolvedFrame = frame.spatialLens
        return ConstellationFilterCameraResetRequest(
            frame: resolvedFrame,
            filter: filter,
            meaningClusterDisplayLimit: resolvedFrame.spatialLens == .meaning
                ? effectiveMeaningClusterDisplayCount
                : nil,
            peopleFocusExpandsToOneHop: resolvedFrame.spatialLens == .people
                ? peopleFocusExpandsToOneHop
                : nil
        )
    }

    @MainActor
    private func applyPendingFilterCameraResetIfReady(for frame: FrameKey) async {
        guard let pendingFilterCameraReset else { return }
        guard !Self.shouldDelayPendingFilterCameraResetForMeaningClusterWarp(
            activeWarpSequence: clusterFilterWarpSequence,
            pending: pendingFilterCameraReset
        ) else {
            return
        }
        let resolvedFrame = frame.spatialLens
        let currentSignature = filterCameraResetSignature(
            frame: state.activeFrame,
            filter: state.filter
        )

        guard Self.shouldApplyPendingFilterCameraReset(
            activeFrame: state.activeFrame,
            renderPacketFrame: renderPacketFrame,
            renderPacketFilter: renderPacketFilter,
            currentFilter: state.filter,
            renderPacketSignature: renderPacketFilterCameraResetSignature,
            currentSignature: currentSignature,
            lockedVectorId: state.lockedVectorId,
            isOnboarding: onboardingMode,
            pending: pendingFilterCameraReset
        ) else {
            if Self.shouldDiscardPendingFilterCameraReset(
                activeFrame: state.activeFrame,
                isOnboarding: onboardingMode,
                pending: pendingFilterCameraReset
            ) {
                self.pendingFilterCameraReset = nil
            }
            return
        }

        if await applyDefaultConstellationCameraIfNeeded(frame: resolvedFrame, reason: .filterChange) {
            self.pendingFilterCameraReset = nil
        }
    }

    @MainActor
    private func restoreCameraForActiveLensIfAvailable(_ frame: FrameKey) {
        let resolvedFrame = frame.spatialLens
        guard !onboardingMode,
              framesWithSessionCameraState.contains(resolvedFrame),
              let cameraState = state.cameraState(for: resolvedFrame) else {
            return
        }
        warpAnimator.onComplete = nil
        warpAnimator.onProgress = nil
        cameraController.snap(to: cameraState)
        let signature = CameraPlanningSignature(cameraState)
        lastPlannedCameraSignature = signature
        lastPersistedCameraSignature = signature
    }

    @MainActor
    private func recordCameraState(
        _ cameraState: CameraState,
        for frame: FrameKey,
        persist: Bool
    ) {
        let signature = updateStoredCameraState(cameraState, for: frame)
        guard persist else { return }
        ConstellationViewStatePersistence.save(
            state: state,
            customTimeRange: customTimeRange
        )
        if state.activeFrame.spatialLens == frame.spatialLens {
            lastPersistedCameraSignature = signature
        }
    }

    @MainActor
    @discardableResult
    private func updateStoredCameraState(
        _ cameraState: CameraState,
        for frame: FrameKey
    ) -> CameraPlanningSignature {
        let settled = Self.settledCameraState(cameraState)
        state.setCameraState(settled, for: frame)
        return CameraPlanningSignature(settled)
    }

    private static func settledCameraState(_ cameraState: CameraState) -> CameraState {
        CameraState(
            position: cameraState.position,
            velocity: .zero,
            yaw: cameraState.yaw,
            pitch: cameraState.pitch,
            yawRate: 0,
            pitchRate: 0,
            roll: cameraState.roll,
            rollRate: 0
        )
    }

    private func sidebar(clearsWindowControls: Bool) -> some View {
        ConstellationSidebar(
            tabRaw: $sidebarTabRaw,
            clearsWindowControls: clearsWindowControls,
            searchQuery: $state.searchQuery,
            searchModel: searchModel(),
            searchMatchIndex: searchMatchIndex,
            onSearchSubmit: { performLexicalSearch() },
            onSelectSearchLane: { lane in selectSearchLane(lane) },
            onSelectMatch: { rawIndex in selectSearchMatch(rawIndex) },
            onWarpMatch: { rawIndex in requestSearchMatchWarp(rawIndex) },
            qaVM: qaVM,
            activeFilter: { await activeFilterSpec() },
            threadContextProvider: { sources in
                await askThreadExpansion(for: sources)
            },
            sourceLookup: { vid in citationSourceRecord(vectorId: vid) },
            onCitationHover: { id in handleCitationHover(id) },
            onCitationClick: { vid in handleAskCitationClick(vectorId: vid) },
            onClose: {
                withAnimation(Self.sidebarSpring) { setSidebarVisible(false) }
            }
        )
    }

    @ViewBuilder
    private func timelineScene() -> some View {
        // `timelineWorkspace` is initialized eagerly in `selectFrame(.timeline)`
        // and in the persisted-state restoration path; we never write to
        // `@State` from inside this view builder. The conditional handles
        // the initial-mount race when persistence restored `activeFrame =
        // .timeline` before `selectFrame` ran: the `.task` block below
        // initializes the workspace off the next runloop turn.
        if let workspace = timelineWorkspace {
            TimelineWorkspaceView(
                constellationState: state,
                workspace: workspace,
                dataController: timelineData,
                modelContext: modelContext,
                vectorStore: services.vectorStore,
                newStarNavigator: newStarNavigator,
                manualRefresh: manualRefresh,
                onStarburstClick: handleStarburstClick,
                onBeaconMenuCommand: handleBeaconMenuCommand,
                onPresentMessageMenu: { [weak workspace = workspace] messageID, point, view in
                    presentMessageContextMenu(
                        messageID: messageID,
                        vectorIdForOverlayRelease: nil,
                        includeCopyAction: true,
                        onAfterMessageMutation: {
                            timelineData.invalidateAndRefreshIfBound()
                        },
                        onAfterDelete: {
                            // The right-click delete path deletes directly (not via
                            // `frontPageDeleteMessages`), so fire the red Collapse
                            // gesture here. Hold the playhead + snapshot on the
                            // departing message for the gesture window so the
                            // Collapse plays, then advance to the next message and
                            // rebuild.
                            let deleteStart = Date()
                            let coordinator = activeDepartingGestureCoordinator
                            coordinator?.begin(.delete, for: [messageID], now: deleteStart)
                            scheduleActiveLensDepartingSettle([messageID], startedAt: deleteStart)
                            let advanceDelay = Self.departingHold(
                                for: [messageID], on: coordinator, tail: Self.departingAdvanceTail
                            )
                            Task { @MainActor [weak workspace] in
                                try? await Task.sleep(for: .seconds(advanceDelay))
                                workspace?.advancePlayheadAfterDeletion(of: messageID)
                                timelineData.invalidateAndRefreshIfBound()
                            }
                        },
                        at: point,
                        in: view
                    )
                },
                actions: timelineMessageActions(workspace: workspace),
                customCategoryCatalog: customCategoryStore.descriptors,
                showsControlColumn: false
            )
            .overlay {
                SearchMatchKeyboardCatcher(
                    onKeyDown: { keyCode, modifiers in
                        handleSearchMatchNavigationKey(keyCode: keyCode, modifiers: modifiers)
                    }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .onChange(of: TimelineSnapshotObservationKey(snapshot: workspace.currentSnapshot)) { _, _ in
                completePendingTimelineNewStarNavigation()
                completePendingTimelineAskCitationNavigation()
                completePendingNotificationFocusNavigation()
            }
            .task(id: pendingTimelineNewStar) { @MainActor in
                retryPendingTimelineNewStarNavigationIfNeeded()
            }
        } else {
            Color.clear
                .task {
                    if timelineWorkspace == nil {
                        let now = Date()
                        let range = state.selectedTimeRange.range(relativeTo: now)
                            ?? (now.addingTimeInterval(-30 * 24 * 60 * 60) ... now)
                        timelineWorkspace = TimelineWorkspaceState(viewportRange: range)
                    }
                }
        }
    }

    @MainActor
    private func requestTimelineRefreshForCurrentStateIfActive() {
        guard state.activeFrame.spatialLens == .timeline,
              let workspace = timelineWorkspace else { return }
        // Self-heal the controller's binding (see `ensureBound`) so a Moments
        // change still re-renders even if a transient `onDisappear` detached
        // the shared controller.
        timelineData.ensureBound(
            workspace: workspace,
            modelContext: modelContext,
            vectorStore: services.vectorStore
        )
        timelineData.requestRefresh(
            viewportRange: workspace.viewportRange,
            pixelsPerDay: workspace.viewportPixelsPerDay,
            bracketedRange: workspace.bracketedRange,
            filter: state.filter,
            selectedTimeRange: state.selectedTimeRange,
            searchTokens: []
        )
    }

    @MainActor
    private func requestFrontPageRefreshForCurrentStateIfActive() {
        guard state.activeFrame.spatialLens == .frontPage,
              let workspace = frontPageWorkspace else { return }
        frontPageData.ensureBound(
            workspace: workspace,
            modelContext: modelContext,
            vectorStore: services.vectorStore
        )
        frontPageData.requestRefresh(
            filter: state.filter,
            selectedTimeRange: state.selectedTimeRange
        )
    }

    @ViewBuilder
    private func frontPageScene() -> some View {
        if let workspace = frontPageWorkspace {
            FrontPageWorkspaceView(
                constellationState: state,
                workspace: workspace,
                dataController: frontPageData,
                modelContext: modelContext,
                vectorStore: services.vectorStore,
                newStarNavigator: newStarNavigator,
                manualRefresh: manualRefresh,
                summaryByMessageId: summaryByMessageId,
                summaryUnavailableMessageIds: summaryUnavailableMessageIds,
                regeneratingSummaryMessageIds: regeneratingSummaryMessageIds,
                onStarburstClick: handleStarburstClick,
                onBeaconMenuCommand: handleBeaconMenuCommand,
                onMessagesPresented: noteFrontPageMessagesPresented,
                onRequestSummary: { messageId, scope in
                    Task {
                        await resolveOnDemandSummary(
                            forMessageId: messageId,
                            rowOverride: frontPageWorkspace?.currentSnapshot?.messageFilterRows[messageId],
                            scope: scope
                        )
                    }
                },
                actions: frontPageMessageActions,
                customCategoryCatalog: customCategoryStore.descriptors,
                showsControlColumn: false
            )
            .onChange(of: FrontPageSnapshotObservationKey(snapshot: workspace.currentSnapshot)) { _, _ in
                syncNewStarNavigatorWithCurrentMessageIndex()
                completePendingFrontPageNewStarNavigation()
                completePendingFrontPageAskCitationNavigation()
                completePendingNotificationFocusNavigation()
                noteFrontPageSnapshotInstalled(workspace.currentSnapshot)
            }
            // Front Page is a reading surface, so search navigation resolves
            // to the matching story's in-place reader instead of a Metal
            // camera warp. The shared catcher keeps Tab / Shift+Tab and
            // Command-Return wired while the non-Metal lens is active.
            .overlay {
                SearchMatchKeyboardCatcher(
                    onKeyDown: { keyCode, modifiers in
                        handleSearchMatchNavigationKey(keyCode: keyCode, modifiers: modifiers)
                    }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        } else {
            Color.clear
                .task {
                    if frontPageWorkspace == nil {
                        frontPageWorkspace = FrontPageWorkspaceState()
                    }
                    requestFrontPageRefreshForCurrentStateIfActive()
                }
        }
    }

    @ViewBuilder
    private func projectsScene() -> some View {
        if let workspace = projectsWorkspace {
            ProjectsWorkspaceView(
                constellationState: state,
                workspace: workspace,
                dataController: projectsData,
                modelContext: modelContext,
                vectorStore: services.vectorStore,
                tagRecommendationClient: .live {
                    guard await services.prepareBGE3ForInteractiveRetrievalIfAvailable() else {
                        return nil
                    }
                    return services.embedder
                },
                newStarNavigator: newStarNavigator,
                manualRefresh: manualRefresh,
                summaryByMessageId: summaryByMessageId,
                summaryUnavailableReasonByMessageId: summaryUnavailableReasonByMessageId,
                summaryUnavailableMessageIds: summaryUnavailableMessageIds,
                regeneratingSummaryMessageIds: regeneratingSummaryMessageIds,
                projectSummaryService: services.projectSummaryService,
                projectSummaryUserIdentity: projectsSummaryUserIdentity,
                deadlineSummaryService: services.deadlineSummaryService,
                attachmentSummaryService: services.attachmentSummaryService,
                jobCompletionBroadcaster: services.jobCompletionBroadcaster,
                onStarburstClick: handleStarburstClick,
                onBeaconMenuCommand: handleBeaconMenuCommand,
                onPresentMessageMenu: { messageID, projectKey, point, view in
                    presentProjectsMessageContextMenu(
                        messageID: messageID,
                        projectKey: projectKey,
                        at: point,
                        in: view
                    )
                },
                onPresentRowMenu: { row, point, view in
                    presentProjectsRowContextMenu(row: row, at: point, in: view)
                },
                onSendToComposer: { ids in
                    frontPageSendToComposer(ids, openComposer: ComposerOpenOnQueuePreference.opensComposer(optionHeld: NSEvent.modifierFlags.contains(.option)))
                },
                onIgnoreMessage: { id in
                    beginListIgnore(messageID: id)
                },
                messageActions: projectsMessageActions(workspace: workspace),
                showsControlColumn: false,
                composerDispatch: composerDispatch
            )
            .onChange(of: ProjectsSnapshotObservationKey(
                snapshot: workspace.currentSnapshot,
                hasRefreshInFlight: projectsData.hasRefreshInFlight
            )) { _, _ in
                syncNewStarNavigatorWithCurrentMessageIndex()
                completePendingProjectsNewStarNavigation()
                completePendingProjectsAskCitationNavigation()
                completePendingNotificationFocusNavigation()
                reconcileProjectsStatusGestures(workspace: workspace)
            }
            .overlay {
                SearchMatchKeyboardCatcher(
                    onKeyDown: { keyCode, modifiers in
                        handleSearchMatchNavigationKey(keyCode: keyCode, modifiers: modifiers)
                    }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        } else {
            Color.clear
                .task {
                    if projectsWorkspace == nil {
                        projectsWorkspace = ProjectsWorkspaceState()
                    }
                }
        }
    }

    @ViewBuilder
    private func explorerScene(
        sourceWarpDrive: ConstellationSourceWarpDrive? = nil
    ) -> some View {
        ZStack {
            // Night-sky backdrop behind the transparent Metal view, so the
            // empty space between nodes in the People / Meanings lenses reads
            // as a deep starfield rather than flat black. Parallax-free — it
            // does not track the camera, so it reads as very distant stars —
            // and it is the same deterministic field the splash + loading
            // bridge draw, so entering the scene shows no seam. Plain
            // starfield (no Milky Way band) keeps it from competing with the
            // foreground nodes. Only the Metal lenses route through
            // `explorerScene`; Timeline / Projects / Front Page render their
            // own workspaces, so they are unaffected.
            NightSkyView(showsMilkyWay: false, twinkles: false)
                .ignoresSafeArea()

            NightSkyNebulaOverlay()
                .ignoresSafeArea()
                .opacity(showsMetalFocusNebula ? 1 : 0)
                .animation(.easeInOut(duration: 1.5), value: showsMetalFocusNebula)

            ConstellationMetalView(
                renderer: metalRenderer,
                packet: renderPacket,
                cameraController: cameraController,
                flightInput: flightInput,
                warpAnimator: warpAnimator,
                sourceWarpDrive: sourceWarpDrive,
                peopleContextDimAnimating: peopleContextDimRampActive,
                orbitalMotion: peopleOrbitalMotion,
                peopleLockActive: state.lockedVectorId != nil
                    || liveLockPersonFocus != nil
                    || pendingFocusClick != nil,
                showsPeopleOrbitPaths: !hidesPeopleOrbitPaths,
                lowPowerModeEnabled: lowPowerModeEnabled,
                onHover: { proxy, point in
                    guard pendingFocusClick == nil else { return }
                    if proxy == nil, case .searchMatch = projectedHoverTarget {
                        return
                    }
                    projectedHoverTarget = nil
                    // The sun (the user) — aggregate correspondence readout.
                    if let proxy, proxy.messageId == PersonSunInstance.hitProxyMessageId {
                        state.hoveredVectorId = nil
                        hoveredPersonEmail = nil
                        setHoveredMeaningCluster(nil)
                        hoveredSunReadout = true
                        metalRenderer.setHoveredOrbitPathHub(email: nil)
                        hoverNodePoint = point
                        hoverPosition = Self.placeHoverPopup(
                            nodePoint: point,
                            viewSize: viewSize
                        )
                        return
                    }
                    if let proxy, let hub = personHub(for: proxy) {
                        state.hoveredVectorId = nil
                        hoveredPersonEmail = hub.email
                        setHoveredMeaningCluster(nil)
                        hoveredSunReadout = false
                        // Brighten this planet's engraved orbit path so the
                        // reciprocity shape reads while the system is held.
                        metalRenderer.setHoveredOrbitPathHub(email: hub.email)
                        hoverNodePoint = point
                        hoverPosition = Self.placeHoverPopup(
                            nodePoint: point,
                            viewSize: viewSize
                        )
                        return
                    }
                    if let proxy, let hub = meaningClusterHub(for: proxy) {
                        showMeaningClusterHover(hub, at: point, anchorWorld: proxy.worldPosition)
                        return
                    }
                    hoveredPersonEmail = nil
                    setHoveredMeaningCluster(nil)
                    hoveredSunReadout = false
                    metalRenderer.setHoveredOrbitPathHub(email: nil)
                    guard shouldShowEmailHoverPaneInCurrentLens else {
                        state.hoveredVectorId = nil
                        return
                    }
                    state.hoveredVectorId = proxy?.vectorId
                    if proxy != nil {
                        // Anchor for the yellow horizontal leader line.
                        hoverNodePoint = point
                        // Place the popup beside the node so the node stays
                        // visible and the header's direction-label row lines
                        // up with the node's y — the leader becomes a
                        // horizontal tether from node to pill.
                        hoverPosition = Self.placeHoverPopupAdjacent(
                            nodePoint: point,
                            viewSize: viewSize,
                            popupSize: emailHoverEnvelope
                        ).center
                    }
                },
                onClick: { proxy, point in
                    guard !onboardingMode else { return }
                    // During a People correspondent lock, route clicks through
                    // the ring-node selection model instead of drilling in. The
                    // Metal view has already taken keyboard focus on its own
                    // mouseDown, so Tab / Esc keep reaching the lock key handler.
                    //   • ring satellite (a message node) → select it (highlight
                    //     + pinned card + action column)
                    //   • another correspondent's hub → switch the lock
                    //   • empty space (or the focused hub) → deselect
                    if liveLockPersonFocus != nil {
                        // Only the focused correspondent's own ring satellites are
                        // selectable during the lock. Gating on
                        // `selectableRingMessageIds` (the exact same ring set the
                        // overlay materializes annotations for) — rather than the
                        // full `currentMessageIndex` scene index — keeps the host's
                        // selection in lock-step with the overlay, whose highlight /
                        // pinned card / chip-sync resolve through `selectedRingItem`
                        // (focused ring + `personRingTier`). A click on a dimmed
                        // off-ring node (another correspondent's satellite) would
                        // otherwise set a selection the overlay can't render or
                        // rank-sync, leaving an action column with no highlight and
                        // a desynced chip strip; such clicks fall through to
                        // deselect instead.
                        if let proxy,
                           personHub(for: proxy) == nil,
                           meaningClusterHub(for: proxy) == nil,
                           selectableRingMessageIds.contains(proxy.messageId),
                           currentMessageIndex[proxy.messageId] != nil {
                            // Require both the focused-ring set (for the highlight
                            // + chip sync, which resolve through the ranked ring
                            // annotations) AND the scene index (for the action
                            // column's status target) so all four — highlight,
                            // pinned card, action column, chip — stay consistent;
                            // a node missing from either is left unselected rather
                            // than showing a half-state.
                            //
                            // Selecting is a lightweight focus, not an "open" — do
                            // NOT mark it visited (that triggers a scene refresh /
                            // context reload that resets the rank cursor and
                            // clobbers the chip-strip sync).
                            lockedRingSelectionMessageId = proxy.messageId
                            return
                        }
                        if let proxy, let hub = personHub(for: proxy) {
                            lockedRingSelectionMessageId = nil
                            selectPersonHub(hub, screenPoint: point)
                            return
                        }
                        lockedRingSelectionMessageId = nil
                        return
                    }
                    guard let proxy else { return }
                    // The sun is home: clicking it reframes the whole solar
                    // system through the sanctioned user-reset camera path.
                    if proxy.messageId == PersonSunInstance.hitProxyMessageId {
                        recenterCamera()
                        return
                    }
                    let personHub = personHub(for: proxy)
                    let meaningHub = meaningClusterHub(for: proxy)
                    let hitKind = ConstellationClickRoutingPolicy.hitKind(
                        isPersonHub: personHub != nil,
                        isMeaningClusterHub: meaningHub != nil
                    )
                    switch ConstellationClickRoutingPolicy.route(
                        activeFrame: state.activeFrame,
                        renderPacketFrame: renderPacketFrame,
                        hitKind: hitKind
                    ) {
                    case .personHubLock:
                        guard let hub = personHub else { return }
                        selectPersonHub(hub, screenPoint: point)
                    case .meaningClusterFilter:
                        guard let hub = meaningHub else { return }
                        toggleMeaningClusterFilter(clusterId: hub.clusterId)
                    case .messageLock:
                        selectNodeForDetailFocus(proxy, screenPoint: point)
                        markNewStarVisited(messageId: proxy.messageId)
                    case .ignore:
                        return
                    }
                },
                onRightClick: { proxy, point, view in
                    guard !onboardingMode else { return }
                    // Right-clicking a Meaning-lens cluster hub opens a small
                    // cluster-filter menu instead of the message-node menu.
                    // Cluster proxies carry a synthetic `meaningCluster:<id>`
                    // id that is not a UUID, so this must precede the UUID gate.
                    if state.activeFrame.spatialLens == .meaning,
                       let proxy,
                       let hub = meaningClusterHub(for: proxy) {
                        presentMeaningClusterContextMenu(
                            clusterId: hub.clusterId,
                            at: point,
                            in: view
                        )
                        return
                    }
                    guard let proxy,
                          let uuid = UUID(uuidString: proxy.messageId) else { return }
                    // During a People correspondent lock, right-clicking one of the
                    // focused correspondent's own ring satellites selects it and
                    // shows the message action menu (full reply/confirm/resolve
                    // parity), matching the disc column. Gating on
                    // `selectableRingMessageIds` mirrors the left-click path so the
                    // selection the menu acts on is always one the overlay can
                    // highlight and rank-sync. The hub — and any dimmed off-ring
                    // node — falls through to the standard node menu.
                    if liveLockPersonFocus != nil,
                       personHub(for: proxy) == nil,
                       meaningClusterHub(for: proxy) == nil,
                       selectableRingMessageIds.contains(proxy.messageId) {
                        lockedRingSelectionMessageId = proxy.messageId
                        presentFrontPageMessageContextMenu(messageID: uuid, at: point, in: view)
                        return
                    }
                    presentNodeContextMenu(
                        proxy: proxy,
                        messageID: uuid,
                        at: point,
                        in: view
                    )
                },
                onApertureDelta: { delta in
                    let now = Date.now
                    if apertureReadoutTimer.map({ now.timeIntervalSince($0) >= 0.05 }) ?? true {
                        apertureReadoutTimer = now
                    }
                    let next = max(0.0, min(1.0, state.aperture + Double(delta)))
                    guard next != state.aperture else { return }
                    state.aperture = next
                    aperturePref = next
                },
                onKeyDown: { keyCode, modifiers in
                    if state.lockedVectorId != nil {
                        switch keyCode {
                        case 0x30:  // Tab
                            // Bare Tab / Shift+Tab walks the default bucketed
                            // order (Meanings flow: affinity rank; People
                            // focus: Sent → Sent·Included → Received → Included with
                            // newest-first within each bucket).
                            //
                            // Option+Tab / Option+Shift+Tab forces the
                            // People-focus overlay into a strictly
                            // chronological walk across the entire
                            // correspondent ring — oldest → newest with
                            // Option+Tab, newest → oldest with
                            // Option+Shift+Tab. The overlay maps the
                            // chronological destination back into the
                            // bucketed rank space so the chip strip and
                            // popup machinery keep using a single index
                            // domain.
                            let direction = modifiers.contains(.shift) ? -1 : 1
                            if modifiers.contains(.option) {
                                lockNeighbourRank.requestChronologicalStep(direction: direction)
                            } else {
                                lockNeighbourRank.step(by: direction)
                            }
                            return true
                        case 49:    // Space
                            let mode: AnnotationExpandedContentMode = modifiers.contains(.shift) ? .message : .summary
                            return lockNeighbourRank.requestExpansionToggle(mode: mode)
                        case 53:    // Esc
                            // Esc always releases the lock and returns to the
                            // People constellation. Ring-node deselection is
                            // handled separately (empty-click / mouse-leave), so
                            // Esc never has to be pressed twice to exit.
                            lockNeighbourRank.exit()
                            leaveSelectedNodeFocus()
                            return true
                        default:
                            return false
                        }
                    }
                    // Unlocked Esc in the Meaning lens clears an engaged cluster
                    // filter (restoring the slider) — the chip is only visible
                    // in this unlocked state, so this never competes with the
                    // locked-node Esc above.
                    if keyCode == 53,  // Esc
                       state.activeFrame.spatialLens == .meaning,
                       state.filter.clusterIds != nil {
                        clearMeaningClusterFilter()
                        return true
                    }
                    return handleSearchMatchNavigationKey(keyCode: keyCode, modifiers: modifiers)
                },
                onCameraProjectionChange: {
                    lockedOverlayProjectionDriver.update(camera: cameraController.state)
                    if let target = projectedHoverTarget {
                        refreshProjectedHoverAnchor(target)
                    }
                },
                onViewSizeChange: { newSize in
                    viewSize = newSize
                    retainedMetalSurfaces.removeAll()
                    if let target = projectedHoverTarget {
                        refreshProjectedHoverAnchor(target)
                    }
                    Task { await refreshSceneData() }
                },
                onPacketDrawn: { stats in
                    completeColdFirstPaintAfterFirstDrawIfNeeded(stats: stats)
                    noteCurrentMetalPacketDrawn()
                },
                onFrameStats: { stats in
                    renderStats = stats
                    reportFirstVisibleNodeRenderedIfNeeded(stats)
                    let adaptiveBudgetChanged = adaptiveRenderBudget.observe(stats)
                    if adaptiveBudgetChanged {
                        Task { await refreshSceneData() }
                    }
                },
                acceptsWithheldDrop: shouldShowWithheldRestoreDropReceiver,
                onWithheldDropTargeted: { targeted in
                    withheldRestoreDropTargeted = targeted
                },
                onWithheldRowsDrop: { rowIDs in
                    restoreWithheldRows(rowIDs: rowIDs)
                },
                onWithheldDropEnded: {
                    disarmWithheldRestoreDrop()
                },
                inputEnabled: !onboardingMode,
                transparentBackground: true
            )
            .ignoresSafeArea()

            SearchMatchKeyboardCatcher(
                onKeyDown: { keyCode, modifiers in
                    handleSearchMatchNavigationKey(keyCode: keyCode, modifiers: modifiers)
                }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)

            arcLabelOverlay
            dyingPersonWormholeOverlay
            apertureReadoutOverlay
            focusSourcePreviewOverlay(opacity: 1, scale: 1, coordinates: .detail)
            focusClickPendingOverlay
            personHubHoverOverlay
            sunHoverOverlay
            meaningClusterHoverOverlay
            hoverReadoutOverlay
            pendingLockSelectionOverlay
            lockedNodeOverlayLayer
            sceneRenderProgressOverlay
            debugOverlay
        }
    }

    /// People and Meaning focus keep the live Metal scene mounted and
    /// transparent. Layer the same cool nebula wash used by an expanded Front
    /// Page thread behind that scene while either lens has an active lock;
    /// every other lens keeps the plain starfield.
    private var showsMetalFocusNebula: Bool {
        let lens = state.activeFrame.spatialLens
        return (lens == .people || lens == .meaning) && state.lockedVectorId != nil
    }

    private func captureFocusedTransitionSourceSnapshot() -> FocusTransitionSourceSnapshot {
        FocusTransitionSourceSnapshot(
            packet: renderPacket,
            camera: cameraController.state,
            renderedFrame: renderPacketFrame.spatialLens,
            renderedFilter: renderPacketFilter
        )
    }

    @MainActor
    private func beginLiveMetalFocusWarp(
        frame: FrameKey,
        vectorId: Int64,
        messageId: String,
        duration: TimeInterval,
        directionSign: Float = 1,
        fieldDimTarget: Float? = nil
    ) {
        let resolvedFrame = frame.spatialLens
        guard LiveMetalFocusTransitionPolicy.usesSourceWarp(
            activeFrame: resolvedFrame,
            effectFrame: resolvedFrame
        ), duration > 0 else {
            clearLiveMetalFocusWarp()
            return
        }

        liveMetalFocusWarpSequence += 1
        let sequence = liveMetalFocusWarpSequence
        liveMetalFocusWarpEffect = LiveMetalFocusWarpEffect(
            id: sequence,
            frame: resolvedFrame,
            vectorId: vectorId,
            messageId: messageId,
            startedAt: Date.now,
            duration: duration,
            directionSign: directionSign,
            fieldDimTarget: fieldDimTarget,
            awaitsFocusedPacket: false
        )

        Task { @MainActor in
            do {
                try await Task.sleep(
                    for: .seconds(
                        LiveMetalFocusTransitionPolicy.sourceWarpSafetyTimeout(
                            rampDuration: duration
                        )
                    )
                )
            } catch {
                return
            }
            guard liveMetalFocusWarpEffect?.id == sequence else { return }
            liveMetalFocusWarpEffect = nil
        }
    }

    @MainActor
    private func clearLiveMetalFocusWarp() {
        guard liveMetalFocusWarpEffect != nil else { return }
        liveMetalFocusWarpSequence += 1
        liveMetalFocusWarpEffect = nil
    }

    @MainActor
    private func armLiveMetalFocusWarpForFocusedPacket(
        frame: FrameKey,
        vectorId: Int64
    ) {
        guard var effect = liveMetalFocusWarpEffect,
              effect.vectorId == vectorId,
              LiveMetalFocusTransitionPolicy.usesSourceWarp(
                activeFrame: frame,
                effectFrame: effect.frame
              ) else {
            return
        }
        effect.awaitsFocusedPacket = true
        liveMetalFocusWarpEffect = effect
    }

    @MainActor
    private func completeLiveFocusRevealIfFocusedPacketInstalled(
        frame: FrameKey,
        packet: ConstellationRenderPacket
    ) {
        guard let gate = pendingLiveFocusReveal,
              frame.spatialLens == state.activeFrame.spatialLens,
              liveLockPersonFocus == nil,
              lockRevealSequence == gate.sequence,
              state.lockedVectorId == gate.vectorId,
              LiveMetalFocusTransitionPolicy.packetContainsFocusedLock(
                packet,
                vectorId: gate.vectorId,
                messageId: gate.messageId
              ) else {
            return
        }

        if let effect = liveMetalFocusWarpEffect,
           effect.awaitsFocusedPacket,
           effect.vectorId == gate.vectorId,
           LiveMetalFocusTransitionPolicy.usesSourceWarp(
            activeFrame: frame,
            effectFrame: effect.frame
           ) {
            clearLiveMetalFocusWarp()
        }
        // People email-node locks recede the background correspondents with
        // the same short post-install ramp the correspondent portrait uses —
        // hub bodies dim, context bands and background ring satellites fade,
        // while the anchor's own correspondent system stays fully lit.
        if frame.spatialLens == .people {
            startPeopleContextDimRamp(
                vectorId: gate.vectorId,
                revealSequence: gate.sequence,
                duration: PeopleLiveFocusTransitionPolicy.emailLockDimRampDuration
            )
        }
        revealPendingLiveFocus(gate: gate)
    }

    @MainActor
    private func refreshLiveFocusAnchorIfAvailable(
        frame: FrameKey,
        packet: ConstellationRenderPacket
    ) {
        guard LiveFocusAnchorPolicy.shouldRefreshFocusedAnchor(
            activeFrame: frame,
            lockedVectorId: state.lockedVectorId,
            revealedLockedVectorId: revealedLockedVectorId,
            pendingRevealVectorId: pendingLiveFocusReveal?.vectorId,
            hasLivePersonFocus: liveLockPersonFocus != nil,
            exitInFlight: liveFocusExitInFlight
        ),
        let lockedVectorId = state.lockedVectorId else {
            return
        }
        let messageId = pendingLiveFocusReveal?.messageId
            ?? (visibleRecordCache[lockedVectorId] ?? citationSourceRecord(vectorId: lockedVectorId))?.messageId
        guard let focusedWorld = LiveMetalFocusTransitionPolicy.focusedLockWorldPosition(
            packet,
            vectorId: lockedVectorId,
            messageId: messageId
        ) else {
            return
        }
        selectedNodeFocusWorld = focusedWorld
    }

    @MainActor
    private func revealPendingLiveFocus(gate: LiveFocusRevealGate) {
        guard pendingLiveFocusReveal?.sequence == gate.sequence,
              pendingLiveFocusReveal?.vectorId == gate.vectorId,
              lockRevealSequence == gate.sequence,
              state.lockedVectorId == gate.vectorId else {
            return
        }

        pendingLiveFocusReveal = nil
        revealLockedOverlay(vectorId: gate.vectorId, sequence: gate.sequence)
        Task { @MainActor in
            guard state.lockedVectorId == gate.vectorId,
                  lockRevealSequence == gate.sequence else { return }
            await markLockEntryEnrichmentReadyAfterSettle(
                vectorId: gate.vectorId,
                sequence: gate.sequence
            )
        }
    }

    @MainActor
    private func completePeopleLiveFocusRevealIfFocusedPacketInstalled(
        frame: FrameKey,
        packet: ConstellationRenderPacket
    ) {
        guard let gate = pendingPeopleLiveFocusReveal,
              frame.spatialLens == .people,
              lockRevealSequence == gate.sequence,
              state.lockedVectorId == gate.vectorId,
              PeopleLiveFocusTransitionPolicy.packetContainsFocusedCorrespondent(
                packet,
                email: gate.email
              ) else {
            return
        }

        pendingPeopleLiveFocusReveal = nil
        revealLockedOverlay(vectorId: gate.vectorId, sequence: gate.sequence)
        startPeopleContextDimRamp(
            vectorId: gate.vectorId,
            revealSequence: gate.sequence,
            duration: gate.dimRampDuration
        )
        Task { @MainActor in
            guard state.lockedVectorId == gate.vectorId,
                  lockRevealSequence == gate.sequence else { return }
            await markLockEntryEnrichmentReadyAfterSettle(
                vectorId: gate.vectorId,
                sequence: gate.sequence
            )
        }
    }

    @MainActor
    private func startPeopleContextDimRamp(
        vectorId: Int64,
        revealSequence: Int,
        duration: TimeInterval
    ) {
        peopleContextDimRampSequence &+= 1
        let rampSequence = peopleContextDimRampSequence
        peopleContextDimRampActive = true
        metalRenderer.setPeopleContextDimPhase(0)

        Task { @MainActor in
            let startedAt = Date.now
            while true {
                guard peopleContextDimRampSequence == rampSequence else { return }
                guard state.activeFrame.spatialLens == .people,
                      state.lockedVectorId == vectorId,
                      lockRevealSequence == revealSequence else {
                    peopleContextDimRampActive = false
                    metalRenderer.setPeopleContextDimPhase(1)
                    return
                }

                let elapsed = Date.now.timeIntervalSince(startedAt)
                let progress = Float(min(1, max(0, elapsed / max(duration, 0.001))))
                metalRenderer.setPeopleContextDimPhase(
                    PeopleLiveFocusTransitionPolicy.backgroundContextDimPhase(rampProgress: progress)
                )

                guard progress < 1 else {
                    peopleContextDimRampActive = false
                    metalRenderer.setPeopleContextDimPhase(1)
                    return
                }

                do {
                    try await Task.sleep(for: OhiaAnimationCadence.frameDuration)
                } catch {
                    return
                }
            }
        }
    }

    @MainActor
    private func cancelPeopleContextDimRamp(resetPhase: Float = 1, ringVisibility: Float? = nil) {
        peopleContextDimRampSequence &+= 1
        peopleContextDimRampActive = false
        metalRenderer.setPeopleContextDimPhase(resetPhase, ringVisibility: ringVisibility)
    }

    @MainActor
    /// Legacy floating cluster labels for Metal arc annotations. Current
    /// live lenses, including Projects, leave `renderPacket.arcLabels`
    /// empty. If a compatibility packet includes labels, project them via
    /// the same `ScreenProjection.project(...)` helper the locked overlay
    /// uses.
    @ViewBuilder
    private var arcLabelOverlay: some View {
        if !renderPacket.arcLabels.isEmpty {
            ZStack(alignment: .topLeading) {
                // `ForEach` keyed by `ArcLabelOverlay.id` (cluster id +
                // case-folded label). When the planner re-emits the same
                // arc label at a slightly different cluster centroid across
                // packets, SwiftUI moves the existing view rather than
                // crossfading two indistinct array slots, while duplicate
                // labels in separate clusters stay distinct.
                ForEach(renderPacket.arcLabels) { label in
                    if let position = ScreenProjection.project(
                        world: label.position,
                        camera: cameraController.state,
                        viewSize: viewSize,
                        fovYRadians: .pi / 3
                    ) {
                        Text(label.text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(
                                Color(
                                    red: Double(label.tint.x),
                                    green: Double(label.tint.y),
                                    blue: Double(label.tint.z),
                                    opacity: 0.92
                                )
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(OhiaColors.surface(0.10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(OhiaColors.surface(0.18), lineWidth: 0.5)
                                    )
                            )
                            .position(position)
                            .allowsHitTesting(false)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var dyingPersonWormholeOverlay: some View {
        if !dyingPersonSnapshots.isEmpty {
            TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { context in
                ZStack(alignment: .topLeading) {
                    ForEach(dyingPersonWormholeItems(at: context.date)) { item in
                        let rect = CGRect(
                            x: item.anchor.x - 0.5,
                            y: item.anchor.y - 0.5,
                            width: 1,
                            height: 1
                        )
                        AnnotationWormhole(
                            anchor: item.anchor,
                            rect: rect,
                            phase: Self.peopleDeathWormholePhase(startedAt: item.startedAt),
                            palette: AnnotationWormholePalette.account(
                                AccountColorPalette.color(forIndex: AccountColorPalette.defaultIndex)
                            ),
                            vortexScale: Self.peopleDeathWormholeVortexScale
                        ) {
                            Color.clear
                                .frame(width: 1, height: 1)
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    @MainActor
    private func dyingPersonWormholeItems(at date: Date) -> [DyingPersonWormholeItem] {
        guard viewSize.width > 1, viewSize.height > 1 else { return [] }
        return dyingPersonSnapshots.compactMap { snapshot in
            let phase = Self.peopleDeathWormholePhase(startedAt: snapshot.startedAt)
            guard !phase.at(date).isComplete,
                  let anchor = ScreenProjection.project(
                      world: snapshot.hub.position,
                      camera: cameraController.state,
                      viewSize: viewSize,
                      fovYRadians: .pi / 3
                  ) else {
                return nil
            }
            return DyingPersonWormholeItem(
                id: PeopleRingMessageScope.normalizedEmail(snapshot.hub.email),
                anchor: anchor,
                startedAt: snapshot.startedAt
            )
        }
    }

    @MainActor
    private var meaningLockedMainEmailActionTarget: MessageActionDiscTarget? {
        guard state.activeFrame.spatialLens == .meaning,
              let lockedVectorId = state.lockedVectorId,
              revealedLockedVectorId == lockedVectorId,
              lockNeighbourRank.currentIndex == 0,
              let record = visibleRecordCache[lockedVectorId] ?? citationSourceRecord(vectorId: lockedVectorId),
              let messageID = UUID(uuidString: record.messageId),
              let row = currentMessageIndex[record.messageId] else {
            return nil
        }
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == messageID })
        descriptor.fetchLimit = 1
        let message = try? modelContext.fetch(descriptor).first
        return MessageActionDiscTarget(
            messageID: messageID,
            statusDescriptor: MessageStatusDescriptor.constellationRow(
                row,
                messageID: messageID,
                statusSignals: lockedOverlayMessageStatusSignals,
                includeAmbientSharedEvidence: true
            ),
            isInComposerQueue: message.map { ComposerQueueMembership.isInQueue($0) } ?? false,
            isListIgnoreEligible: message.map(MailingListIgnoreRuleService.isEligibleListMessage) ?? false
        )
    }

    /// Resolved action target for the click-selected People-lens ring satellite.
    /// Mirrors `meaningLockedMainEmailActionTarget` but keys off
    /// `lockedRingSelectionMessageId` (the ring email the user clicked) rather
    /// than the rank-0 main email. `nil` when no ring node is selected or its
    /// message has left the filtered scene — the action column then collapses
    /// to just the close + legend discs.
    @MainActor
    private var ringSelectionActionTarget: MessageActionDiscTarget? {
        guard state.activeFrame.spatialLens == .people,
              liveLockPersonFocus != nil,
              let messageId = lockedRingSelectionMessageId,
              let uuid = UUID(uuidString: messageId),
              let row = currentMessageIndex[messageId] else {
            return nil
        }
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == uuid })
        descriptor.fetchLimit = 1
        let message = try? modelContext.fetch(descriptor).first
        return MessageActionDiscTarget(
            messageID: uuid,
            statusDescriptor: MessageStatusDescriptor.constellationRow(
                row,
                messageID: uuid,
                statusSignals: lockedOverlayMessageStatusSignals,
                includeAmbientSharedEvidence: true
            ),
            isInComposerQueue: message.map { ComposerQueueMembership.isInQueue($0) } ?? false,
            isListIgnoreEligible: message.map(MailingListIgnoreRuleService.isEligibleListMessage) ?? false
        )
    }

    @ViewBuilder
    private var apertureReadoutOverlay: some View {
        // Two-stage gating avoids steady-state cost: the outer `if` is
        // evaluated only when `apertureReadoutTimer` changes, and the inner
        // TimelineView ticks exclusively during the fade window.
        if apertureReadoutTimer != nil {
            TimelineView(.periodic(from: .now, by: OhiaAnimationCadence.frameInterval)) { context in
                VStack {
                    HStack {
                        ApertureReadoutView(
                            aperture: state.aperture,
                            apertureNodeCount: renderPacket.stars.count,
                            totalNodeCount: renderPacket.totalMessageCount,
                            lastInputAt: apertureReadoutTimer,
                            now: context.date
                        )
                        .padding(.leading, 14)
                        .padding(.top, 54)
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
    }

    static func placeHoverPopup(
        nodePoint: CGPoint,
        viewSize: CGSize
    ) -> CGPoint {
        HoverPopupPlacement.center(nodePoint: nodePoint, viewSize: viewSize)
    }

    /// Side-of-node placement used by the email-node hover popup
    /// (`HoverReadoutView`). The popup sits beside the node with a small
    /// horizontal gap and a vertical offset that aligns its
    /// direction-label row with the node's y. The returned side drives the
    /// header mirror and the tether's terminal edge.
    static func placeHoverPopupAdjacent(
        nodePoint: CGPoint,
        viewSize: CGSize,
        popupSize: CGSize = HoverPopupPlacement.defaultEnvelope
    ) -> HoverPopupPlacement.AdjacentPlacement {
        HoverPopupPlacement.adjacent(
            nodePoint: nodePoint,
            viewSize: viewSize,
            popupSize: popupSize
        )
    }

    private var emailHoverEnvelope: CGSize {
        HoverPopupPlacement.emailEnvelope(for: readingTextSize)
    }

    @MainActor
    private var shouldShowEmailHoverPaneInCurrentLens: Bool {
        PeopleConstellationHoverPolicy.shouldShowEmailHover(
            activeFrame: state.activeFrame,
            lockedVectorId: state.lockedVectorId,
            hasLivePersonFocus: liveLockPersonFocus != nil
        )
    }

    @MainActor
    private func clearEmailHoverPaneState() {
        state.hoveredVectorId = nil
        hoveredPersonEmail = nil
        setHoveredMeaningCluster(nil)
        hoveredSunReadout = false
        metalRenderer.setHoveredOrbitPathHub(email: nil)
    }

    @MainActor
    private func clearEmailHoverPaneIfSuppressed() -> Bool {
        guard !shouldShowEmailHoverPaneInCurrentLens else { return false }
        projectedHoverTarget = nil
        clearEmailHoverPaneState()
        return true
    }

    @MainActor
    private func refreshProjectedHoverAnchor(_ target: ProjectedHoverTarget) {
        guard !clearEmailHoverPaneIfSuppressed() else { return }
        let vectorId = target.vectorId
        state.hoveredVectorId = updateProjectedHoverAnchor(
            vectorId: vectorId,
            worldOverride: target.worldPosition
        ) ? vectorId : nil
    }

    @MainActor
    private func handleCitationHover(_ vectorId: Int64?) {
        guard let vectorId else {
            if case .citation(let active) = projectedHoverTarget,
               state.hoveredVectorId == active {
                state.hoveredVectorId = nil
            }
            if case .citation = projectedHoverTarget {
                projectedHoverTarget = nil
            }
            return
        }

        guard !clearEmailHoverPaneIfSuppressed() else { return }
        projectedHoverTarget = .citation(vectorId)
        hoveredPersonEmail = nil
        setHoveredMeaningCluster(nil)
        if updateProjectedHoverAnchor(vectorId: vectorId) {
            state.hoveredVectorId = vectorId
        } else {
            state.hoveredVectorId = nil
        }
    }

    @MainActor
    private func handleAskCitationClick(vectorId: Int64) {
        guard let record = citationSourceRecord(vectorId: vectorId) else { return }
        switch AskCitationLensRoutingPolicy.route(activeFrame: state.activeFrame) {
        case .timelineWorkspace:
            if focusTimelineAskCitation(record) == false {
                queuePendingTimelineAskCitation(record)
            }
            return
        case .projectsWorkspace:
            if focusProjectsAskCitation(record) == false {
                queuePendingProjectsAskCitation(record)
            }
            return
        case .frontPageWorkspace:
            if focusFrontPageAskCitation(record) == false {
                queuePendingFrontPageAskCitation(record)
            }
            return
        case .metalMessageFocus:
            focusAskCitationInMetalLens(vectorId: vectorId, record: record)
        }
    }

    @MainActor
    private func focusAskCitationInMetalLens(vectorId: Int64, record: VectorRecord) {
        guard Self.usesMetalScene(state.activeFrame) else { return }
        let world = frameAwarePosition(vectorId: vectorId, fallbackRecord: record)
            ?? Self.worldPosition(for: record)
        let sourceColor = renderedNodeColor(vectorId: vectorId, messageId: record.messageId)
        queueSelectedNodeFocus(
            vectorId: vectorId,
            fallbackWorld: world,
            sourceColor: sourceColor,
            allowsPeopleEmailFocus: Self.askCitationAllowsEmailFocus(activeFrame: state.activeFrame)
        )
    }

    @MainActor
    @discardableResult
    private func focusTimelineAskCitation(_ record: VectorRecord) -> Bool {
        guard state.activeFrame.spatialLens == .timeline,
              let timelineWorkspace,
              let messageID = UUID(uuidString: record.messageId) else {
            return false
        }
        let fallbackDate = record.messageReceivedAt.map { Date(timeIntervalSince1970: $0) }
        return timelineWorkspace.focusMessage(
            messageID,
            date: fallbackDate,
            maximumViewportSpan: Self.timelineSearchWarpViewportSpan
        )
    }

    @MainActor
    @discardableResult
    private func focusProjectsAskCitation(_ record: VectorRecord) -> Bool {
        guard state.activeFrame.spatialLens == .projects,
              let workspace = projectsWorkspace,
              let snapshot = workspace.currentSnapshot,
              ProjectsDataController.signatureMatchesCurrentFilter(
                  snapshot: snapshot,
                  filter: state.filter
              ),
              let messageID = UUID(uuidString: record.messageId) else {
            return false
        }
        return workspace.openLinksForMessage(messageID, in: snapshot, openEmailReadout: true)
    }

    @MainActor
    @discardableResult
    private func focusFrontPageAskCitation(_ record: VectorRecord) -> Bool {
        guard state.activeFrame.spatialLens == .frontPage,
              let workspace = frontPageWorkspace,
              let snapshot = workspace.currentSnapshot,
              FrontPageDataController.signatureMatchesCurrentFilter(
                  snapshot: snapshot,
                  filter: state.filter,
                  selectedTimeRange: state.selectedTimeRange,
                  unreadOnly: workspace.unreadOnly
              ),
              let messageID = UUID(uuidString: record.messageId) else {
            return false
        }
        guard let articleID = frontPageData.displayArticleID(
            forMatchedMessageID: messageID,
            in: snapshot
        ) else {
            return false
        }
        return workspace.focusArticleDisplayingSearchMatch(articleID)
    }

    @MainActor
    private func queuePendingTimelineAskCitation(_ record: VectorRecord) {
        guard state.activeFrame.spatialLens == .timeline,
              let messageID = UUID(uuidString: record.messageId) else {
            return
        }
        pendingTimelineAskCitation = PendingTimelineAskCitation(
            messageID: messageID,
            fallbackDate: record.messageReceivedAt.map { Date(timeIntervalSince1970: $0) }
        )
        timelineData.invalidateAndRefreshIfBound()
        completePendingTimelineAskCitationNavigation()
    }

    @MainActor
    private func queuePendingProjectsAskCitation(_ record: VectorRecord) {
        guard state.activeFrame.spatialLens == .projects,
              let messageID = UUID(uuidString: record.messageId) else {
            return
        }
        pendingProjectsAskCitationMessageID = messageID
        projectsData.invalidateAndRefresh()
        completePendingProjectsAskCitationNavigation()
    }

    @MainActor
    private func queuePendingFrontPageAskCitation(_ record: VectorRecord) {
        guard state.activeFrame.spatialLens == .frontPage,
              let messageID = UUID(uuidString: record.messageId) else {
            return
        }
        pendingFrontPageAskCitationMessageID = messageID
        requestFrontPageRefreshForCurrentStateIfActive()
        completePendingFrontPageAskCitationNavigation()
    }

    @MainActor
    private func clearPendingAskCitationNavigation() {
        pendingTimelineAskCitation = nil
        pendingProjectsAskCitationMessageID = nil
        pendingFrontPageAskCitationMessageID = nil
    }

    @MainActor
    @discardableResult
    private func updateProjectedHoverAnchor(
        vectorId: Int64,
        fallbackRecord: VectorRecord? = nil,
        worldOverride: SIMD3<Float>? = nil
    ) -> Bool {
        let record = fallbackRecord
            ?? visibleRecordCache[vectorId]
            ?? citationSourceRecord(vectorId: vectorId)
        guard let point = projectedPointForVector(
            vectorId,
            fallbackRecord: record,
            worldOverride: worldOverride
        ) else {
            return false
        }
        hoverNodePoint = point
        // Projected hover surfaces the same `HoverReadoutView` as regular
        // email-node hover, so it uses the same side-of-node placement.
        hoverPosition = Self.placeHoverPopupAdjacent(
            nodePoint: point,
            viewSize: viewSize,
            popupSize: emailHoverEnvelope
        ).center
        return true
    }

    @MainActor
    private func projectedPointForVector(
        _ vectorId: Int64,
        fallbackRecord: VectorRecord? = nil,
        worldOverride: SIMD3<Float>? = nil
    ) -> CGPoint? {
        guard viewSize.width > 1, viewSize.height > 1 else { return nil }
        let messageId = fallbackRecord?.messageId
        // Ask citations resolve through source vectors, but the user sees one
        // star per email. Prefer the rendered message star so the hover leader
        // points at the email node, not a chunk/vector satellite.
        let world = worldOverride
            ?? messageId.flatMap { id in
                renderPacket.stars.first(where: { $0.messageId == id })?.position
            }
            ?? messageId.flatMap { id in
                renderPacket.hitProxies.first(where: { $0.messageId == id })?.worldPosition
            }
            ?? renderPacket.hitProxies.first(where: { $0.vectorId == vectorId })?.worldPosition
            ?? frameAwarePosition(vectorId: vectorId, fallbackRecord: fallbackRecord)
        guard let world else { return nil }
        return ScreenProjection.project(
            world: world,
            camera: cameraController.state,
            viewSize: viewSize,
            fovYRadians: .pi / 3
        )
    }

    @ViewBuilder
    private var personHubHoverOverlay: some View {
        // Normally suppressed while a lock is open so the lock card owns
        // the selected-node feedback. In the People-lens portrait overlay
        // (`liveLockPersonFocus != nil`) the hover popup over the focused
        // Saturn is restored — the user can still see correspondent
        // metrics on hover while inspecting ring emails.
        if pendingFocusClick == nil,
           state.lockedVectorId == nil || liveLockPersonFocus != nil,
           let context = hoveredPersonHubContext {
            HoverNodeIndicator()
                .id(context.email)
                .position(hoverNodePoint)
                .constellationHoverNodeIndicatorEmerge()

            ConstellationHoverTetherShape(
                from: hoverNodePoint,
                to: hoverPosition,
                popupSize: CGSize(width: 308, height: 150)
            )
            .stroke(
                OhiaColors.chipActiveBorder.opacity(0.72),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3])
            )
            .allowsHitTesting(false)
            .transition(.opacity)

            PersonHubHoverCard(context: context)
                .position(hoverPosition)
                .constellationHoverPopupEmerge()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(context.accessibilityLabel)
        }
    }

    /// Hover readout for the solar system's sun — the user's aggregate
    /// correspondence across every account in scope. Mirrors the person
    /// hover overlay's structure (indicator + tether + card) so the sun
    /// reads as a first-class hoverable body.
    @ViewBuilder
    private var sunHoverOverlay: some View {
        if pendingFocusClick == nil,
           state.lockedVectorId == nil,
           liveLockPersonFocus == nil,
           hoveredSunReadout,
           let sun = renderPacket.personSun {
            HoverNodeIndicator()
                .id(PersonSunInstance.hitProxyMessageId)
                .position(hoverNodePoint)
                .constellationHoverNodeIndicatorEmerge()

            ConstellationHoverTetherShape(
                from: hoverNodePoint,
                to: hoverPosition,
                popupSize: CGSize(width: 308, height: 132)
            )
            .stroke(
                OhiaColors.chipActiveBorder.opacity(0.72),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3])
            )
            .allowsHitTesting(false)
            .transition(.opacity)

            PersonSunHoverCard(sun: sun, accounts: accounts)
                .position(hoverPosition)
                .constellationHoverPopupEmerge()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "You. \(sun.correspondentCount) correspondents, \(accounts.count) accounts, \(sun.sentCount) sent, \(sun.receivedCount) received, \(sun.openObligationCount) open obligations."
                )
        }
    }

    private static let meaningClusterHoverBodyWidth = MeaningClusterHoverCard.width
    private static let meaningClusterHoverBodyFallbackHeight: CGFloat = 118
    private static let meaningClusterHoverHeaderFallbackHeight: CGFloat = 19

    @ViewBuilder
    private var meaningClusterHoverOverlay: some View {
        if pendingFocusClick == nil,
           state.lockedVectorId == nil,
           let context = hoveredMeaningClusterContext {
            // Terminate the leader on the bordered card's top edge at the
            // node's y — not on the floating "Meaning" annotation row above
            // the card. Shift the card down so its top-left corner sits on
            // the leader's attach point.
            let bodyHeight = meaningClusterHoverBodyHeight > 0
                ? meaningClusterHoverBodyHeight
                : Self.meaningClusterHoverBodyFallbackHeight
            let headerChrome: CGFloat = {
                if meaningClusterHoverHeight > meaningClusterHoverBodyHeight,
                   meaningClusterHoverBodyHeight > 0 {
                    return meaningClusterHoverHeight - meaningClusterHoverBodyHeight
                }
                return Self.meaningClusterHoverHeaderFallbackHeight
            }()
            let attachY = hoverNodePoint.y
            let totalHeight = meaningClusterHoverHeight > 0
                ? meaningClusterHoverHeight
                : headerChrome + bodyHeight
            let popupCenter = CGPoint(
                x: hoverPosition.x,
                y: attachY + totalHeight / 2 - headerChrome
            )
            let mirrored = popupCenter.x < hoverNodePoint.x

            HoverNodeIndicator()
                .id(context.clusterId)
                .position(hoverNodePoint)
                .allowsHitTesting(false)
                .constellationHoverNodeIndicatorEmerge()

            ConstellationHoverTetherShape(
                from: hoverNodePoint,
                to: popupCenter,
                popupSize: CGSize(
                    width: Self.meaningClusterHoverBodyWidth,
                    height: bodyHeight
                ),
                attachY: attachY
            )
            .stroke(
                context.tintColor.opacity(0.78),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
            .allowsHitTesting(false)
            .transition(.opacity)

            MeaningClusterHoverCard(
                context: context,
                mirrored: mirrored
            )
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MeaningClusterHoverHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
                .onPreferenceChange(MeaningClusterHoverHeightPreferenceKey.self) { height in
                    if height > 0 {
                        meaningClusterHoverHeight = height
                    }
                }
                .onPreferenceChange(MeaningClusterHoverBodyHeightPreferenceKey.self) { height in
                    if height > 0 {
                        meaningClusterHoverBodyHeight = height
                    }
                }
                .position(popupCenter)
                .allowsHitTesting(false)
                .constellationHoverPopupEmerge()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(context.accessibilityLabel)
        }
    }

    @ViewBuilder
    private var hoverReadoutOverlay: some View {
        // Hover readout — tethered annotation at hoverPosition. Hidden
        // while ANY lock is open so the lock path owns the selected-node
        // feedback. In particular: the People-focus locked overlay now
        // renders its own `PeopleDialWedge` (a polar wedge orbiting the
        // focused Saturn) for both Tab and hover — surfacing the standard
        // `HoverReadoutView` alongside it would compete with the dial for
        // the same screen real estate and produce two overlapping panes
        // describing the same satellite.
        if pendingFocusClick == nil,
           state.lockedVectorId == nil,
           let id = state.hoveredVectorId,
           let rec = visibleRecordCache[id] ?? citationSourceRecord(vectorId: id),
           let row = currentMessageIndex[rec.messageId] {
            HoverNodeIndicator()
                .id(id)
                .position(hoverNodePoint)
                .constellationHoverNodeIndicatorEmerge()

            ConstellationHoverTetherShape(
                from: hoverNodePoint,
                to: hoverPosition,
                popupSize: emailHoverEnvelope,
                attachY: hoverNodePoint.y
            )
            .stroke(
                OhiaColors.chipActiveBorder,
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
            .allowsHitTesting(false)
            .transition(.opacity)

            HoverReadoutView(
                context: HoverReadoutContext(
                    messageId: rec.messageId,
                    row: row,
                    summaryOverride: summaryByMessageId[rec.messageId],
                    classificationOverride: classificationByMessageId[rec.messageId],
                    summaryUnavailableReason: summaryUnavailableReasonByMessageId[rec.messageId],
                    summaryIsRegenerating: regeneratingSummaryMessageIds.contains(rec.messageId),
                    summaryIsLoading: shouldShowSummaryPlaceholder(
                        forMessageId: rec.messageId,
                        row: row
                    ),
                    account: hoverAccountContext(for: row),
                    peopleFocusEmail: lockedCorrespondentFocusEmail()
                ),
                mirrored: hoverPosition.x < hoverNodePoint.x
            )
            .position(hoverPosition)
            .allowsHitTesting(false)
            .constellationHoverPopupEmerge()
        }
    }

    @ViewBuilder
    private var focusClickPendingOverlay: some View {
        if let pending = pendingFocusClick,
           pending.personFocus == nil,
           let point = focusClickPendingPoint(for: pending) {
            FocusJumpPendingIndicator(startedAt: pending.startedAt, sourceColor: pending.sourceColor)
                .id(pending.id)
                .position(point)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityLabel("Opening email node")
        }
    }

    @ViewBuilder
    private var sceneRenderProgressOverlay: some View {
        if let progress = sceneRenderProgress, sceneRenderProgressVisible {
            OhiaLoadingIndicator(
                accessibilityLabel: Self.sceneRenderProgressAccessibilityLabel(progress.reason)
            )
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.18), value: progress.sequence)
        }
    }

    @ViewBuilder
    private func focusSourcePreviewOverlay(
        opacity: Double,
        scale: CGFloat,
        coordinates: FocusSourcePreviewCoordinates
    ) -> some View {
        if let preview = focusSourcePreview {
            let clickPoint = preview.clickPoint(in: coordinates)
            let popupCenter = preview.popupCenter(in: coordinates)
            ConstellationHoverTetherShape(
                from: clickPoint,
                to: popupCenter,
                popupSize: emailHoverEnvelope,
                attachY: clickPoint.y
            )
            .stroke(
                swiftUIColor(from: preview.sourceColor).opacity(0.72),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
            .allowsHitTesting(false)
            .opacity(opacity)

            HoverReadoutView(
                context: HoverReadoutContext(
                    messageId: preview.messageId,
                    row: preview.row,
                    summaryOverride: preview.summaryOverride,
                    classificationOverride: preview.classificationOverride,
                    summaryUnavailableReason: nil,
                    summaryIsLoading: false,
                    account: hoverAccountContext(for: preview.row),
                    peopleFocusEmail: lockedCorrespondentFocusEmail()
                ),
                mirrored: popupCenter.x < clickPoint.x
            )
            .position(popupCenter)
            .scaleEffect(scale)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var pendingLockSelectionOverlay: some View {
        if let id = state.lockedVectorId,
           revealedLockedVectorId != id,
           suppressedPendingLockIndicatorVectorId != id {
            pendingLockSelectionIndicator(vectorId: id)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var lockedNodeOverlayLayer: some View {
        if let id = state.lockedVectorId,
           revealedLockedVectorId == id,
           let rec = visibleRecordCache[id] ?? citationSourceRecord(vectorId: id),
           let row = currentMessageIndex[rec.messageId] {
            lockedNodeOverlay(id: id, record: rec, row: row)
                .transition(.opacity)
        }
    }

    /// Hidden Esc-as-cancel button installed at the body level whenever
    /// any lock state is active. Sized to zero and `.allowsHitTesting(false)`
    /// so it never affects layout, hit-testing, or VoiceOver — its sole
    /// job is to register an Esc keyEquivalent with the host window while
    /// a lock (regular or focused) is on screen. Only rendered conditionally
    /// so `.cancelAction` doesn't steal Esc when no lock is active.
    @ViewBuilder
    private var lockedNodeEscDismissButton: some View {
        if state.lockedVectorId != nil && !liveFocusExitInFlight {
            Button {
                // Always release the lock. Rank-step is preselected on
                // entry (index 0 = main email), so a two-stage
                // "exit rank-step first, release on second Esc" path
                // would mean Esc never dismisses the overlay until the
                // user explicitly tabbed to a non-main pane and back.
                // Reset rank state alongside release so we don't leak
                // the active index into the next lock session.
                lockNeighbourRank.exit()
                leaveSelectedNodeFocus()
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Collapsed version of `cornerControlsColumn` used while the
    /// People-lens lock is in its portrait state. Same disc chrome as the
    /// legend / recenter buttons, but the only affordance is "release the
    /// lock" — matching the Meanings overlay's lock-card xmark.
    private func peopleFocusCloseButtonColumn(onLeading: Bool) -> some View {
        let columnWidth: CGFloat = 70
        let ringTarget = ringSelectionActionTarget
        return VStack(spacing: 14) {
            LensActionDisc(
                glyph: .native("xmark.circle.fill"),
                label: "Close",
                accessibility: "Release lock",
                action: leaveSelectedNodeFocus
            )

            // Recenter the camera on the focused correspondent's Saturn.
            // `recenterCamera()` is lock-aware: while a lock is active it
            // targets the locked/focused node instead of resetting the whole
            // constellation packet. The one-second disabled state reads as
            // "recenter in flight" and prevents repeated clicks from stacking.
            LensActionDisc(
                glyph: .knockout("scope"),
                label: "Recenter",
                accessibility: "Recenter",
                isEnabled: !recenterCooldownActive
            ) {
                beginRecenterCooldown()
                recenterCamera()
            }

            // Lock-overlay shortcut legend — moved here from the
            // CORRESPONDENT card so the People lock carries its legend on
            // the rail like the other lenses' columns.
            LensActionDisc(
                glyph: .native("questionmark.circle.fill"),
                label: "Legend",
                accessibility: "Locked node shortcuts",
                isActive: true,
                isEnabled: !lockRingLegendPresented,
                action: { lockRingLegendPresented.toggle() }
            )
            .popover(isPresented: $lockRingLegendPresented, arrowEdge: onLeading ? .trailing : .leading) {
                LockedNodeOverlayLegendView(scope: .peopleFocus)
                    .frame(width: 440)
            }

            if ConstellationEdgeColumnPolicy.showsStandalonePeopleComposeDisc(
                hasRingSelectionActions: ringTarget != nil
            ), let composerTarget = composerQueueRailTarget {
                composerQueueRailButton(composerTarget)
            }

            // Ring-node actions appear below a divider when the user has
            // click-selected a satellite on the correspondent's rings.
            if let ringTarget {
                Rectangle()
                    .fill(OhiaColors.glassBorder.opacity(0.6))
                    .frame(height: 1)
                    .padding(.horizontal, 14)
                RingNodeActionDiscGroup(
                    target: ringTarget,
                    actions: frontPageMessageActions,
                    onAfterDelete: { lockedRingSelectionMessageId = nil }
                )
            }

            Spacer(minLength: 0)
        }
        .responsiveActionDiscLabels()
        .padding(.vertical, 14)
        .frame(width: columnWidth)
        .frame(maxHeight: .infinity)
        .background(OhiaColors.glassPanel)
        .overlay(
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: onLeading ? .trailing : .leading)
        )
    }

    private func cornerControlsColumn(onLeading: Bool) -> some View {
        let columnWidth: CGFloat = 70
        return VStack(spacing: 18) {
            // Reserved for the overlaid starburst so capsule text can
            // grow into the scene without widening the column.
            StarburstLabelSlot()
            // Mirror the starburst chrome (38×38 disc, surface fill,
            // chipActiveBorder ring + icon tint) so the recenter
            // affordance reads as a sibling control rather than a
            // generic system glyph. It greys for one second after a click
            // while the camera move is treated as in flight.
            LensActionDisc(
                glyph: .knockout("scope"),
                label: "Recenter",
                accessibility: "Recenter",
                isEnabled: !recenterCooldownActive
            ) {
                beginRecenterCooldown()
                recenterCamera()
            }
            LensActionDisc(
                glyph: .native("questionmark.circle.fill"),
                label: "Legend",
                accessibility: "Legend",
                isActive: true,
                isEnabled: !legendPresented,
                action: { legendPresented.toggle() }
            )
            .popover(isPresented: $legendPresented, arrowEdge: onLeading ? .trailing : .leading) {
                ConstellationLegendView(
                    hasSearch: state.searchResultIds.isEmpty == false,
                    hasCitations: qaVM.citationVectorIds.isEmpty == false,
                    hasSelection: state.lockedVectorId != nil,
                    hasNebulae: renderPacket.nebulae.isEmpty == false,
                    hasFibers: renderPacket.fibers.isEmpty == false,
                    showsOrbitGrammar: renderPacket.personSun != nil
                )
                .frame(width: 400)
            }
            if state.activeFrame.spatialLens == .people {
                Rectangle()
                    .fill(OhiaColors.glassBorder.opacity(0.6))
                    .frame(height: 1)
                    .padding(.horizontal, 14)

                // Match the LensActionDisc rows above: the control centres
                // on the disc axis and its gloss label centres beneath it.
                VStack(spacing: 3) {
                    Toggle(isOn: $hidesPeopleOrbitPaths) {
                        EmptyView()
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .tint(OhiaColors.chipActiveForeground)
                    .labelsHidden()
                    Text("Hide Orbits")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(OhiaColors.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Hide orbit lines")
            }
            if let composerTarget = composerQueueRailTarget {
                composerQueueRailButton(composerTarget)
            }
            Spacer(minLength: 0)
        }
        .responsiveActionDiscLabels()
        .padding(.vertical, 14)
        .frame(width: columnWidth)
        .frame(maxHeight: .infinity)
        .background(OhiaColors.glassPanel)
        .overlay(
            // Hairline divider on the column's body-facing edge.
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: onLeading ? .trailing : .leading)
        )
        .overlay(alignment: onLeading ? .topLeading : .topTrailing) {
            NewStarFormationNoticeView(
                formingCount: newStarNavigator.formingCount,
                badgeCount: NewMailArrivalLedger.shared.unvisitedCount,
                formationText: starburstCapsuleText,
                isNavigable: NewMailArrivalLedger.shared.unvisitedCount > 0,
                isSearching: manualRefresh.state == .searching,
                failureKind: starburstFailureKind,
                ackFlickerSeq: manualRefresh.ackFlickerSeq,
                emptySignalSeq: manualRefresh.emptySignalSeq,
                action: handleStarburstClick,
                menuAction: handleBeaconMenuCommand
            )
            .fixedSize()
            .padding(.top, 14)
            .padding(.leading, onLeading ? (columnWidth - 38) / 2 : 0)
            .padding(.trailing, onLeading ? 0 : (columnWidth - 38) / 2)
        }
    }

    @MainActor
    private var composerQueueRailTarget: ComposerQueueRailTarget? {
        guard let messageID = composerQueueRailMessageID() else { return nil }
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == messageID })
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first else { return nil }

        let isInQueue = ComposerQueueMembership.isInQueue(message)
        // Any inbound message can be sent to the Composer; sent mail cannot.
        let isInbound = !message.isSentByUser
        guard isInbound || isInQueue else { return nil }

        return ComposerQueueRailTarget(
            messageID: messageID,
            isInQueue: isInQueue,
            isEnabled: isInbound && !isInQueue && ComposerQueueMembership.canToggleNeedsReply(message)
        )
    }

    @MainActor
    private func composerQueueRailMessageID() -> UUID? {
        if let locked = visibleLockedMessageId(),
           let messageID = UUID(uuidString: locked) {
            return messageID
        }
        guard let vectorID = state.hoveredVectorId,
              let record = visibleRecordCache[vectorID] ?? citationSourceRecord(vectorId: vectorID) else {
            return nil
        }
        return UUID(uuidString: record.messageId)
    }

    @MainActor
    private func composerQueueRailButton(_ target: ComposerQueueRailTarget) -> some View {
        let help = target.isInQueue ? "Already in Composer queue" : "Send to Composer"
        // Fronting follows ComposerOpenOnQueuePreference (default on) inverted by
        // ⌥ at click time; the disc relabels itself to match.
        return LensComposeDisc(
            isActive: target.isInQueue,
            isEnabled: target.isEnabled,
            restAccessibility: help,
            action: {
                frontPageSendToComposer([target.messageID], openComposer: ComposerOpenOnQueuePreference.opensComposer(optionHeld: NSEvent.modifierFlags.contains(.option)))
            }
        )
    }

    private var liveInboundNotificationBridge: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .ohiaLiveInboundReadyForLensPresentation
                )
            ) { notification in
                handleLiveInboundReadyForLensPresentation(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaIMAPNewInboundMessages)) { notification in
                handleLiveInboundNotification(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaNewMailArrivalVisibilityChanged)) { _ in
                handleArrivalVisibilityChanged()
            }
    }

    @ViewBuilder
    private var debugOverlay: some View {
        if renderDebugHUDPref, let renderStats {
            VStack {
                Spacer()
                HStack {
                    RenderDebugHUD(stats: renderStats, packet: renderPacket)
                        .padding(14)
                    Spacer()
                }
            }
            .allowsHitTesting(false)
        }
    }

    @MainActor
    // MARK: - Literal search

    /// Run the exact-biased literal search for the current query, honouring the
    /// active top-bar filter scope, then pin and flash the matched nodes. This
    /// intentionally does not move the camera; only the Search tab's explicit
    /// Warp action (button or ⌘Return) engages travel.
    private func performLexicalSearch() {
        clearSearchWarpNavigation()
        beginSceneRenderProgress(.search)
        cancelSemanticSearchPreparation()
        Task {
            let query = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let filter = await searchFilterSpec()
            let result = (try? await lexicalController.search(query, filter: filter))
                ?? .empty(query: query)
            lexicalResult = result
            selectedSearchLane = result.defaultLane
            searchMatchIndex = 0
            applySearchLaneHighlights(result: result, lane: selectedSearchLane)

            if !result.semanticLaneAvailable {
                prepareSemanticSearchLaneForCurrentQuery(result.query)
            }

            guard Self.usesMetalScene(state.activeFrame) else { return }
            await refreshSceneData()
        }
    }

    private func cancelSemanticSearchPreparation() {
        semanticSearchPreparationSequence += 1
        semanticSearchPreparationTask?.cancel()
        semanticSearchPreparationTask = nil
        semanticSearchPendingQuery = nil
    }

    /// Ensure semantic query embedding is available (locally or through the
    /// retrieval worker), then rerun the unchanged query so the NEARBY lane
    /// stops at "preparing" only when BGE is genuinely unavailable.
    private func prepareSemanticSearchLaneForCurrentQuery(_ query: String) {
        guard !query.isEmpty else { return }
        semanticSearchPreparationTask?.cancel()
        semanticSearchPreparationSequence += 1
        let sequence = semanticSearchPreparationSequence
        semanticSearchPendingQuery = query
        semanticSearchPreparationTask = Task { @MainActor in
            defer {
                if semanticSearchPreparationSequence == sequence {
                    semanticSearchPreparationTask = nil
                    semanticSearchPendingQuery = nil
                }
            }
            let isReady = await services.prepareBGE3ForInteractiveRetrievalIfAvailable()
            guard isReady, !Task.isCancelled else { return }
            guard state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }

            let filter = await searchFilterSpec()
            let result = (try? await lexicalController.search(query, filter: filter))
                ?? .empty(query: query)
            guard !Task.isCancelled else { return }
            guard state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }

            lexicalResult = result
            selectedSearchLane = result.defaultLane
            searchMatchIndex = 0
            applySearchLaneHighlights(result: result, lane: selectedSearchLane)

            guard Self.usesMetalScene(state.activeFrame) else { return }
            await refreshSceneData()
        }
    }

    /// Select which search lane feeds the navigator and scene highlights.
    private func selectSearchLane(_ lane: LexicalSearchLane) {
        guard let result = lexicalResult, result.laneIsSelectable(lane) else { return }
        selectedSearchLane = lane
        searchMatchIndex = 0
        applySearchLaneHighlights(result: result, lane: lane)

        guard searchWarpNavigationActive,
              state.lockedVectorId == nil else {
            return
        }
        if activeFrameSupportsNonMetalSearchNavigation {
            _ = focusSearchMatchInActiveNonMetalLens(startingAt: 0, direction: 1)
        } else if Self.usesMetalScene(state.activeFrame) {
            requestSearchMatchReframe(0)
        }
    }

    @MainActor
    private func applySearchLaneHighlights(result: LexicalSearchResult, lane: LexicalSearchLane?) {
        let matches = result.matches(for: lane)
        let highlightIds = matches.map(\.vectorId)
        state.searchResultIds = highlightIds
        let intensity: Float = lane == .semantic ? 0.5 : 1.0
        searchScores = Array(repeating: intensity, count: highlightIds.count)
        searchResultRecordCache = Dictionary(
            uniqueKeysWithValues: ((try? services.vectorStore.hydrate(vectorIds: highlightIds)) ?? [])
                .map { ($0.vectorId, $0) }
        )
    }

    private func activeSearchMatches() -> [LexicalSearchResult.Match] {
        lexicalResult?.matches(for: selectedSearchLane) ?? []
    }

    /// Select a search match by (wrapping) index. Before an explicit Warp
    /// this only changes the sidebar selection; after Warp, stepping recenters
    /// each hit at a lens-appropriate distance and advances the hover pane.
    private func selectSearchMatch(_ rawIndex: Int) {
        let matches = activeSearchMatches()
        guard !matches.isEmpty else { return }
        let index = wrappedSearchMatchIndex(rawIndex, count: matches.count)
        searchMatchIndex = index
        if searchWarpNavigationActive,
           state.lockedVectorId == nil {
            if state.activeFrame.spatialLens == .timeline {
                _ = focusTimelineSearchMatch(matches[index])
            } else if state.activeFrame.spatialLens == .projects {
                _ = focusProjectsSearchMatch(matches[index])
            } else if state.activeFrame.spatialLens == .frontPage {
                _ = focusFrontPageSearchMatch(matches[index])
            } else if Self.usesMetalScene(state.activeFrame) {
                requestSearchMatchReframe(index)
            }
        }
    }

    /// Explicitly travel to a literal match. This is the Search-tab path that
    /// engages `WarpAnimator` for the button and ⌘Return.
    private func requestSearchMatchWarp(_ rawIndex: Int) {
        Task {
            await warpToSearchMatch(rawIndex)
        }
    }

    @MainActor
    private func warpToSearchMatch(_ rawIndex: Int) async {
        let matches = activeSearchMatches()
        guard !matches.isEmpty else { return }
        let index = wrappedSearchMatchIndex(rawIndex, count: matches.count)
        searchMatchIndex = index
        let match = matches[index]
        if state.activeFrame.spatialLens == .timeline {
            guard focusTimelineSearchMatch(match) else { return }
            searchWarpNavigationActive = true
            return
        }
        if state.activeFrame.spatialLens == .projects {
            guard focusProjectsSearchMatch(match) else { return }
            searchWarpNavigationActive = true
            return
        }
        if state.activeFrame.spatialLens == .frontPage {
            guard focusFrontPageSearchMatch(match) else { return }
            searchWarpNavigationActive = true
            return
        }
        guard Self.usesMetalScene(state.activeFrame) else { return }
        let fallbackRecord = searchResultRecord(for: match.vectorId)
        await ensureSearchWarpTargetRendered(match: match, fallbackRecord: fallbackRecord)
        guard let target = searchWarpTargetPosition(match: match, fallbackRecord: fallbackRecord) else { return }
        searchWarpNavigationActive = true
        focusSearchMatchHoverIfNeeded(
            match: match,
            fallbackRecord: fallbackRecord,
            worldPosition: target
        )
        reframeCameraToSearchMatch(target: target, match: match, fallbackRecord: fallbackRecord)
    }

    @MainActor
    private func requestSearchMatchReframe(_ rawIndex: Int) {
        Task {
            await reframeSearchMatch(rawIndex)
        }
    }

    @MainActor
    private func reframeSearchMatch(_ rawIndex: Int) async {
        let matches = activeSearchMatches()
        guard !matches.isEmpty else { return }
        let index = wrappedSearchMatchIndex(rawIndex, count: matches.count)
        searchMatchIndex = index
        guard Self.usesMetalScene(state.activeFrame) else { return }
        let match = matches[index]
        let fallbackRecord = searchResultRecord(for: match.vectorId)
        await ensureSearchWarpTargetRendered(match: match, fallbackRecord: fallbackRecord)
        guard searchMatchIndex == index else { return }
        guard let target = searchWarpTargetPosition(match: match, fallbackRecord: fallbackRecord) else { return }
        focusSearchMatchHoverIfNeeded(
            match: match,
            fallbackRecord: fallbackRecord,
            worldPosition: target
        )
        reframeCameraToSearchMatch(target: target, match: match, fallbackRecord: fallbackRecord)
    }

    @MainActor
    private func reframeCameraToSearchMatch(
        target: SIMD3<Float>,
        match: LexicalSearchResult.Match,
        fallbackRecord: VectorRecord?
    ) {
        let cameraPosition = cameraController.state.position
        let delta = target - cameraPosition
        let direction = simd_length(delta) > 0.001
            ? simd_normalize(delta)
            : SIMD3<Float>(0, 0, -1)
        let standoff = searchMatchCameraStandoff(
            target: target,
            match: match,
            fallbackRecord: fallbackRecord
        )
        warpAnimator.engage(to: target - direction * standoff, lookAt: target)
        let hoverTarget = ProjectedHoverTarget.searchMatch(match.vectorId, target)
        warpAnimator.onComplete = { [vectorId = match.vectorId, fallbackRecord, target, hoverTarget] in
            guard shouldShowEmailHoverPaneInCurrentLens,
                  projectedHoverTarget == hoverTarget else { return }
            if updateProjectedHoverAnchor(
                vectorId: vectorId,
                fallbackRecord: fallbackRecord,
                worldOverride: target
            ) {
                state.hoveredVectorId = vectorId
            }
        }
    }

    @MainActor
    private func searchMatchCameraStandoff(
        target: SIMD3<Float>,
        match: LexicalSearchResult.Match,
        fallbackRecord: VectorRecord?
    ) -> Float {
        let profile = ConstellationCameraFraming.layerProfile(for: state.activeFrame)
        let base = profile.minDistance
        guard state.activeFrame.spatialLens == .people else {
            return base
        }
        let messageId = fallbackRecord?.messageId ?? match.messageId
        let matchingHubs = renderPacket.personHubs.filter { $0.messageIds.contains(messageId) }
        guard let hub = matchingHubs.min(by: {
            simd_length_squared($0.position - target) < simd_length_squared($1.position - target)
        }) else {
            return base
        }

        let ringExtent = max(hub.radius, hub.maxRingRadius)
        let nodeOffset = simd_distance(hub.position, target)
        let contextualRadius = max(ringExtent * 0.55, nodeOffset * 0.35, 0.12)
        let fitDistance = contextualRadius / (ConstellationCameraFraming.tanHalfVerticalFOV * 0.68)
        return min(max(base, fitDistance), 2.4)
    }

    @MainActor
    private func requestSearchMatchStepReframe(direction: Int) -> Bool {
        if activeFrameSupportsNonMetalSearchNavigation {
            return focusSearchMatchInActiveNonMetalLens(
                startingAt: searchMatchIndex + direction,
                direction: direction
            )
        }
        let matches = activeSearchMatches()
        guard matches.count > 1 else { return false }
        let nextIndex = wrappedSearchMatchIndex(searchMatchIndex + direction, count: matches.count)
        requestSearchMatchReframe(nextIndex)
        return true
    }

    @MainActor
    private func handleSearchMatchNavigationKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        // Delete key: bare ⌫ deletes the active lens's selection with the
        // confirmation alert; ⌘⌫ deletes immediately. ⌥/⌃/⇧ combos fall
        // through untouched. The catcher lets the Search field's keys reach us
        // for navigation, so we bail when any text input is focused — plain ⌫
        // there must backspace the query, not delete a node.
        if keyCode == Self.deleteKeyCode {
            let blocked: NSEvent.ModifierFlags = [.option, .control, .shift]
            guard flags.intersection(blocked).isEmpty else { return false }
            guard !isTextInputResponderFocused() else { return false }
            let confirm = !flags.contains(.command)
            // A locked scene node always wins; the Withheld (Junk/Trash) drawer
            // handles Delete only when it is open with a selection and no node
            // is locked.
            if deleteSelectedSceneMessage(confirm: confirm) { return true }
            return deleteSelectedWithheldRowsIfDrawerActive(confirm: confirm)
        }
        let returnKey = keyCode == Self.returnKeyCode || keyCode == Self.keypadEnterKeyCode
        let commandReturn = returnKey && flags.contains(.command)
        if commandReturn {
            let blockedFlags: NSEvent.ModifierFlags = [.shift, .option, .control]
            guard flags.intersection(blockedFlags).isEmpty else { return false }
            guard state.lockedVectorId == nil,
                  searchWarpSupportedInActiveFrame else {
                return false
            }
            requestSearchMatchWarp(searchMatchIndex)
            return true
        }

        if let direction = Self.searchMatchArrowStepDirection(
            keyCode: keyCode,
            modifiers: flags
        ) {
            guard !activeSearchMatches().isEmpty else { return false }
            selectSearchMatch(searchMatchIndex + direction)
            return true
        }

        let commandG = keyCode == Self.gKeyCode && flags.contains(.command)
        let tab = keyCode == Self.tabKeyCode && !flags.contains(.command)
        guard commandG || tab else { return false }
        let blockedFlags: NSEvent.ModifierFlags = [.option, .control]
        guard flags.intersection(blockedFlags).isEmpty else { return false }
        guard state.lockedVectorId == nil,
              (searchWarpNavigationActive || shouldBeginNonMetalSearchNavigationWithTab(tab: tab)) else {
            return false
        }
        let direction = flags.contains(.shift) ? -1 : 1
        if !searchWarpNavigationActive, activeFrameSupportsNonMetalSearchNavigation {
            searchWarpNavigationActive = true
            guard focusSearchMatchInActiveNonMetalLens(
                startingAt: searchMatchIndex + direction,
                direction: direction
            ) else {
                searchWarpNavigationActive = false
                return false
            }
            return true
        }
        return requestSearchMatchStepReframe(direction: direction)
    }

    nonisolated static func searchMatchArrowStepDirection(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Int? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return nil }
        let blockedFlags: NSEvent.ModifierFlags = [.shift, .option, .control]
        guard flags.intersection(blockedFlags).isEmpty else { return nil }

        switch keyCode {
        case leftArrowKeyCode:
            return -1
        case rightArrowKeyCode:
            return 1
        default:
            return nil
        }
    }

    @MainActor
    private var searchWarpSupportedInActiveFrame: Bool {
        Self.usesMetalScene(state.activeFrame)
            || state.activeFrame.spatialLens == .timeline
            || state.activeFrame.spatialLens == .projects
            || state.activeFrame.spatialLens == .frontPage
    }

    @MainActor
    private var activeFrameSupportsNonMetalSearchNavigation: Bool {
        state.activeFrame.spatialLens == .timeline
            || state.activeFrame.spatialLens == .projects
            || state.activeFrame.spatialLens == .frontPage
    }

    @MainActor
    private func shouldBeginNonMetalSearchNavigationWithTab(tab: Bool) -> Bool {
        tab
            && activeFrameSupportsNonMetalSearchNavigation
            && !activeSearchMatches().isEmpty
    }

    @MainActor
    private func focusSearchMatchInActiveNonMetalLens(startingAt rawIndex: Int, direction: Int) -> Bool {
        let matches = activeSearchMatches()
        guard !matches.isEmpty else { return false }
        let step = direction < 0 ? -1 : 1
        var index = wrappedSearchMatchIndex(rawIndex, count: matches.count)
        for _ in 0..<matches.count {
            if focusSearchMatchInActiveNonMetalLens(matches[index]) {
                searchMatchIndex = index
                return true
            }
            index = wrappedSearchMatchIndex(index + step, count: matches.count)
        }
        return false
    }

    @MainActor
    private func focusSearchMatchInActiveNonMetalLens(_ match: LexicalSearchResult.Match) -> Bool {
        switch state.activeFrame.spatialLens {
        case .timeline:
            return focusTimelineSearchMatch(match)
        case .projects:
            return focusProjectsSearchMatch(match)
        case .frontPage:
            return focusFrontPageSearchMatch(match)
        default:
            return false
        }
    }

    @MainActor
    private func focusTimelineSearchMatch(_ match: LexicalSearchResult.Match) -> Bool {
        guard state.activeFrame.spatialLens == .timeline,
              let timelineWorkspace,
              let messageID = UUID(uuidString: match.messageId) else {
            return false
        }
        let fallbackDate = match.receivedAt.map { Date(timeIntervalSince1970: $0) }
        return timelineWorkspace.focusMessage(
            messageID,
            date: fallbackDate,
            maximumViewportSpan: Self.timelineSearchWarpViewportSpan,
            searchHighlight: searchMatchHighlight(for: match, messageID: messageID)
        )
    }

    @MainActor
    private func focusProjectsSearchMatch(_ match: LexicalSearchResult.Match) -> Bool {
        guard state.activeFrame.spatialLens == .projects,
              let workspace = projectsWorkspace,
              let snapshot = workspace.currentSnapshot,
              ProjectsDataController.signatureMatchesCurrentFilter(
                snapshot: snapshot,
                filter: state.filter
              ),
              let messageID = UUID(uuidString: match.messageId) else {
            return false
        }
        guard snapshot.row(
            containing: messageID,
            preferredProjectKey: workspace.focusedProjectKey
        ) != nil else {
            return false
        }
        return workspace.openLinksForMessage(messageID, in: snapshot)
    }

    @MainActor
    private func focusFrontPageSearchMatch(_ match: LexicalSearchResult.Match) -> Bool {
        guard state.activeFrame.spatialLens == .frontPage,
              let workspace = frontPageWorkspace,
              let snapshot = workspace.currentSnapshot,
              FrontPageDataController.signatureMatchesCurrentFilter(
                snapshot: snapshot,
                filter: state.filter,
                selectedTimeRange: state.selectedTimeRange,
                unreadOnly: workspace.unreadOnly
              ),
              let messageID = UUID(uuidString: match.messageId) else {
            return false
        }
        return frontPageData.focusSearchMatch(
            messageID: messageID,
            in: snapshot,
            searchHighlight: searchMatchHighlight(for: match, messageID: messageID)
        )
    }

    @MainActor
    private func searchMatchHighlight(
        for match: LexicalSearchResult.Match,
        messageID: UUID
    ) -> SearchMatchHighlight? {
        guard let result = lexicalResult,
              let lane = searchHighlightLane(for: match, result: result) else {
            return nil
        }

        switch lane {
        case .exact:
            return SearchMatchHighlight(
                messageID: messageID,
                phrases: Self.exactSearchHighlightPhrases(from: result)
            )
        case .semantic:
            guard let semanticCue = match.semanticCue else { return nil }
            return SearchMatchHighlight(messageID: messageID, phrases: [semanticCue])
        }
    }

    @MainActor
    private func searchHighlightLane(
        for match: LexicalSearchResult.Match,
        result: LexicalSearchResult
    ) -> LexicalSearchLane? {
        if let selectedSearchLane,
           result.matches(for: selectedSearchLane).contains(match) {
            return selectedSearchLane
        }
        if result.semanticMatches.contains(match) {
            return .semantic
        }
        if result.exactMatches.contains(match) {
            return .exact
        }
        return nil
    }

    private static func exactSearchHighlightPhrases(from result: LexicalSearchResult) -> [String] {
        if result.isPhrase {
            return [unquotedSearchHighlightPhrase(result.query)]
        }
        let terms = result.terms.map(\.term)
        return terms.isEmpty ? [unquotedSearchHighlightPhrase(result.query)] : terms
    }

    private static func unquotedSearchHighlightPhrase(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.hasPrefix("\""),
              trimmed.hasSuffix("\"") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func focusSearchMatchHoverIfNeeded(
        match: LexicalSearchResult.Match,
        fallbackRecord: VectorRecord?,
        worldPosition: SIMD3<Float>
    ) {
        guard Self.usesMetalScene(state.activeFrame) else { return }
        guard !clearEmailHoverPaneIfSuppressed() else { return }
        projectedHoverTarget = .searchMatch(match.vectorId, worldPosition)
        hoveredPersonEmail = nil
        setHoveredMeaningCluster(nil)
        if updateProjectedHoverAnchor(
            vectorId: match.vectorId,
            fallbackRecord: fallbackRecord,
            worldOverride: worldPosition
        ) {
            state.hoveredVectorId = match.vectorId
        } else {
            state.hoveredVectorId = nil
        }
    }

    @MainActor
    private func clearSearchWarpNavigation() {
        searchWarpNavigationActive = false
        if case .searchMatch(let active, _) = projectedHoverTarget {
            if state.hoveredVectorId == active {
                state.hoveredVectorId = nil
            }
            projectedHoverTarget = nil
        }
    }

    private func wrappedSearchMatchIndex(_ rawIndex: Int, count: Int) -> Int {
        ((rawIndex % count) + count) % count
    }

    @MainActor
    private func searchResultRecord(for vectorId: Int64) -> VectorRecord? {
        if let cached = searchResultRecordCache[vectorId] {
            return cached
        }
        guard let record = (try? services.vectorStore.hydrate(vectorIds: [vectorId]))?.first else {
            return nil
        }
        searchResultRecordCache[vectorId] = record
        return record
    }

    @MainActor
    private func ensureSearchWarpTargetRendered(
        match: LexicalSearchResult.Match,
        fallbackRecord: VectorRecord?
    ) async {
        guard renderedSearchWarpTargetPosition(match: match, fallbackRecord: fallbackRecord) == nil else {
            return
        }
        await refreshSceneData()
        guard renderedSearchWarpTargetPosition(match: match, fallbackRecord: fallbackRecord) == nil else {
            return
        }
        for _ in 0..<12 {
            guard renderRefreshInFlight else { return }
            try? await Task.sleep(for: .milliseconds(50))
            if renderedSearchWarpTargetPosition(match: match, fallbackRecord: fallbackRecord) != nil {
                return
            }
        }
    }

    @MainActor
    private func searchWarpTargetPosition(
        match: LexicalSearchResult.Match,
        fallbackRecord: VectorRecord?
    ) -> SIMD3<Float>? {
        renderedSearchWarpTargetPosition(match: match, fallbackRecord: fallbackRecord)
            ?? frameAwarePosition(vectorId: match.vectorId, fallbackRecord: fallbackRecord)
    }

    @MainActor
    private func renderedSearchWarpTargetPosition(
        match: LexicalSearchResult.Match,
        fallbackRecord: VectorRecord?
    ) -> SIMD3<Float>? {
        guard renderPacketFrame.spatialLens == state.activeFrame.spatialLens else {
            return nil
        }
        let messageId = fallbackRecord?.messageId ?? match.messageId
        return renderPacket.stars.first(where: { $0.messageId == messageId })?.position
            ?? renderPacket.hitProxies.first(where: { $0.messageId == messageId })?.worldPosition
            ?? renderPacket.satellites.first(where: { $0.vectorId == match.vectorId })?.position
            ?? renderPacket.hitProxies.first(where: { $0.vectorId == match.vectorId })?.worldPosition
            ?? renderPacket.stars.first(where: { $0.representativeVectorId == match.vectorId })?.position
    }

    /// Assemble the Search-tab view model from the last literal result, adding
    /// cluster labels and sender display names from the app-layer snapshot.
    private func searchModel() -> ConstellationSearchModel {
        guard let result = lexicalResult else { return .empty }
        let currentSearchQuery = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let semanticSearchPending = semanticSearchPendingQuery == result.query
            && currentSearchQuery == result.query
        // Only Meaning has cluster membership; other lenses show no label.
        let vToC: [Int64: Int64] = state.activeFrame.spatialLens == .meaning
            ? (try? services.vectorClusterStore.vectorToCluster(frame: state.activeFrame)) ?? [:]
            : [:]
        let clusterById: [Int64: ClusterRecord] = Dictionary(
            uniqueKeysWithValues: clusters.map { ($0.id, $0) }
        )
        let messageIndex = snapshotCache.snapshot(
            for: state.activeFrame,
            maxAge: .greatestFiniteMagnitude
        )?.messageIndex ?? [:]

        func clusterLabel(forVectorId vectorId: Int64) -> String? {
            guard let cid = vToC[vectorId], let cluster = clusterById[cid] else { return nil }
            return cluster.label
        }
        func senderDisplay(messageId: String, email: String) -> String {
            if let row = messageIndex[messageId], let name = row.fromName, !name.isEmpty {
                return name
            }
            return email
        }
        func displayMatch(_ match: LexicalSearchResult.Match, lane: LexicalSearchLane) -> ConstellationSearchModel.Match {
            let fieldsLabel: String
            if lane == .semantic {
                fieldsLabel = Self.semanticFieldsLabel(cue: match.semanticCue)
            } else {
                let matchedFields = Self.matchedFieldsLabel(
                    subject: match.matchedSubject,
                    body: match.matchedBody,
                    sender: match.matchedSender,
                    attachment: match.matchedAttachment
                )
                fieldsLabel = "matched in \(matchedFields)"
            }
            return ConstellationSearchModel.Match(
                vectorId: match.vectorId,
                fieldsLabel: fieldsLabel,
                subjectLine: match.subject,
                attachmentFilenames: match.matchedAttachmentFilenames,
                attachmentEvidenceLabel: Self.attachmentEvidenceLabel(
                    descriptors: match.matchedAttachmentDescriptors,
                    filenames: match.matchedAttachmentFilenames
                ),
                attachmentSnippet: match.matchedAttachmentDescriptors.first?.snippet,
                sender: senderDisplay(messageId: match.messageId, email: match.senderEmail),
                dateLabel: Self.searchDateLabel(match.receivedAt),
                clusterLabel: clusterLabel(forVectorId: match.vectorId)
            )
        }
        let exactMatches = result.exactMatches.map { displayMatch($0, lane: .exact) }
        let semanticMatches = result.semanticMatches.map { displayMatch($0, lane: .semantic) }
        let matches = selectedSearchLane == .semantic ? semanticMatches : exactMatches

        let dates = result.exactMatches.compactMap { match -> Date? in
            guard let ts = match.receivedAt else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
        let span: ClosedRange<Date>? = {
            guard let lo = dates.min(), let hi = dates.max() else { return nil }
            return lo...hi
        }()

        var clusterCounts: [Int64: Int] = [:]
        for match in result.exactMatches {
            guard let cid = vToC[match.vectorId] else { continue }
            clusterCounts[cid, default: 0] += 1
        }
        let topCluster: ConstellationSearchModel.LabeledCount? = {
            guard let (cid, count) = clusterCounts.max(by: { $0.value < $1.value }),
                  let label = clusterById[cid]?.label else { return nil }
            return .init(label: label, count: count)
        }()

        var senderCounts: [String: Int] = [:]
        for match in result.exactMatches {
            let display = senderDisplay(messageId: match.messageId, email: match.senderEmail)
            guard !display.isEmpty else { continue }
            senderCounts[display, default: 0] += 1
        }
        let topSender: ConstellationSearchModel.LabeledCount? = senderCounts
            .max(by: { $0.value < $1.value })
            .map { .init(label: $0.key, count: $0.value) }

        return ConstellationSearchModel(
            query: result.query,
            hasQuery: !result.query.isEmpty,
            isPhrase: result.isPhrase,
            selectedLane: selectedSearchLane,
            exactCount: result.exactTotalCount,
            exactMatchCount: result.exactMatches.count,
            semanticCount: result.semanticMatches.count,
            semanticLaneAvailable: result.semanticLaneAvailable,
            semanticSearchPending: semanticSearchPending,
            topSemanticScore: result.topSemanticScore,
            weakSemantic: result.weakSemantic,
            terms: result.terms.map { .init(label: $0.term, count: $0.count) },
            phrase: result.phrase.map { .init(label: $0.term, count: $0.count) },
            fieldSubject: result.fieldSubject,
            fieldBody: result.fieldBody,
            fieldSender: result.fieldSender,
            fieldAttachment: result.fieldAttachment,
            span: span,
            topCluster: topCluster,
            topSender: topSender,
            activeTotalCount: selectedSearchLane == .semantic ? result.semanticMatches.count : result.exactTotalCount,
            matches: matches
        )
    }

    private static func semanticFieldsLabel(
        cue: String?
    ) -> String {
        let cleanedCue = cue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var label = "nearby meaning"
        if let cleanedCue, !cleanedCue.isEmpty {
            label += " · \(cleanedCue)"
        }
        return label
    }

    private static func matchedFieldsLabel(subject: Bool, body: Bool, sender: Bool, attachment: Bool) -> String {
        var parts: [String] = []
        if subject { parts.append("subject") }
        if body { parts.append("body") }
        if sender { parts.append("sender") }
        if attachment { parts.append("attachment") }
        return parts.isEmpty ? "text" : parts.joined(separator: " + ")
    }

    private static func attachmentEvidenceLabel(
        descriptors: [LexicalSearchResult.Match.AttachmentDescriptor],
        filenames: [String]
    ) -> String {
        guard let first = descriptors.first else {
            let visible = filenames.prefix(2).joined(separator: ", ")
            let extra = filenames.count - 2
            guard extra > 0 else { return visible }
            return "\(visible) +\(extra)"
        }
        let filename = first.filename.isEmpty ? "attachment" : first.filename
        let suffix = descriptors.count > 1 ? " +\(descriptors.count - 1)" : ""
        return "\(first.provenanceLabel): \(filename)\(suffix)"
    }

    private static let searchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static func searchDateLabel(_ receivedAt: TimeInterval?) -> String {
        guard let receivedAt else { return "undated" }
        return searchDateFormatter.string(from: Date(timeIntervalSince1970: receivedAt))
    }

    @MainActor
    private var focusedRetrievalScopeKind: FocusedRetrievalScopePolicy.Kind? {
        let lens = state.activeFrame.spatialLens
        let hasMetalFocus = lens == .people
            ? liveLockPersonFocus != nil
            : state.lockedVectorId != nil
        return FocusedRetrievalScopePolicy.kind(
            for: state.activeFrame,
            hasMetalFocus: hasMetalFocus,
            hasFrontPageFocus: frontPageWorkspace?.focusedArticleID != nil,
            hasTimelineFocus: timelineWorkspace?.playheadMessageID != nil,
            hasProjectFocus: projectsWorkspace?.focusedProjectKey != nil
        )
    }

    @MainActor
    private var focusedThreadCenterMessageID: UUID? {
        switch state.activeFrame.spatialLens {
        case .frontPage:
            return frontPageWorkspace?.focusedArticleID
        case .timeline:
            return timelineWorkspace?.playheadMessageID
        case .meaning:
            guard let vectorID = state.lockedVectorId,
                  let record = visibleRecordCache[vectorID]
                    ?? citationSourceRecord(vectorId: vectorID) else {
                return nil
            }
            return UUID(uuidString: record.messageId)
        default:
            return nil
        }
    }

    @MainActor
    private func focusedRetrievalFilterSpec() async -> FilterSpec? {
        guard let scopeKind = focusedRetrievalScopeKind else { return nil }

        let messageIDs: Set<String>
        switch scopeKind {
        case .thread:
            guard let centerMessageID = focusedThreadCenterMessageID else {
                messageIDs = []
                break
            }
            messageIDs = await focusedThreadMessageIDs(centerMessageID: centerMessageID)
        case .correspondent:
            guard let correspondent = liveLockPersonFocus?.email else {
                messageIDs = []
                break
            }
            let snapshot = await constellationSnapshot(for: state.activeFrame)
            messageIDs = PeopleRingMessageScope.scopedMessageIds(
                involving: correspondent,
                filter: VectorFilter(),
                messageIndex: snapshot.messageIndex,
                userAddresses: userAddressSet
            )
        case .project:
            guard let workspace = projectsWorkspace,
                  let projectKey = workspace.focusedProjectKey else {
                messageIDs = []
                break
            }
            messageIDs = await focusedProjectMessageIDs(
                projectKey: projectKey,
                workspace: workspace
            )
        }

        return FocusedRetrievalScopePolicy.filterSpec(
            messageIDs: messageIDs,
            collections: VectorCollectionVisibilityPreferences.collections()
        )
    }

    @MainActor
    private func focusedThreadMessageIDs(centerMessageID: UUID) async -> Set<String> {
        let container = modelContext.container
        return await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let thread = FrontPageDataController.threadContext(
                for: centerMessageID,
                modelContext: context
            )
            var ids = Set(thread.messages.map { $0.id.uuidString })
            ids.insert(centerMessageID.uuidString)
            return ids
        }.value
    }

    @MainActor
    private func focusedProjectMessageIDs(
        projectKey: String,
        workspace: ProjectsWorkspaceState
    ) async -> Set<String> {
        Set(
            workspace.currentSnapshot?
                .projectDefinitionRow(for: projectKey)?
                .messageIDs
                .map(\.uuidString) ?? []
        )
    }

    /// Focused Search uses the lens-specific hard message boundary above.
    /// Outside a focused surface it keeps the constellation's existing filter
    /// semantics and can warp to any match in that constellation scope.
    private func searchFilterSpec() async -> FilterSpec {
        if let focused = await focusedRetrievalFilterSpec() {
            return focused
        }
        var filter = ConstellationFilterResolver.effectiveSceneFilter(
            baseFilter: state.filter,
            selectedTimeRange: state.selectedTimeRange
        )
        if state.activeFrame.spatialLens == .timeline, let workspace = timelineWorkspace {
            filter = TimelineFilterIntersection.intersect(
                filter: filter,
                viewportRange: workspace.viewportRange,
                bracketedRange: workspace.bracketedRange
            )
            let allowedMessageIds = timelineAllowedMessageIdsForAsk(
                workspace: workspace,
                filter: filter
            )
            return filterSpec(from: filter, allowedMessageIds: allowedMessageIds)
        }
        if state.activeFrame.spatialLens == .projects, let workspace = projectsWorkspace {
            let allowedMessageIds = projectsAllowedMessageIdsForRetrieval(
                workspace: workspace,
                filter: state.filter
            )
            return filterSpec(from: filter, allowedMessageIds: allowedMessageIds)
        }
        if filter.collections.isEmpty {
            return filterSpec(from: filter, allowedMessageIds: [])
        }
        let snapshot = await constellationSnapshot(for: state.activeFrame)
        let allowedMessageIds = await allowedMessageIdsForRetrieval(
            filter: filter,
            snapshot: snapshot
        )
        return filterSpec(from: filter, allowedMessageIds: allowedMessageIds)
    }

    nonisolated private static func buildCorrespondentSuggestions(
        scopes: Set<CorrespondentScope>,
        accountIds: Set<UUID>?,
        messageIndex: [String: MessageFilterRow]
    ) -> [CorrespondentFilterSuggestion] {
        if accountIds?.isEmpty == true || scopes.isEmpty { return [] }

        var accumulators: [String: CorrespondentSuggestionAccumulator] = [:]
        for row in messageIndex.values {
            if let accountIds {
                guard let accountId = row.accountId, accountIds.contains(accountId) else { continue }
            }

            if scopes.contains(.from) {
                observePerson(
                    address: row.fromAddress,
                    displayName: row.fromName,
                    date: row.receivedAt,
                    accumulators: &accumulators
                )
            }
            if scopes.contains(.to) {
                for (index, address) in row.toAddresses.enumerated() {
                    let displayName = row.toDisplayNames.indices.contains(index)
                        ? row.toDisplayNames[index]
                        : nil
                    observePerson(
                        address: address,
                        displayName: displayName,
                        date: row.receivedAt,
                        accumulators: &accumulators
                    )
                }
            }
            if scopes.contains(.cc) {
                for (index, address) in row.ccAddresses.enumerated() {
                    let displayName = row.ccDisplayNames.indices.contains(index)
                        ? row.ccDisplayNames[index]
                        : nil
                    observePerson(
                        address: address,
                        displayName: displayName,
                        date: row.receivedAt,
                        accumulators: &accumulators
                    )
                }
            }
            if scopes.contains(.bcc) {
                for (index, address) in row.bccAddresses.enumerated() {
                    let displayName = row.bccDisplayNames.indices.contains(index)
                        ? row.bccDisplayNames[index]
                        : nil
                    observePerson(
                        address: address,
                        displayName: displayName,
                        date: row.receivedAt,
                        accumulators: &accumulators
                    )
                }
            }
        }

        return accumulators.values
            .map(\.suggestion)
            .sorted { lhs, rhs in
                if lhs.frequency != rhs.frequency { return lhs.frequency > rhs.frequency }
                let leftSeen = lhs.lastSeen?.timeIntervalSinceReferenceDate ?? 0
                let rightSeen = rhs.lastSeen?.timeIntervalSinceReferenceDate ?? 0
                if leftSeen != rightSeen { return leftSeen > rightSeen }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    nonisolated private static func observePerson(
        address: String,
        displayName: String?,
        date: Date?,
        accumulators: inout [String: CorrespondentSuggestionAccumulator]
    ) {
        let email = address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !email.isEmpty else { return }

        let cleanName = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleanName?.isEmpty == false ? cleanName! : email
        let subtitle = title.normalizedForCorrespondentAutocomplete == email.normalizedForCorrespondentAutocomplete
            ? nil
            : email

        accumulators[email, default: CorrespondentSuggestionAccumulator(
            value: email,
            title: title,
            subtitle: subtitle
        )]
        .observe(title: title, subtitle: subtitle, date: date)
    }

    @MainActor
    private func refreshIfPlacementObservationChanged() async {
        guard state.selectedTimeRange.refreshesOnNewPlacements || onboardingMode else { return }
        let frame = state.activeFrame
        guard let placement = await Self.loadPlacementObservation(from: services.vectorStore),
              !Task.isCancelled, frame == state.activeFrame else { return }
        let observation = PlacementObservation(total: placement.total, placed: placement.placed)
        guard observation != lastObservedPlacement else { return }
        guard observation.placed > 0 || !renderPacket.stars.isEmpty else { return }
        if await refreshSceneAfterVectorPlacement(updateObservedPlacement: false) {
            lastObservedPlacement = observation
        }
    }

    @MainActor
    @discardableResult
    private func refreshSceneAfterVectorPlacement(updateObservedPlacement: Bool = true) async -> Bool {
        if shouldDeferPlacementSceneRefresh() { return false }
        let frame = state.activeFrame
        if updateObservedPlacement,
           let placement = await Self.loadPlacementObservation(from: services.vectorStore) {
            guard !Task.isCancelled, frame == state.activeFrame else { return false }
            lastObservedPlacement = PlacementObservation(total: placement.total, placed: placement.placed)
        }
        guard !Task.isCancelled, frame == state.activeFrame else { return false }
        // Placement changes can introduce the first row for a newly-filtered
        // account. Bypass the short-lived snapshot cache so the active account
        // filter sees those rows immediately rather than after a lens switch.
        await refreshSceneData(updateColorLookup: true)
        return true
    }

    @concurrent
    private static func loadPlacementObservation(from store: VectorStore) async -> PlacementObservation? {
        guard !Task.isCancelled, let counts = try? store.placementCounts(), !Task.isCancelled else { return nil }
        return PlacementObservation(total: counts.total, placed: counts.placed)
    }

    @MainActor
    private func applyShowEntitiesPreference() {
        applyVectorCollectionPreferences()
    }

    /// 4-bit fingerprint over the vector-collection AppStorage prefs.
    /// Drives the single `.onChange` observer that bridges them into
    /// `state.filter.collections`; folding four Bools into one Int avoids
    /// blowing SwiftUI's body type-check budget with four chained
    /// `.onChange` modifiers.
    private var vectorCollectionPrefsFingerprint: Int {
        (showEntitiesPref   ? 1 : 0)
        | (showContextPref    ? 2 : 0)
        | (showAttachmentPref ? 4 : 0)
        | (showStylePref      ? 8 : 0)
    }

    private var scenePreferenceObservationKey: ConstellationScenePreferenceObservationKey {
        ConstellationScenePreferenceObservationKey(
            vectorCollectionPrefsFingerprint: vectorCollectionPrefsFingerprint,
            peopleFocusExpandsToOneHop: peopleFocusExpandsToOneHop
        )
    }

    @MainActor
    private func handleScenePreferenceChange(
        previous: ConstellationScenePreferenceObservationKey,
        current: ConstellationScenePreferenceObservationKey
    ) {
        if previous.vectorCollectionPrefsFingerprint != current.vectorCollectionPrefsFingerprint {
            applyVectorCollectionPreferences()
        }
        if previous.peopleFocusExpandsToOneHop != current.peopleFocusExpandsToOneHop {
            handlePeopleVoicesNetworkChange()
        }
    }

    /// Bridge the four `constellationVector*` AppStorage keys (driven by
    /// the Developer Settings "Constellation Layers" section) into
    /// `state.filter.collections`. Replaces the retired toolbar Layers
    /// section — render-time visibility for the four vector kinds is
    /// now a developer-surface concern, not a primary content filter.
    @MainActor
    private func applyVectorCollectionPreferences() {
        var collections: Set<VectorCollection> = []
        if showEntitiesPref { collections.insert(.entity) }
        if showContextPref { collections.insert(.context) }
        if showAttachmentPref { collections.insert(.attachment) }
        if showStylePref { collections.insert(.style) }
        state.filter.collections = collections
    }

    @MainActor
    private func handlePeopleVoicesNetworkChange() {
        retainedMetalSurfaces.removeAll()
        guard state.activeFrame.spatialLens == .people,
              peopleFrameFocus(frame: state.activeFrame, filter: state.filter) != nil else {
            return
        }
        armFilterCameraResetIfNeeded()
        beginSceneRenderProgress(.filter)
        Task { await refreshSceneData(updateColorLookup: true) }
    }

    private var configuredMeaningClusterDisplayLimit: Int {
        ClusterDetectPayload.clampedMeaningTargetClusters(Int(meaningClusterDisplayCount.rounded()))
    }

    private var meaningClusterDisplayLimit: Int {
        Self.meaningClusterEffectiveDisplayLimit(
            configuredLimit: configuredMeaningClusterDisplayLimit,
            availableClusterCount: scopedMeaningClusterAvailableCount
        )
    }

    private var meaningClusterDisplayBinding: Binding<Double> {
        Binding(
            get: {
                scopedMeaningClusterAvailableCount == nil
                    ? 0
                    : Double(meaningClusterDisplayLimit)
            },
            set: { newValue in
                meaningClusterDisplayCount = Double(
                    ClusterDetectPayload.clampedMeaningTargetClusters(Int(newValue.rounded()))
                )
            }
        )
    }

    /// Clamp the user's display request to the render-eligible clusters in the
    /// current Moments/filter scope. Before the first scoped packet arrives,
    /// retain the configured request so the initial Meaning render can bootstrap.
    nonisolated static func meaningClusterEffectiveDisplayLimit(
        configuredLimit: Int,
        availableClusterCount: Int?
    ) -> Int {
        let configured = ClusterDetectPayload.clampedMeaningTargetClusters(configuredLimit)
        guard let availableClusterCount else { return configured }
        return min(configured, max(0, availableClusterCount))
    }

    /// Counts semantic clusters that the planner can render for the already
    /// selected stars. This deliberately mirrors the planner's two support
    /// floors without running its medoid/ranking work: one O(n) pass is cached
    /// at packet installation, never in the draw loop.
    nonisolated static func meaningClusterAvailableCount(
        clusters: [ClusterRecord],
        visibleStars: [MessageStarInstance],
        messageIndex: [String: MessageFilterRow]
    ) -> Int {
        let minimumStoredMembers = 4
        let minimumVisibleMembers = 4
        guard visibleStars.count >= minimumVisibleMembers else { return 0 }

        let dynamicVisibleFloor = max(
            minimumVisibleMembers,
            min(12, Int(ceil(Double(visibleStars.count) * 0.0025)))
        )
        let eligibleClusterIds = Set(
            clusters.lazy
                .filter { $0.memberCount >= minimumStoredMembers }
                .map(\.id)
        )
        guard !eligibleClusterIds.isEmpty else { return 0 }

        var visibleCountByCluster: [Int64: Int] = [:]
        visibleCountByCluster.reserveCapacity(eligibleClusterIds.count)
        for star in visibleStars {
            guard let clusterId = messageIndex[star.messageId]?.clusterId,
                  eligibleClusterIds.contains(clusterId) else {
                continue
            }
            visibleCountByCluster[clusterId, default: 0] += 1
        }
        return visibleCountByCluster.values.reduce(into: 0) { count, visibleMembers in
            if visibleMembers >= dynamicVisibleFloor {
                count += 1
            }
        }
    }

    private var effectiveMeaningClusterDisplayCount: Int {
        onboardingMode
            ? ClusterDetectPayload.onboardingMeaningTargetClusters
            : meaningClusterDisplayLimit
    }

    /// Clusters stay in the packet while a node lock is open — the planner
    /// stamps `meaningClusterVisibility = 0` on locked packets and the
    /// renderer fades the orbs continuously along the lock transition's
    /// source-warp ramp. Excluding them here (the pre-fade behavior) made
    /// every orb vanish in one frame at the first locked packet and pop
    /// back at the unlocked refresh after release.
    private func shouldRenderMeaningClusters(for frame: FrameKey) -> Bool {
        frame.spatialLens == .meaning
            && effectiveMeaningClusterDisplayCount > ClusterDetectPayload.noMeaningTargetClusters
            && meaningClusterPipelineStatus.isReadyForDisplay
    }

    private var meaningClusterObservationIsActive: Bool {
        state.activeFrame.spatialLens == .meaning
            && coldFirstPaintRequest == nil
    }

    private var meaningClusterRecoveryKey: MeaningClusterRecoveryKey {
        MeaningClusterRecoveryKey(
            activeFrame: state.activeFrame.spatialLens,
            renderPacketFrame: renderPacketFrame.spatialLens,
            displayCount: effectiveMeaningClusterDisplayCount,
            visibleHubCount: renderPacket.meaningClusterHubs.count,
            cachedClusterCount: clusters.count,
            lockedVectorId: state.lockedVectorId,
            onboardingMode: onboardingMode,
            coldFirstPaintPending: coldFirstPaintRequest != nil
        )
    }

    private var meaningClusterStoreObservationKey: MeaningClusterStoreObservationKey {
        MeaningClusterStoreObservationKey(
            activeFrame: state.activeFrame.spatialLens,
            displayCount: effectiveMeaningClusterDisplayCount,
            lockedVectorId: state.lockedVectorId,
            onboardingMode: onboardingMode,
            coldFirstPaintPending: coldFirstPaintRequest != nil
        )
    }

    @MainActor
    private func shouldRefreshMeaningClustersBeforeRender(
        frame: FrameKey,
        shouldIncludeClusters: Bool
    ) -> Bool {
        guard shouldIncludeClusters, frame.spatialLens == .meaning, !onboardingMode else {
            return false
        }
        return clusters.isEmpty
            || renderPacketFrame.spatialLens != frame.spatialLens
            || renderPacket.meaningClusterHubs.isEmpty
    }

    @MainActor
    private func repairMissingMeaningClustersIfNeeded() async {
        guard coldFirstPaintRequest == nil,
              !meaningClusterDisplayRefreshInFlight,
              shouldRenderMeaningClusters(for: state.activeFrame),
              renderPacketFrame.spatialLens == state.activeFrame.spatialLens,
              renderPacket.meaningClusterHubs.isEmpty else {
            return
        }
        guard let storedClusters = displayClusters(
            for: state.activeFrame,
            context: "meaning cluster recovery"
        ) else {
            return
        }
        guard storedClusters.isEmpty == false else { return }

        meaningClusterDisplayRefreshInFlight = true
        defer {
            finishMeaningClusterDisplayRefresh()
        }

        await refreshClusterLabels(
            frame: state.activeFrame,
            forceSnapshotRefresh: true,
            refreshSceneOnGain: false
        )
        await refreshSceneData(frame: state.activeFrame)
    }

    @MainActor
    private func observeMeaningClusterStoreWhileActive() async {
        guard meaningClusterObservationIsActive, !onboardingMode else {
            return
        }

        await refreshMeaningClusterBackstopIfNeeded()

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard meaningClusterObservationIsActive, !onboardingMode else {
                return
            }
            await refreshMeaningClusterBackstopIfNeeded()
        }
    }

    @MainActor
    private func currentMeaningClusterPipelineStatus() -> MeaningClusterPipelineStatus {
        PipelineReadiness.meaningClusterStatus(
            context: modelContext,
            vectorStore: services.vectorStore,
            clusterStore: services.vectorClusterStore,
            messageStoreURL: services.messageStoreURL,
            currentEmbeddingVersion: services.embedderRegistry.current.embeddingVersion,
            initialImportWorkPending: PipelineReadiness.initialImportWorkIsPending(
                context: modelContext
            )
        )
    }

    nonisolated static func meaningClusterPublicationIdentity(
        frame: FrameKey,
        clusters: [ClusterRecord]
    ) -> MeaningClusterPublicationIdentity {
        MeaningClusterPublicationIdentity(frame: frame, clusters: clusters)
    }

    nonisolated static func meaningClusterPublicationNeedsRefresh(
        installed: MeaningClusterPublicationIdentity?,
        current: MeaningClusterPublicationIdentity,
        cachedClusterCount: Int
    ) -> Bool {
        installed != current || (current.clusterCount > 0 && cachedClusterCount == 0)
    }

    nonisolated static func meaningClusterBackstopRequiresPipelineRefresh(
        status: MeaningClusterPipelineStatus,
        installed: MeaningClusterPublicationIdentity?,
        current: MeaningClusterPublicationIdentity,
        cachedClusterCount: Int
    ) -> Bool {
        guard status.isReadyForDisplay else { return false }
        return meaningClusterPublicationNeedsRefresh(
            installed: installed,
            current: current,
            cachedClusterCount: cachedClusterCount
        )
    }

    nonisolated static func meaningClusterBackstopShouldProbeActiveJob(
        status: MeaningClusterPipelineStatus,
        lastObservedActive: Bool?
    ) -> Bool {
        status.needsDetection || lastObservedActive == true
    }

    nonisolated static func meaningClusterActiveJobProbeNeedsReadinessRefresh(
        status: MeaningClusterPipelineStatus,
        previousActive: Bool?,
        currentActive: Bool
    ) -> Bool {
        guard currentActive == false, status.needsDetection else { return false }
        return previousActive == true || previousActive == nil
    }

    @MainActor
    private func activeMeaningClusterDetectionJobExists(frame: FrameKey) -> Bool? {
        guard let activeJobs = try? JobFetch.jobs(
            type: .clusterDetect,
            statuses: [.pending, .running],
            context: modelContext
        ) else {
            return nil
        }

        var foundUndecodablePayload = false
        for job in activeJobs {
            guard let data = job.payload?.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ClusterDetectPayload.self, from: data) else {
                foundUndecodablePayload = true
                continue
            }
            if payload.frame == frame {
                return true
            }
        }
        return foundUndecodablePayload ? nil : false
    }

    @MainActor
    private func refreshMeaningClusterBackstopIfNeeded() async {
        let frame = state.activeFrame
        guard meaningClusterObservationIsActive, !onboardingMode else {
            return
        }

        if Self.meaningClusterBackstopShouldProbeActiveJob(
            status: meaningClusterPipelineStatus,
            lastObservedActive: lastMeaningClusterActiveJobProbe
        ), let activeJobExists = activeMeaningClusterDetectionJobExists(frame: frame) {
            let previousActive = lastMeaningClusterActiveJobProbe
            lastMeaningClusterActiveJobProbe = activeJobExists
            if Self.meaningClusterActiveJobProbeNeedsReadinessRefresh(
                status: meaningClusterPipelineStatus,
                previousActive: previousActive,
                currentActive: activeJobExists
            ) {
                // A no-op detection publishes no new cluster identity, and a
                // completion event can be missed while the lens remounts. Run
                // the exact readiness scan once on the active -> inactive edge;
                // the stored `false` prevents repeat scans on later timer ticks.
                await refreshMeaningClustersIfStoreChanged()
                return
            }
            if activeJobExists {
                // Cluster publication is atomic. While this frame's job is
                // pending/running there cannot be a completed replacement to
                // install, so avoid even the small cluster-store read below.
                return
            }
        }

        guard let storedClusters = displayClusters(
            for: frame,
            context: "meaning cluster publication backstop"
        ) else {
            return
        }

        let publicationIdentity = Self.meaningClusterPublicationIdentity(
            frame: frame,
            clusters: storedClusters
        )
        guard Self.meaningClusterBackstopRequiresPipelineRefresh(
            status: meaningClusterPipelineStatus,
            installed: lastMeaningClusterStoreSignature,
            current: publicationIdentity,
            cachedClusterCount: clusters.count
        ) else {
            return
        }

        // Lens entry and cluster job completion perform exact pipeline-status
        // refreshes. This timer is only a missed-publication backstop, so keep its
        // no-change path to the small cluster record set instead of rescanning the
        // full message/vector corpus on the main actor every second.
        await refreshMeaningClustersIfStoreChanged()
    }

    @MainActor
    private func refreshMeaningClustersIfStoreChanged() async {
        let frame = state.activeFrame
        guard meaningClusterObservationIsActive, !onboardingMode else {
            return
        }

        let status = currentMeaningClusterPipelineStatus()
        if meaningClusterPipelineStatus != status {
            meaningClusterPipelineStatus = status
        }
        guard status.isReadyForDisplay else {
            await clearMeaningClustersWhileUnavailable(frame: frame)
            return
        }

        guard let storedClusters = displayClusters(
            for: frame,
            context: "meaning cluster store observation"
        ) else {
            return
        }
        let publicationIdentity = Self.meaningClusterPublicationIdentity(
            frame: frame,
            clusters: storedClusters
        )

        guard !storedClusters.isEmpty else {
            guard !clusters.isEmpty else {
                lastMeaningClusterStoreSignature = publicationIdentity
                return
            }
            guard !meaningClusterDisplayRefreshInFlight else {
                meaningClusterPublicationRefreshPending = true
                return
            }
            meaningClusterDisplayRefreshInFlight = true
            defer {
                finishMeaningClusterDisplayRefresh()
            }
            clusters = []
            meaningLabeler.clear()
            await refreshSceneData(frame: frame)
            lastMeaningClusterStoreSignature = publicationIdentity
            return
        }

        // Repairing a render packet that lost its hubs is owned by the dedicated
        // one-shot recovery task (`repairMissingMeaningClustersIfNeeded`, keyed on
        // `meaningClusterRecoveryKey`), which fires once per change — not on a timer.
        // This backstop poll must react ONLY to an actual store publication
        // change or a still-empty cluster cache on first populate.
        // Previously a `visibleHubsMissing` clause here re-ran the full
        // refreshClusterLabels + refreshSceneData pass every second whenever the
        // store held clusters but their members were filtered out of the active
        // scope (a tight time range → "N / 0 visible") — work that can never
        // produce hubs, burning the main actor at 1 Hz indefinitely.
        guard Self.meaningClusterPublicationNeedsRefresh(
            installed: lastMeaningClusterStoreSignature,
            current: publicationIdentity,
            cachedClusterCount: clusters.count
        ) else {
            return
        }
        guard !meaningClusterDisplayRefreshInFlight else {
            meaningClusterPublicationRefreshPending = true
            return
        }

        meaningClusterDisplayRefreshInFlight = true
        defer {
            finishMeaningClusterDisplayRefresh()
        }

        await refreshClusterLabels(
            frame: frame,
            forceSnapshotRefresh: true,
            refreshSceneOnGain: false
        )
        await refreshSceneData(frame: frame)
        lastMeaningClusterStoreSignature = Self.meaningClusterPublicationIdentity(
            frame: frame,
            clusters: clusters
        )
    }

    @MainActor
    private func finishMeaningClusterDisplayRefresh() {
        meaningClusterDisplayRefreshInFlight = false
        guard meaningClusterPublicationRefreshPending else { return }
        meaningClusterPublicationRefreshPending = false
        Task { @MainActor in
            await refreshMeaningClustersIfStoreChanged()
        }
    }

    @MainActor
    private func clearMeaningClustersWhileUnavailable(frame: FrameKey) async {
        let hadVisibleClusterData = !clusters.isEmpty
            || !renderPacket.meaningClusterHubs.isEmpty
            || state.filter.clusterIds?.isEmpty == false
        let hadClusterPresentationState = hadVisibleClusterData
            || scopedMeaningClusterAvailableCount != nil
            || lastMeaningClusterStoreSignature != nil
            || hoveredMeaningClusterId != nil
            || pendingMeaningClusterEngageId != nil
            || clusterFilterWarpSequence != nil
            || !clusterFilterSourceHubs.isEmpty
        guard hadClusterPresentationState else { return }

        clusters = []
        scopedMeaningClusterAvailableCount = nil
        meaningLabeler.clear()
        lastMeaningClusterStoreSignature = nil
        dismissMeaningClusterHover()

        if state.filter.clusterIds?.isEmpty == false {
            if clusterFilterWarpSequence != nil, warpAnimator.isWarping {
                warpAnimator.cancel()
            }
            clusterFilterTransitionSequence += 1
            clusterFilterWarpSequence = nil
            clusterFilterRestoreCamera = nil
            clusterFilterSourceHubs = []
            pendingMeaningClusterEngageId = nil
            pendingFilterCameraReset = nil
            suppressFilterCameraReset = true
            state.filter.clusterIds = nil
        }

        if hadVisibleClusterData {
            await refreshSceneData(frame: frame)
        }
    }

    @MainActor
    private func displayClusters(for frame: FrameKey, context: String) -> [ClusterRecord]? {
        do {
            return try services.vectorClusterStore.clusters(for: frame)
        } catch {
            ConstellationLog.logger.warning(
                "cluster display read failed frame=\(frame.rawValue, privacy: .public) errorKind=\(String(reflecting: type(of: error)), privacy: .public)"
            )
            return nil
        }
    }

    @MainActor
    private func scheduleMeaningClusterDisplayRefresh() {
        guard state.activeFrame.spatialLens == .meaning, !onboardingMode else { return }
        armFilterCameraResetIfNeeded()
        meaningClusterDisplayRefreshTask?.cancel()
        meaningClusterDisplayRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  state.activeFrame.spatialLens == .meaning,
                  !onboardingMode else { return }
            guard !meaningClusterDisplayRefreshInFlight else { return }
            meaningClusterDisplayRefreshInFlight = true
            defer {
                finishMeaningClusterDisplayRefresh()
            }
            await refreshSceneData()
        }
    }

    /// Pull current Meaning clusters and persist heuristic labels for any
    /// missing one. Meaning is the only lens with cluster membership; any other
    /// frame clears the cluster state without reading the store. Cluster labels
    /// stay available to side panels/search stats; 3D billboards are off by
    /// default because the heuristic can include sender domains and should not
    /// appear in the canvas unless explicitly enabled.
    @MainActor
    private func refreshClusterLabels(
        frame explicitFrame: FrameKey? = nil,
        forceSnapshotRefresh: Bool = false,
        refreshSceneOnGain: Bool = true
    ) async {
        let frame = explicitFrame ?? state.activeFrame
        guard frame.spatialLens == .meaning,
              !onboardingMode,
              meaningClusterPipelineStatus.isReadyForDisplay else {
            self.clusters = []
            meaningLabeler.clear()
            return
        }

        guard let clusters = displayClusters(for: frame, context: "cluster label refresh") else {
            return
        }
        guard !clusters.isEmpty else {
            self.clusters = []
            meaningLabeler.clear()
            return
        }

        let hadMeaningClusters = self.clusters.isEmpty == false
        var refreshedSnapshot: ConstellationSnapshot?
        let needsLabel = clusters.filter { $0.label == nil }
        if !needsLabel.isEmpty {
            let vToC = (try? services.vectorClusterStore.vectorToCluster(frame: frame)) ?? [:]
            // Invert vector→cluster so we can pull the member-vector list per cluster.
            var membersByCluster: [Int64: [Int64]] = [:]
            for (vid, cid) in vToC {
                membersByCluster[cid, default: []].append(vid)
            }
            // One batched message-id resolve for every involved vector.
            let allVids = Array(Set(vToC.keys))
            let messageIdByVector = (try? services.vectorStore.messageIds(for: allVids)) ?? [:]
            let snapshot = await constellationSnapshot(for: frame, forceRefresh: forceSnapshotRefresh)
            refreshedSnapshot = snapshot
            let summarizer = ClusterSummarizer(messageIndex: snapshot.messageIndex, engine: nil)
            for cluster in needsLabel {
                let memberVids = membersByCluster[cluster.id] ?? []
                let label = summarizer.label(
                    forCluster: cluster,
                    memberVectorIds: memberVids,
                    messageIdByVectorId: messageIdByVector
                )
                try? services.vectorClusterStore.setLabel(label, forCluster: cluster.id)
            }
        }

        // Re-fetch so the scene picks up the freshly-persisted labels.
        guard let labeled = displayClusters(for: frame, context: "cluster label refetch") else {
            return
        }
        self.clusters = labeled
        _ = showClusterBillboardsPref
        let gainedMeaningClusters = !hadMeaningClusters
            && !labeled.isEmpty
            && renderPacketFrame.spatialLens == frame.spatialLens
            && renderPacket.meaningClusterHubs.isEmpty

        // Drive the Meaning lens's cluster-hover metadata. TF-IDF evidence
        // terms compute off the main actor and reuse the previous pass while
        // cluster content is unchanged; Qwen-first semantic titles stream in
        // asynchronously as a cached presentation layer, with Apple
        // Intelligence as fallback. Other lenses cleared the visible label
        // cache above, so hover metadata stays scoped to Meanings.
        let snapshot: ConstellationSnapshot
        if let refreshedSnapshot {
            snapshot = refreshedSnapshot
        } else {
            snapshot = await constellationSnapshot(for: frame, forceRefresh: forceSnapshotRefresh)
        }
        let titleGenerationClusterIds = renderPacketFrame.spatialLens == frame.spatialLens
            ? Set(renderPacket.meaningClusterHubs.map(\.clusterId))
            : []
        meaningLabeler.scheduleUpdate(
            clusters: labeled,
            messageIndex: snapshot.messageIndex,
            titleGenerator: meaningClusterTitleGenerator,
            titleGenerationClusterIds: titleGenerationClusterIds
        )
        if gainedMeaningClusters, refreshSceneOnGain {
            Task { @MainActor in
                await refreshSceneData(frame: frame)
            }
        }
    }

    @MainActor
    private func representativeNewStarRecords(for messageIds: [String]) -> [VectorRecord] {
        newStarRecordFetch(for: messageIds).records
    }

    /// Fetches the representative placed record per candidate message and
    /// separately reports candidates that have NO vector rows at all. A
    /// message whose embedding completed without producing vectors will never
    /// place and never render — the navigator must retire it instead of
    /// holding it in "forming" forever.
    @MainActor
    private func newStarRecordFetch(
        for messageIds: [String]
    ) -> (records: [VectorRecord], vectorlessMessageIds: [String]) {
        var records: [VectorRecord] = []
        var vectorless: [String] = []
        for messageId in messageIds {
            guard let messageRecords = try? services.vectorStore.vectorsForMessage(messageId: messageId) else {
                continue
            }
            if messageRecords.isEmpty {
                vectorless.append(messageId)
            } else if let representative = representativeNewStarRecord(from: messageRecords) {
                records.append(representative)
            }
        }
        return (records, vectorless)
    }

    @MainActor
    private func representativeNewStarRecord(from records: [VectorRecord]) -> VectorRecord? {
        records
            .filter { record in
                record.layoutX != nil && record.layoutY != nil && record.layoutZ != nil
            }
            .sorted { lhs, rhs in
                let leftRank = newStarCollectionRank(lhs.collection)
                let rightRank = newStarCollectionRank(rhs.collection)
                if leftRank != rightRank { return leftRank < rightRank }
                if lhs.chunkIndex != rhs.chunkIndex { return lhs.chunkIndex < rhs.chunkIndex }
                return lhs.vectorId < rhs.vectorId
            }
            .first
    }

    @MainActor
    private func syncNewStarNavigatorWithCurrentMessageIndex() {
        syncNewStarNavigator(
            availableRecords: [],
            messageIndex: currentMessageIndex,
            includesUntrackedArrivals: false
        )
    }

    @MainActor
    private func syncNewStarNavigator(
        availableRecords: [VectorRecord],
        messageIndex: [String: MessageFilterRow],
        includesUntrackedArrivals: Bool
    ) {
        // Embargoed live arrivals are invisible to the new-star tracker:
        // they must not enter forming/pending before the arrival moment.
        // Filtering here covers every sync call site with one gate.
        var resolvedMessageIndex = NewMailArrivalLedger.shared
            .filteredMessageIndex(messageIndex)
        // Re-track every announced-but-unvisited arrival on every sync.
        // A scope-mismatched sync (stale snapshot cache, filter change,
        // lens switch) can drop a pending entry, and a recreated navigator
        // (window reopen) starts empty — but the ledger still owes the
        // user a visit, so the navigation queue must re-promote them.
        newStarNavigator.noteInboundMessageIDs(
            NewMailArrivalLedger.shared.unvisitedArrivalIds
        )
        hydrateTrackedNewStarRows(into: &resolvedMessageIndex)
        var records = availableRecords
        let candidateIds = newStarRecordCandidateIds(
            messageIndex: resolvedMessageIndex,
            availableRecords: records,
            includesUntrackedArrivals: includesUntrackedArrivals
        )
        if candidateIds.isEmpty == false {
            let fetch = newStarRecordFetch(for: candidateIds)
            records += fetch.records
            retireVectorlessNewStarCandidates(
                fetch.vectorlessMessageIds,
                messageIndex: resolvedMessageIndex
            )
        }

        syncNewStarNavigatorState(
            records: records,
            messageIndex: resolvedMessageIndex,
            includesUntrackedArrivals: includesUntrackedArrivals
        )

        let followUpCandidateIds = newStarRecordCandidateIds(
            messageIndex: resolvedMessageIndex,
            availableRecords: records,
            includesUntrackedArrivals: includesUntrackedArrivals
        )
        guard followUpCandidateIds.isEmpty == false else { return }
        let followUpFetch = newStarRecordFetch(for: followUpCandidateIds)
        records += followUpFetch.records
        retireVectorlessNewStarCandidates(
            followUpFetch.vectorlessMessageIds,
            messageIndex: resolvedMessageIndex
        )
        syncNewStarNavigatorState(
            records: records,
            messageIndex: resolvedMessageIndex,
            includesUntrackedArrivals: includesUntrackedArrivals
        )
    }

    /// Retires tracked arrivals whose completed embedding produced no vectors
    /// from the spatial queue: no node will ever form for them. The canonical
    /// ledger remains unvisited because workspace lenses can still open the
    /// message by UUID, and a Metal-lens click can fall back to Front Page.
    /// (Normally unreachable — `EmbeddingOrchestrator` never marks a row
    /// embedded with zero vectors — but correct under the transient where
    /// vectors are deleted between completion and fetch.)
    @MainActor
    private func retireVectorlessNewStarCandidates(
        _ messageIds: [String],
        messageIndex: [String: MessageFilterRow]
    ) {
        for messageId in messageIds {
            guard let row = messageIndex[messageId],
                  row.embeddingStatus == .completed else { continue }
            newStarNavigator.markVisited(messageId: messageId)
        }
    }

    @MainActor
    private func hydrateTrackedNewStarRows(into messageIndex: inout [String: MessageFilterRow]) {
        let missingIDs = newStarNavigator.trackedMessageIds.compactMap { rawID -> UUID? in
            guard messageIndex[rawID] == nil else { return nil }
            return UUID(uuidString: rawID)
        }
        guard missingIDs.isEmpty == false else { return }

        for messageID in missingIDs {
            guard let row = newStarMessageFilterRow(for: messageID) else { continue }
            messageIndex[messageID.uuidString] = row
        }
    }

    @MainActor
    private func newStarMessageFilterRow(for messageID: UUID) -> MessageFilterRow? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == messageID
            }
        )
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first else {
            return nil
        }
        // Same user-action overlay the canonical loader applies: hydration
        // can run minutes after the arrival (starburst hydrate-on-miss,
        // mid-load re-patch), by which time the user may have confirmed or
        // marked the message from another surface.
        return NewStarArrivalRowHydrator.messageFilterRow(
            from: message,
            customCategoryCatalogKeys: customCategoryStore.allKeys,
            userActions: MessageAttentionUserActionState(
                projectActions: ProjectLensActionRepository(modelContext: modelContext)
                    .actionState(accountScopeKey: "all")
            )
        )
    }

    @MainActor
    private func newStarRecordCandidateIds(
        messageIndex: [String: MessageFilterRow],
        availableRecords: [VectorRecord],
        includesUntrackedArrivals: Bool
    ) -> [String] {
        if includesUntrackedArrivals {
            return newStarNavigator.candidateMessageIdsNeedingRecords(
                messageIndex: messageIndex,
                availableRecords: availableRecords
            )
        }
        return newStarNavigator.trackedMessageIdsNeedingRecords(
            messageIndex: messageIndex,
            availableRecords: availableRecords
        )
    }

    @MainActor
    private func syncNewStarNavigatorState(
        records: [VectorRecord],
        messageIndex: [String: MessageFilterRow],
        includesUntrackedArrivals: Bool
    ) {
        if includesUntrackedArrivals {
            newStarNavigator.sync(records: records, messageIndex: messageIndex)
        } else {
            newStarNavigator.syncTrackedLiveInbound(records: records, messageIndex: messageIndex)
        }
    }

    private func newStarCollectionRank(_ collection: VectorCollection) -> Int {
        switch collection {
        case .context: return 0
        case .attachment: return 1
        case .entity: return 2
        case .style: return 3
        }
    }

    /// Build the set of vectorIds that must be rendered regardless of
    /// the aperture radius — search results, Q&A citations, the locked
    /// destination, and the hovered destination. These are records the user is actively
    /// working on; aperture must not hide them.
    @MainActor
    private func buildAlwaysInclude() -> Set<Int64> {
        var set = Set<Int64>(state.searchResultIds)
        set.formUnion(newStarNavigator.pendingVectorIds)
        set.formUnion(highlighter.vectorIds)
        if let pending = pendingFocusClick { set.insert(pending.vectorId) }
        if let locked = state.lockedVectorId { set.insert(locked) }
        if let hovered = state.hoveredVectorId { set.insert(hovered) }
        return set
    }

    @MainActor
    private func renderBudgetForCurrentState(
        request: ConstellationMetalDisplayRequest
    ) -> RenderBudget {
        let profile = ConstellationRenderHardwareProfile.current(
            device: metalRenderer.metalDevice,
            lowPowerModeEnabled: lowPowerModeEnabled
        )
        adaptiveRenderBudget.setBaseBudget(profile.baseBudget)
        let budget = ConstellationColdFirstPaintPolicy.budget(
            base: adaptiveRenderBudget.currentBudget,
            isColdCacheMiss: coldFirstPaintRequest == request
        )
        // Locking does NOT contract the budget. The locked scene renders the
        // same field the user was just exploring — isolation comes from the
        // field dim and focus grades, not from removing nodes — so the
        // focused-packet install and the exit release stay free of visible
        // star popping. Frame-pressure reductions above still apply while
        // locked, exactly as they do unlocked.
        if state.searchResultIds.isEmpty == false || qaVM.citationVectorIds.isEmpty == false {
            return RenderBudget(
                maxStars: max(budget.maxStars, 2_000),
                maxNebulae: budget.maxNebulae,
                maxFibers: max(budget.maxFibers, 3_200),
                maxSatellites: budget.maxSatellites,
                degradationTier: budget.degradationTier
            )
        }
        return budget
    }

    @MainActor
    private func peopleLevelOfDetailPacketIfNeeded(
        _ packet: ConstellationRenderPacket,
        frame: FrameKey,
        camera: CameraState
    ) -> ConstellationRenderPacket {
        guard !onboardingMode,
              frame.spatialLens == .people,
              liveLockPersonFocus == nil,
              state.lockedVectorId == nil else {
            return packet
        }

        guard isLargePeoplePacket(packet) else { return packet }

        let cpuMS = renderStats?.cpuEncodingMilliseconds ?? 0
        let uploadMS = renderStats?.packetPreparationMilliseconds ?? 0
        let cameraDistance = simd_length(camera.position)
        let shouldReduce = cpuMS >= Self.peopleLiveLODCPUFrameMilliseconds
            || uploadMS >= Self.peopleLiveLODUploadMilliseconds
            || cameraDistance >= Self.peopleLiveLODCameraDistance
        guard shouldReduce else { return packet }

        return packet.applyingPeopleLevelOfDetail(
            .zoomedOutPressure,
            generatedAt: packet.generatedAt + Self.peopleLiveLODGeneratedAtOffset
        )
    }

    @MainActor
    private func isLargePeoplePacket(_ packet: ConstellationRenderPacket) -> Bool {
        packet.personHubs.count >= Self.peopleLiveLODHubTrigger
            || packet.stars.count >= Self.peopleLiveLODStarTrigger
    }

    @MainActor
    private func pendingLockSelectionIndicator(vectorId: Int64) -> some View {
        TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { _ in
            if let point = lockedSelectionIndicatorPoint(vectorId: vectorId) {
                HoverNodeIndicator()
                    .id("locked-selection-\(vectorId)")
                    .position(point)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// True while a People-lens correspondent-focus entry transition is still
    /// running — from the fly-in warp (which arms `pendingPeopleLiveFocusReveal`
    /// at scene contraction) through the background-recede dim ramp
    /// (`peopleContextDimRampActive`). The overlay uses this to hold the
    /// ring-node hover tracker inert until the scene has fully settled, so the
    /// transient dial card can't flicker onto nodes that are still sliding into
    /// place. The gate→ramp handoff happens within a single MainActor tick (the
    /// reveal resolves and the ramp starts in the same call), so there is no gap
    /// where both are false mid-transition.
    ///
    /// This can also read `true` during a People email-node lock entry and
    /// during People exits, which likewise start `peopleContextDimRampActive`.
    /// That is harmless: the hover tracker that consumes this only mounts under
    /// `isPeopleFocusOverlay` (a correspondent lock with `liveLockPersonFocus`
    /// set); email-node locks and the unmounting exit path never have it up, so
    /// the extra `true` windows gate nothing.
    private var peopleFocusEntering: Bool {
        pendingPeopleLiveFocusReveal != nil || peopleContextDimRampActive
    }

    @MainActor
    private func lockedNodeOverlay(
        id: Int64,
        record: VectorRecord,
        row: MessageFilterRow
    ) -> some View {
        // The card itself centers in the scene; this side preference only seeds the
        // dashed-leader fallback when projection is unavailable. Pick the edge opposite
        // the sidebar so the leader visually points away from the search/ask pane.
        let cardSide: HorizontalEdge = sidebarPlacement == .leading ? .trailing : .leading
        // Telemetry strip pins to the same horizontal edge as the sidebar
        // so they form a single info column on one side of the scene.
        // Mapped here rather than derived inside the overlay so the
        // dependency on `sidebarPlacement` is explicit at the call site.
        let sidebarEdge: HorizontalEdge = sidebarPlacement == .leading ? .leading : .trailing
        let enrichmentToken = lockEntryEnrichmentToken
        let enrichmentSequence = enrichmentToken?.vectorId == id && lockSummaryInFlightToken != enrichmentToken
            ? enrichmentToken?.sequence
            : nil
        // Same picker the Metal renderer feeds to `PeopleGraphBuilder` for
        // the Saturn ring bands. Passing the array straight through to the
        // overlay lets the CORRESPONDENT chip strip render in lockstep with
        // the rings the user actually sees in space.
        let overlayResolvedFilter = ConstellationFilterResolver.effectiveSceneFilter(
            baseFilter: state.filter,
            selectedTimeRange: state.selectedTimeRange
        )
        let ringTierColors: [Color] = correspondentRingTierColors(filter: overlayResolvedFilter).map { rgb in
            Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z), opacity: 1)
        }
        return LockedNodeOverlay(
            lockedVectorId: id,
            record: record,
            row: row,
            activeFrame: state.activeFrame,
            renderPacket: renderPacket,
            cameraController: cameraController,
            viewSize: viewSize,
            vectorStore: services.vectorStore,
            vectorNeighborsStore: services.vectorNeighborsStore,
            vectorFrameLayoutStore: services.vectorFrameLayoutStore,
            messageIndex: currentMessageIndex,
            modelContext: modelContext,
            contextOverride: nil,
            personFocus: liveLockPersonFocus,
            peopleRingMessageIds: peopleRingMessageIds(for: liveLockPersonFocus),
            summaryOverride: summaryByMessageId[record.messageId],
            classificationOverride: classificationByMessageId[record.messageId],
            summaryCustomKeysOverride: summaryCustomKeysByMessageId[record.messageId],
            customCategoryCatalog: customCategoryStore.descriptors,
            summaryByMessageId: summaryByMessageId,
            messageStatusSignals: lockedOverlayMessageStatusSignals,
            regeneratingSummaryMessageIds: regeneratingSummaryMessageIds,
            focusWorldOverride: selectedNodeFocusWorld,
            layoutFocalPointOverride: nil,
            projectionDriver: lockedOverlayProjectionDriver,
            lockedAccountColor: accountColor(for: row),
            peopleRingTierColors: ringTierColors,
            defaultCardSide: cardSide,
            sidebarSide: sidebarEdge,
            userAddresses: userAddressSet,
            userIdentity: summarizationUserIdentity(for: row),
            contextOrientationService: services.contextOrientationService,
            askMemoryProvider: services.askMemoryProvider,
            attachmentSummaryService: services.attachmentSummaryService,
            jobCompletionBroadcaster: services.jobCompletionBroadcaster,
            enrichmentSequence: enrichmentSequence,
            entryPhase: 1,
            peopleFocusEntering: peopleFocusEntering,
            onPresentMessageContextMenu: { messageId, point, view in
                guard let messageID = UUID(uuidString: messageId) else { return }
                presentMessageContextMenu(
                    messageID: messageID,
                    vectorIdForOverlayRelease: messageId == record.messageId && liveLockPersonFocus == nil
                        ? id
                        : nil,
                    includeCopyAction: true,
                    at: point,
                    in: view
                )
            },
            onRelease: leaveSelectedNodeFocus,
            onClassificationChanged: { [messageId = record.messageId] classification, customKeys in
                applyUserClassification(
                    messageId: messageId,
                    classification: classification,
                    customCategoryKeys: customKeys
                )
            },
            isSenderPinned: pinnedEmailsMirror.contains(row.fromAddress.lowercased()),
            onToggleSenderPinned: {
                toggleSenderPinned(
                    email: row.fromAddress,
                    displayName: row.fromName
                )
            },
            onPrewarmRelatedSummaries: { targets in
                scheduleRelatedSummaryPrewarm(targets)
            },
            onRequestRelatedSummary: { target in
                await resolveOnDemandSummary(
                    forMessageId: target.messageId,
                    rowOverride: target.row,
                    scope: .lockedContext
                )
            },
            onWarpToWorld: { @MainActor [self] world in
                // Tab-step through the rank list: warp the camera to the
                // focused item, but adjust depth (via cone-fit math in
                // `adaptiveLockedOverlayApproach`) so the locked email's
                // star stays in the viewport too. Without this the camera
                // would always land at a fixed 0.12 units from the target
                // — fine when the target is right next to the locked
                // node, but for far-away neighbours the locked context
                // (and therefore the annotation pane laid out alongside
                // it) would fall outside the camera view. Awaits the
                // engaged warp's duration so the rank orchestrator can
                // sequence close → warp → open without overlap.
                let lockedContext = state.lockedVectorId.flatMap { id in
                    frameAwarePosition(vectorId: id)
                }
                warpToWithContext(target: world, contextPoint: lockedContext)
                let duration = warpAnimator.currentEngagementDuration
                if duration > 0 {
                    try? await Task.sleep(for: .seconds(duration))
                }
            },
            rankController: lockNeighbourRank,
            selectedRingMessageId: $lockedRingSelectionMessageId
        )
    }

    @MainActor
    private func accountColor(for row: MessageFilterRow) -> AccountColor {
        guard let accountId = row.accountId,
              let account = accounts.first(where: { $0.id == accountId }) else {
            return AccountColorPalette.color(forIndex: AccountColorPalette.defaultIndex)
        }
        return AccountColorPalette.color(forIndex: account.colorIndex)
    }

    @MainActor
    private func accountColorIndexByAccountId() -> [UUID: Int] {
        Dictionary(
            uniqueKeysWithValues: accounts.map {
                ($0.id, $0.colorIndex ?? AccountColorPalette.defaultIndex)
            }
        )
    }

    @MainActor
    private func hoverAccountContext(for row: MessageFilterRow) -> HoverAccountContext? {
        guard let accountId = row.accountId,
              let account = accounts.first(where: { $0.id == accountId }) else {
            return nil
        }
        return hoverAccountContext(for: account)
    }

    @MainActor
    private func hoverAccountContext(for account: Account) -> HoverAccountContext {
        HoverAccountContext(
            displayName: account.displayName,
            emailAddress: account.emailAddress,
            colorIndex: account.colorIndex ?? AccountColorPalette.defaultIndex
        )
    }

    @MainActor
    private func personHubAccountEntries(for rows: [MessageFilterRow]) -> [PersonHubAccountEntry] {
        var countsByAccountId: [UUID: Int] = [:]
        for row in rows {
            guard let accountId = row.accountId else { continue }
            countsByAccountId[accountId, default: 0] += 1
        }

        return countsByAccountId.compactMap { accountId, count in
            guard let account = accounts.first(where: { $0.id == accountId }) else { return nil }
            return PersonHubAccountEntry(
                id: accountId,
                account: hoverAccountContext(for: account),
                count: count
            )
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            let lhs = $0.account.resolvedDisplayName.lowercased()
            let rhs = $1.account.resolvedDisplayName.lowercased()
            if lhs != rhs { return lhs < rhs }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Persists user-defined custom keys for the given message via SwiftData
    /// and updates the in-memory override maps so the locked card's chip strip
    /// rerenders immediately.
    /// Both sets empty clears every assignment. Custom-key changes against
    /// a still-collecting category also record / withdraw the message as a
    /// tagged training example (which can trigger definition generation at
    /// the activation threshold).
    private struct MessageClassificationUndoSnapshot: Equatable {
        let classification: MailClassification?
        let customCategoryKeys: Set<String>
    }

    @MainActor
    @discardableResult
    private func applyUserClassification(
        messageId: String,
        classification: MailClassification?,
        customCategoryKeys: Set<String>,
        registerUndo: Bool = true,
        reconcileProjects: Bool = true
    ) -> Bool {
        guard let uuid = UUID(uuidString: messageId) else { return false }
        let writeContext = ModelContext(modelContext.container)
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == uuid })
        descriptor.fetchLimit = 1
        guard let message = try? writeContext.fetch(descriptor).first else { return false }

        let analysis: MessageAnalysis
        if let existing = message.analysis {
            analysis = existing
        } else {
            let created = MessageAnalysis(
                message: message,
                analysisVersion: "user-classification",
                dimensionsJSON: "{}"
            )
            writeContext.insert(created)
            message.analysis = created
            analysis = created
        }
        let storageCustomKeys = customCategoryKeys.intersection(customCategoryStore.allKeys)
        // Example bookkeeping must compare against the keys that were
        // actually stored on the row before this edit, not the override
        // map, so a re-applied identical set is a no-op.
        let previousCustomKeys = Set(CustomCategoryKeysJSON.decode(analysis.customCategoryKeysJSON))
            .intersection(customCategoryStore.allKeys)
        let previousClassification = MailClassificationJSON.decode(analysis.mailClassificationJSON)
        let classificationJSON: String?
        do {
            classificationJSON = try classification.map(MailClassificationJSON.encode)
            analysis.mailClassificationJSON = classificationJSON
            analysis.customCategoryKeysJSON = try CustomCategoryKeysJSON.encode(storageCustomKeys)
            try writeContext.save()
        } catch {
            // A failed save must not leave the mutated/inserted analysis
            // registered in the shared context: later refresh paths save that
            // context and could otherwise commit a category change that the UI
            // correctly reported as failed.
            writeContext.rollback()
            print("[Constellation] manual classification save failed: \(String(reflecting: type(of: error)))")
            return false
        }

        // Tag / untag collecting-category examples for every key whose
        // membership changed. `setExample` is a no-op for active
        // categories and enqueues the definition job at the threshold. A
        // tag that reaches the threshold without unlocking activation
        // (every example still shares one correspondent) surfaces an
        // alert instead of leaving the user to notice the stalled menu
        // label on their own.
        for added in storageCustomKeys.subtracting(previousCustomKeys) {
            let result = customCategoryStore.setExample(true, messageID: uuid, key: added)
            if result == .updated(reachedThresholdWithoutDiversity: true),
               let displayName = customCategoryStore.descriptor(forKey: added)?.displayName {
                customCategoryTaggingNotice = CustomCategoryTaggingNotice(
                    kind: .reachedThresholdWithoutDiversity(displayName: displayName)
                )
            }
        }
        for removed in previousCustomKeys.subtracting(storageCustomKeys) {
            customCategoryStore.setExample(false, messageID: uuid, key: removed)
        }

        // Keep overrides in the maps so the chip strip immediately reflects
        // the new state — falling through to the row's stale value would
        // otherwise re-show the just-removed chips until the next snapshot
        // rebuild.
        classificationByMessageId[messageId] = classification
        summaryCustomKeysByMessageId[messageId] = storageCustomKeys

        // If this is the currently locked node, mirror its classification
        // into AppStorage so the Edit-menu submenu's checkmarks update
        // without waiting for a snapshot rebuild.
        let storedClassificationJSON = classificationJSON ?? analysis.mailClassificationJSON
        snapshotCache.updateClassification(
            messageId: messageId,
            classificationJSON: storedClassificationJSON,
            customCategoryKeys: storageCustomKeys
        )
        if lockedNodeIDStorage == messageId {
            lockedNodeClassificationStorage = storedClassificationJSON ?? ""
            lockedNodeCustomKeysStorage = (try? CustomCategoryKeysJSON.encode(storageCustomKeys)) ?? ""
        }
        if state.filter.purposes != nil
            || state.filter.mailingListCategoryIncluded != nil {
            Task { await refreshSceneData() }
        } else if state.filter.customCategoryKeys != nil {
            Task { await refreshSceneData() }
        }
        // Category-pulldown counts bucket by shared purpose and Lists regardless of
        // whether the Topics filter is constraining the scene. The .task keyed
        // on basePacket.generatedAt only fires when refreshSceneData runs, so
        // refresh counts explicitly here to catch an edit that leaves every
        // classification facet unconstrained, where the scene doesn't rebuild.
        Task { await refreshTopicClassificationCounts() }

        let before = MessageClassificationUndoSnapshot(
            classification: previousClassification,
            customCategoryKeys: previousCustomKeys
        )
        let after = MessageClassificationUndoSnapshot(
            classification: classification,
            customCategoryKeys: storageCustomKeys
        )
        if registerUndo, before != after {
            classificationUndoMessageID = uuid
            messageUndoTarget.registerSuccessfulAction(
                on: undoManager,
                actionName: "Change Category",
                undo: { [self] in
                    classificationUndoMessageID = nil
                    let succeeded = applyUserClassification(
                        messageId: messageId,
                        classification: before.classification,
                        customCategoryKeys: before.customCategoryKeys,
                        registerUndo: false,
                        reconcileProjects: true
                    )
                    classificationUndoOperationSucceeded = succeeded
                    return succeeded
                },
                redo: { [self] in
                    classificationUndoMessageID = nil
                    let succeeded = applyUserClassification(
                        messageId: messageId,
                        classification: after.classification,
                        customCategoryKeys: after.customCategoryKeys,
                        registerUndo: false,
                        reconcileProjects: true
                    )
                    classificationUndoOperationSucceeded = succeeded
                    return succeeded
                }
            )
        }
        if reconcileProjects {
            Task { await reconcileManualProjectMembershipAfterCategoryChange(messageID: uuid) }
        }
        return true
    }

    @MainActor
    private func reconcileManualProjectMembershipAfterCategoryChange(messageID: UUID) async {
        guard let coordinator = services.manualProjectMembershipCoordinator else {
            return
        }
        await coordinator.reconcile(
            messageIDs: [messageID],
            changedFacets: [.fixedCategory, .customCategory]
        )
        projectsData.invalidateAndRefresh()
    }

    /// Removes a user-defined category everywhere it surfaces: the catalog
    /// row itself, the live filter's explicit custom selection, both
    /// in-memory override maps, and the rendered scene (rows re-decode
    /// against the shrunk catalog on the forced snapshot rebuild). Fixed
    /// categories have no removal path by construction.
    @MainActor
    private func removeCustomCategory(key: String) {
        customCategoryStore.removeCategory(key: key)
        if var selected = state.filter.customCategoryKeys {
            selected.remove(key)
            state.filter.customCategoryKeys = selected
        }
        for (messageId, keys) in summaryCustomKeysByMessageId where keys.contains(key) {
            summaryCustomKeysByMessageId[messageId] = keys.subtracting([key])
        }
        topicCustomCategoryCounts.removeValue(forKey: key)
        snapshotCache.clearAll()
        Task {
            await refreshSceneData()
            await refreshTopicClassificationCounts()
        }
    }

    /// Stable identity for `@Query` reactivity in `.onChange(of:)`. The
    /// modifier chain on the main body trips the type-checker complexity
    /// limit if the projection is computed inline, so the chain reads a
    /// single computed value instead. Sorted so `Equatable` semantics
    /// don't see iteration-order noise between equivalent fetches.
    private var pinnedCorrespondentsKey: [String] {
        pinnedCorrespondents.map(\.primaryEmail).sorted()
    }

    /// Reseed `pinnedEmailsMirror` from the current `@Query` result. Used
    /// on first paint and after any persistent rebuild settles, so the
    /// mirror converges back onto the canonical SwiftData state.
    private func syncPinnedEmailsMirrorFromQuery() {
        pinnedEmailsMirror = Set(pinnedCorrespondents.map(\.primaryEmail))
    }

    @MainActor
    private func handlePinnedCorrespondentsChange() {
        syncPinnedEmailsMirrorFromQuery()
        retainedMetalSurfaces.removeAll()
        guard state.activeFrame.spatialLens == .people else { return }
        Task { await refreshSceneData() }
    }

    /// Flip the pinned state for a correspondent. Routes through the
    /// idempotent `PinnedCorrespondent.setPinned(...)` helper so neither
    /// rapid double-taps nor a parallel Settings-window write can produce
    /// duplicate rows. Also updates the local optimistic mirror
    /// (`pinnedEmailsMirror`) synchronously so the context menu's
    /// `isSenderPinned` reads the new state in the same frame as the
    /// save, eliminating the ~1-frame "wrong label" flash window that
    /// would otherwise sit between the save and the `@Query` rebuild.
    private func toggleSenderPinned(email: String, displayName: String?) {
        let normalized = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return }
        let willBePinned = !pinnedEmailsMirror.contains(normalized)
        // Optimistic local update first so any synchronous re-evaluation
        // (including the context menu re-opening before `@Query` fires)
        // already sees the new state.
        if willBePinned {
            pinnedEmailsMirror.insert(normalized)
        } else {
            pinnedEmailsMirror.remove(normalized)
        }
        PinnedCorrespondent.setPinned(
            willBePinned,
            for: normalized,
            displayName: displayName,
            in: modelContext
        )
        retainedMetalSurfaces.removeAll()
        // Pinned-set changes affect `.people`'s major-correspondent
        // computation, so refresh the scene to redraw coloration.
        Task { await refreshSceneData() }
    }

    private var projectsMessageSummaryTaskToken: String? {
        guard state.activeFrame.spatialLens == .projects,
              let messageID = projectsWorkspace?.messageReadout?.messageID else {
            return nil
        }
        return messageID.uuidString
    }

    private var regeneratingSummaryMessageIds: Set<String> {
        Set(summaryRegenerationTokensByMessageId.keys)
    }

    @MainActor
    private func presentProjectsMessageContextMenu(
        messageID: UUID,
        projectKey: String,
        at point: NSPoint,
        in view: NSView
    ) {
        let repository = ProjectLensActionRepository(modelContext: modelContext)
        let accountScopeKey = projectsWorkspace?.accountScopeKey ?? "all"
        let actionState = repository.actionState(accountScopeKey: accountScopeKey)
        let isResolved = actionState.resolvedMessageIDs.contains(messageID)
        let isReplyNeededByUser = actionState.replyNeededMessageIDs.contains(messageID)
        let isRepliedByUser = actionState.repliedMessageIDs.contains(messageID)
        let isConfirmationNeededByUser = actionState.confirmationNeededMessageIDs.contains(messageID)
        let isConfirmedByUser = actionState.confirmedMessageIDs.contains(messageID)

        var extras: [ConstellationNodeContextMenu.Context.ExtraItem] = []
        extras.append(
            ConstellationNodeContextMenu.Context.ExtraItem(
                title: isResolved ? "Reopen Message" : "Mark Message Resolved",
                state: isResolved ? .on : .off,
                systemSymbolName: isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle"
            ) { [self] in
                // Begin the green Collapse only when *activating* the state, and
                // only on a surface that hosts the overlay, so the right-click menu
                // animates the same way the hover cluster and right column do.
                // Settled explicitly (the resolved message stays in the Projects
                // dossier), matching the wrapped action bundle.
                if !isResolved, projectsWorkspace?.hasDepartingCardSurface == true {
                    let now = Date()
                    projectsWorkspace?.statusGestureCoordinator.begin(.resolve, for: [messageID], now: now)
                    projectsWorkspace?.statusGestureCoordinator.scheduleDepartingSettle(
                        for: [messageID], startedAt: now, hold: ProjectsWorkspaceState.departingSettleHold
                    )
                }
                frontPageSetResolved([messageID], value: !isResolved)
            }
        )
        extras.append(
            ConstellationNodeContextMenu.Context.ExtraItem(
                title: isReplyNeededByUser ? "Clear Reply Needed" : "Mark Reply Needed",
                state: isReplyNeededByUser ? .on : .off,
                systemSymbolName: "arrowshape.turn.up.left"
            ) { [self] in
                frontPageSetReplyNeeded([messageID], value: !isReplyNeededByUser)
            }
        )
        extras.append(
            ConstellationNodeContextMenu.Context.ExtraItem(
                title: isRepliedByUser ? "Mark Unreplied" : "Mark Replied",
                state: isRepliedByUser ? .on : .off,
                systemSymbolName: isRepliedByUser ? "arrowshape.turn.up.left" : "arrowshape.turn.up.left.fill"
            ) { [self] in
                frontPageSetReplied([messageID], value: !isRepliedByUser)
            }
        )
        // Confirmation actions only apply to messages that actually carry a
        // confirmation obligation (triage binary obligation: needs-reply XOR
        // needs-confirmation). User-coded confirmation overrides keep the
        // items visible so they can be cleared; an unresolvable message
        // (not in the snapshot) fails open so state is never stranded.
        let filterRow = projectsWorkspace?.currentSnapshot?.messageFilterRows[messageID.uuidString]
        let confirmationApplies = filterRow == nil
            || filterRow?.requiresConfirmation == true
            || filterRow?.isConfirmed == true
            || isConfirmationNeededByUser
            || isConfirmedByUser
        if confirmationApplies {
            extras.append(
                ConstellationNodeContextMenu.Context.ExtraItem(
                    title: isConfirmationNeededByUser ? "Clear Confirmation Needed" : "Mark Confirmation Needed",
                    state: isConfirmationNeededByUser ? .on : .off,
                    systemSymbolName: "questionmark.circle"
                ) { [self] in
                    frontPageSetConfirmationNeeded([messageID], value: !isConfirmationNeededByUser)
                }
            )
            extras.append(
                ConstellationNodeContextMenu.Context.ExtraItem(
                    title: isConfirmedByUser ? "Mark Unconfirmed" : "Mark Confirmed",
                    state: isConfirmedByUser ? .on : .off,
                    systemSymbolName: isConfirmedByUser ? "xmark.seal" : "checkmark.seal"
                ) { [self] in
                    frontPageSetConfirmed([messageID], value: !isConfirmedByUser)
                }
            )
        }

        presentMessageContextMenu(
            messageID: messageID,
            vectorIdForOverlayRelease: nil,
            includeCopyAction: true,
            extraItems: extras,
            onAfterMessageMutation: { [self] in
                projectsData.invalidateAndRefresh()
                frontPageData.invalidateAndRefresh()
            },
            onAfterDelete: { [self] in
                // Only re-anchor the selection on the message's project
                // if there's no active multi-selection — deleting a
                // single message inside one of N selected rows should
                // not silently drop the other N-1.
                if !projectKey.isEmpty,
                   let workspace = projectsWorkspace,
                   workspace.selectedProjectKeys.count <= 1 {
                    workspace.focusProject(projectKey)
                }
                // Hold the rebuild until the just-begun Collapse plays, so the card
                // is not yanked before its motion (0 when no gesture is active).
                let hold = projectsWorkspace?.statusGestureCoordinator.remainingDepartingHold() ?? 0
                projectsData.invalidateAndRefresh(holdingFor: hold)
                frontPageData.invalidateAndRefresh()
            },
            onDeleteBegin: { [self] in
                // Post-confirmation, post-dispatch: fire the red Collapse on the
                // Projects coordinator so the right-click delete crumbles the card
                // the same way the hover cluster and right column do — but only on a
                // surface that hosts the overlay, so the Gantt drops the dot at once.
                guard let coordinator = projectsWorkspace?.statusGestureCoordinator,
                      projectsWorkspace?.hasDepartingCardSurface == true else { return }
                let now = Date()
                coordinator.begin(.delete, for: [messageID], now: now)
                coordinator.scheduleDepartingSettle(
                    for: [messageID], startedAt: now,
                    hold: Self.departingHold(for: [messageID], on: coordinator, tail: Self.departingSettleTail)
                )
            },
            at: point,
            in: view
        )
    }

    @MainActor
    private func invalidateSharedMessageAttentionSurfaces() {
        performSharedMessageAttentionInvalidation(
            preservingFrontPageProjectDefinitions: false
        )
    }

    @MainActor
    private func performSharedMessageAttentionInvalidation(
        preservingFrontPageProjectDefinitions: Bool
    ) {
        invalidateRetainedLensSurfacesForMutation(
            preservingFrontPageProjectDefinitions: preservingFrontPageProjectDefinitions
        )
        projectsWorkspace?.bumpActionRevision()
        // Hold the Projects rebuild the same way as Front Page below: a fast
        // local resolve / delete would otherwise drop or re-render the workroom /
        // Deadlines card before its Collapse plays. 0 when no departing gesture is
        // active → an immediate refresh, exactly as before.
        let projectsHold = projectsWorkspace?.statusGestureCoordinator.remainingDepartingHold() ?? 0
        projectsData.invalidateAndRefresh(holdingFor: projectsHold)
        // Hold the Front Page rebuild until any active departing (delete / resolve)
        // gesture reaches its motion floor, so a fast local resolve does not drop
        // the card before its green Collapse plays. 0 when none is active → an
        // immediate refresh, exactly as before. Delete's slow IMAP round-trip
        // already covers its own hold, so this leaves it unchanged.
        let departingHold = frontPageWorkspace?.statusGestureCoordinator.remainingDepartingHold() ?? 0
        frontPageData.invalidateAndRefresh(
            holdingFor: departingHold,
            preservingProjectDefinitions: preservingFrontPageProjectDefinitions
        )
        timelineData.invalidateAndRefreshIfBound()
        snapshotCache.clearAll()
        guard Self.usesMetalScene(state.activeFrame) else { return }
        Task { await refreshSceneData(updateColorLookup: false) }
    }

    /// After each Projects rebuild, run the coordinator's safety sweep. Every
    /// Projects departing gesture (delete / resolve / send-to-Composer) clears on
    /// its own `scheduleDepartingSettle` timer once its motion plays, and Projects
    /// begins no in-place gestures, so nothing is resolved by snapshot state here —
    /// the sweep only expires anything that somehow outlived the safety window
    /// (e.g. a settle task lost to a rapid re-fire). Never resolve on message
    /// presence: a deadline's representative email need not live in the project
    /// `messageLookup`, and clearing on absence would cut its Collapse short.
    @MainActor
    private func reconcileProjectsStatusGestures(workspace: ProjectsWorkspaceState) {
        workspace.statusGestureCoordinator.reconcile { _, _ in false }
    }

    // MARK: - Front Page message actions

    @MainActor
    private var frontPageAccountScopeKey: String {
        ProjectsDataController.accountScopeKey(for: state.filter)
    }

    /// The action-closure bundle handed to the Front Page lens (cards, reader,
    /// right column). Each closure routes into the shared mutation paths below
    /// so reply/confirm/resolve state stays consistent across every lens.
    @MainActor
    private var frontPageMessageActions: FrontPageMessageActionHandlers {
        FrontPageMessageActionHandlers(
            presentMenu: { [self] id, point, view in
                presentFrontPageMessageContextMenu(messageID: id, at: point, in: view)
            },
            presentThreadMenu: { [self] id, point, view in
                presentFrontPageMessageContextMenu(
                    messageID: id,
                    includesMessageProjectAction: false,
                    readTargetIDs: FrontPageThreadReadTarget.messageIDs(
                        representativeID: id,
                        composition: frontPageWorkspace?.currentSnapshot?.composition
                    ),
                    at: point,
                    in: view
                )
            },
            presentBulkMenu: { [self] ids, point, view in
                presentFrontPageBulkMessageContextMenu(messageIDs: ids, at: point, in: view)
            },
            setRead: { [self] ids, value in frontPageSetRead(ids, value: value) },
            setFlagged: { [self] ids, value in frontPageSetFlagged(ids, value: value) },
            markAsSpam: { [self] ids in _ = frontPageMarkAsSpamMessages(ids) },
            setReplyNeeded: { [self] ids, value in frontPageSetReplyNeeded(ids, value: value) },
            // ⌥ at click time → also open / front the Composer ("Open in
            // Composer"); plain click only enqueues ("Send to Composer").
            // Dispatch is synchronous at press, so sampling the live modifier
            // flags here captures the ⌥ state of the actual click.
            sendToComposer: { [self] ids in
                frontPageSendToComposer(ids, openComposer: ComposerOpenOnQueuePreference.opensComposer(optionHeld: NSEvent.modifierFlags.contains(.option)))
            },
            setReplied: { [self] ids, value in frontPageSetReplied(ids, value: value) },
            setConfirmationNeeded: { [self] ids, value in frontPageSetConfirmationNeeded(ids, value: value) },
            setConfirmed: { [self] ids, value in frontPageSetConfirmed(ids, value: value) },
            setResolved: { [self] ids, value in frontPageSetResolved(ids, value: value) },
            delete: { [self] ids in _ = frontPageDeleteMessages(ids) },
            ignore: { [self] id in beginListIgnore(messageID: id) },
            setClassification: { [self] id, classification, customKeys in
                applyUserClassification(
                    messageId: id.uuidString,
                    classification: classification,
                    customCategoryKeys: customKeys
                )
            },
            setClassificationAndReportSuccess: { [self] id, classification, customKeys in
                applyUserClassification(
                    messageId: id.uuidString,
                    classification: classification,
                    customCategoryKeys: customKeys
                )
            },
            canUndoClassification: { [self] messageID in
                classificationUndoMessageID == messageID
                    && undoManager?.canUndo == true
                    && undoManager?.undoActionName == "Change Category"
            },
            undoClassification: { [self] messageID in
                guard classificationUndoMessageID == messageID,
                      undoManager?.canUndo == true,
                      undoManager?.undoActionName == "Change Category" else {
                    return false
                }
                classificationUndoOperationSucceeded = nil
                undoManager?.undo()
                classificationUndoMessageID = nil
                return classificationUndoOperationSucceeded == true
            },
            reconcileProjectMembership: { [self] id in
                await reconcileManualProjectMembershipAfterCategoryChange(messageID: id)
            }
        )
    }

    @MainActor
    private var meaningLockedMessageActions: FrontPageMessageActionHandlers {
        var actions = frontPageMessageActions
        actions.delete = { [self] ids in
            let lockedTargetID = meaningLockedMainEmailActionTarget?.messageID
            let lockedVectorId = state.lockedVectorId
            _ = frontPageDeleteMessages(ids) { [self] deletedIDs in
                guard let lockedTargetID,
                      deletedIDs.contains(lockedTargetID),
                      state.activeFrame.spatialLens == .meaning else {
                    return
                }
                scheduleLockedDeletionReturnAfterAnimation(
                    messageIds: Set(deletedIDs.map(\.uuidString)),
                    dyingPeople: [],
                    lockedVectorId: lockedVectorId
                )
            }
        }
        return actions
    }

    @MainActor
    private func timelineMessageActions(workspace: TimelineWorkspaceState) -> FrontPageMessageActionHandlers {
        var actions = frontPageMessageActions
        actions.delete = { [self, weak workspace] ids in
            // `frontPageDeleteMessages` fires the red Collapse on the active
            // (Timeline) coordinator. Hold the playhead on the departing message
            // so the Collapse plays before the reader advances to the next.
            let deleted = frontPageDeleteMessages(ids)
            guard deleted,
                  ids.count == 1,
                  let deletedID = ids.first else { return }
            let advanceDelay = Self.departingHold(
                for: [deletedID], on: workspace?.statusGestureCoordinator, tail: Self.departingAdvanceTail
            )
            Task { @MainActor [weak workspace] in
                try? await Task.sleep(for: .seconds(advanceDelay))
                workspace?.advancePlayheadAfterDeletion(of: deletedID)
            }
        }
        // Resolve: play the green Collapse in the reader. The resolved message
        // stays in the snapshot (unlike delete), so fire + settle the gesture
        // explicitly rather than relying on a snapshot-drop reconcile.
        let baseSetResolved = actions.setResolved
        actions.setResolved = { [weak workspace] ids, value in
            if value, let workspace {
                let now = Date()
                let coordinator = workspace.statusGestureCoordinator
                coordinator.begin(.resolve, for: ids, now: now)
                coordinator.scheduleDepartingSettle(
                    for: ids, startedAt: now,
                    hold: Self.departingHold(for: ids, on: coordinator, tail: Self.departingSettleTail)
                )
                // Resolve keeps the message on the timeline (unlike delete), so
                // the reader would otherwise reveal it intact after the Collapse.
                // Advance off it once the motion plays, so it reads as leaving.
                if ids.count == 1, let resolvedID = ids.first {
                    let advanceDelay = Self.departingHold(
                        for: [resolvedID], on: coordinator, tail: Self.departingAdvanceTail
                    )
                    Task { @MainActor [weak workspace] in
                        try? await Task.sleep(for: .seconds(advanceDelay))
                        workspace?.advancePlayheadAfterDeletion(of: resolvedID)
                    }
                }
            }
            baseSetResolved(ids, value)
        }
        // The semantic-viewport header reflects a category edit optimistically,
        // but the multitrack lanes below read from the snapshot. Rebuild it so
        // the edited message moves to its new category lane — matching the
        // right-click Categories menu, which refreshes via onAfterMessageMutation.
        let baseSetClassification = actions.setClassification
        actions.setClassification = { [self] id, classification, customKeys in
            baseSetClassification(id, classification, customKeys)
            timelineData.invalidateAndRefreshIfBound()
        }
        return actions
    }

    /// The action bundle handed to the Projects lens (workroom cards, Deadlines
    /// rows / focused reader, right control column). It starts from the shared
    /// `frontPageMessageActions`, so delete and send-to-Composer already route
    /// through the host paths that fire the red Collapse / launch on the active
    /// (Projects) coordinator. Only resolve needs wrapping here: like Timeline,
    /// the resolved message stays in the Projects snapshot (the workroom is the
    /// full dossier), so its green Collapse is fired and settled explicitly rather
    /// than relying on a snapshot-drop reconcile.
    @MainActor
    private func projectsMessageActions(workspace: ProjectsWorkspaceState) -> FrontPageMessageActionHandlers {
        var actions = frontPageMessageActions
        actions.setClassification = { [self] id, classification, customKeys in
            applyUserClassification(
                messageId: id.uuidString,
                classification: classification,
                customCategoryKeys: customKeys,
                reconcileProjects: false
            )
        }
        actions.setClassificationAndReportSuccess = { [self] id, classification, customKeys in
            applyUserClassification(
                messageId: id.uuidString,
                classification: classification,
                customCategoryKeys: customKeys,
                reconcileProjects: false
            )
        }
        let baseSetResolved = actions.setResolved
        actions.setResolved = { [weak workspace] ids, value in
            // Only animate on a surface that hosts the overlay (workroom /
            // Deadlines); on the Gantt the resolve applies immediately, as before.
            if value, let workspace, workspace.hasDepartingCardSurface {
                let now = Date()
                workspace.statusGestureCoordinator.begin(.resolve, for: ids, now: now)
                workspace.statusGestureCoordinator.scheduleDepartingSettle(
                    for: ids, startedAt: now, hold: ProjectsWorkspaceState.departingSettleHold
                )
            }
            baseSetResolved(ids, value)
        }
        return actions
    }

    /// Single-message right-click menu for a Front Page card / the reader.
    /// Mirrors `presentProjectsMessageContextMenu`: the cross-lens menu (Open
    /// in Focus, Read, Flag, Categories, Delete, Copy) plus explicit
    /// user-coding actions for resolved, reply, and confirmation state.
    @MainActor
    private func presentFrontPageMessageContextMenu(
        messageID: UUID,
        includesMessageProjectAction: Bool = true,
        readTargetIDs: [UUID]? = nil,
        at point: NSPoint,
        in view: NSView
    ) {
        let repository = ProjectLensActionRepository(modelContext: modelContext)
        let accountScopeKey = frontPageAccountScopeKey
        let actionState = repository.actionState(accountScopeKey: accountScopeKey)
        let isResolved = actionState.resolvedMessageIDs.contains(messageID)
        let isReplyNeededByUser = actionState.replyNeededMessageIDs.contains(messageID)
        let isRepliedByUser = actionState.repliedMessageIDs.contains(messageID)
        let isConfirmationNeededByUser = actionState.confirmationNeededMessageIDs.contains(messageID)
        let isConfirmedByUser = actionState.confirmedMessageIDs.contains(messageID)

        var extras: [ConstellationNodeContextMenu.Context.ExtraItem] = []
        extras.append(
            ConstellationNodeContextMenu.Context.ExtraItem(
                title: isResolved ? "Reopen Message" : "Mark Message Resolved",
                state: isResolved ? .on : .off,
                systemSymbolName: isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle"
            ) { [self] in
                // Begin the masking gesture only when *activating* the state, so
                // the right-click menu animates the same way the hover cluster
                // and right column do.
                if !isResolved {
                    frontPageWorkspace?.statusGestureCoordinator.begin(.resolve, for: [messageID])
                    if ResolvedActionFilterPolicy.criterion(
                        stored: state.filter.resolvedCriterion,
                        lens: .frontPage
                    ) == .excluded {
                        frontPageWorkspace?.removeResolvedArticles([messageID])
                    }
                }
                frontPageSetResolved([messageID], value: !isResolved)
            }
        )
        extras.append(
            ConstellationNodeContextMenu.Context.ExtraItem(
                title: isReplyNeededByUser ? "Clear Reply Needed" : "Mark Reply Needed",
                state: isReplyNeededByUser ? .on : .off,
                systemSymbolName: "arrowshape.turn.up.left"
            ) { [self] in
                if !isReplyNeededByUser { frontPageWorkspace?.statusGestureCoordinator.begin(.replyNeeded, for: [messageID]) }
                frontPageSetReplyNeeded([messageID], value: !isReplyNeededByUser)
            }
        )
        extras.append(
            ConstellationNodeContextMenu.Context.ExtraItem(
                title: isRepliedByUser ? "Mark Unreplied" : "Mark Replied",
                state: isRepliedByUser ? .on : .off,
                systemSymbolName: isRepliedByUser ? "arrowshape.turn.up.left" : "arrowshape.turn.up.left.fill"
            ) { [self] in
                if !isRepliedByUser { frontPageWorkspace?.statusGestureCoordinator.begin(.markReplied, for: [messageID]) }
                frontPageSetReplied([messageID], value: !isRepliedByUser)
            }
        )
        // Same confirmation-applicability gate as the Projects menu: the
        // two confirmation actions appear only when the message carries a
        // confirmation obligation or already-coded confirmation state.
        let article = frontPageWorkspace?.currentSnapshot?.article(id: messageID)
        let confirmationApplies = article == nil
            || article?.requiresConfirmation == true
            || article?.isConfirmed == true
            || isConfirmationNeededByUser
            || isConfirmedByUser
        if confirmationApplies {
            extras.append(
                ConstellationNodeContextMenu.Context.ExtraItem(
                    title: isConfirmationNeededByUser ? "Clear Confirmation Needed" : "Mark Confirmation Needed",
                    state: isConfirmationNeededByUser ? .on : .off,
                    systemSymbolName: "questionmark.circle"
                ) { [self] in
                    if !isConfirmationNeededByUser { frontPageWorkspace?.statusGestureCoordinator.begin(.confirmationNeeded, for: [messageID]) }
                    frontPageSetConfirmationNeeded([messageID], value: !isConfirmationNeededByUser)
                }
            )
            extras.append(
                ConstellationNodeContextMenu.Context.ExtraItem(
                    title: isConfirmedByUser ? "Mark Unconfirmed" : "Mark Confirmed",
                    state: isConfirmedByUser ? .on : .off,
                    systemSymbolName: isConfirmedByUser ? "xmark.seal" : "checkmark.seal"
                ) { [self] in
                    if !isConfirmedByUser { frontPageWorkspace?.statusGestureCoordinator.begin(.markConfirmed, for: [messageID]) }
                    frontPageSetConfirmed([messageID], value: !isConfirmedByUser)
                }
            )
        }

        presentMessageContextMenu(
            messageID: messageID,
            vectorIdForOverlayRelease: nil,
            includeCopyAction: true,
            includesMessageProjectAction: includesMessageProjectAction,
            readTargetIDs: readTargetIDs,
            extraItems: extras,
            onAfterMessageMutation: { [self] in
                invalidateSharedMessageAttentionSurfaces()
            },
            onAfterDelete: { [self] in
                frontPageWorkspace?.removeDeletedArticles([messageID])
                invalidateSharedMessageAttentionSurfaces()
                // Keep the People-lock ring selection in sync: if the deleted
                // message was the click-selected satellite, drop the selection
                // so the highlight + action column collapse. Mirrors the disc
                // group's `onAfterDelete` so both delete paths behave alike.
                if lockedRingSelectionMessageId == messageID.uuidString {
                    lockedRingSelectionMessageId = nil
                }
            },
            onFlagBegin: { [self] value in
                frontPageWorkspace?.statusGestureCoordinator.begin(.flag(raising: value), for: [messageID])
                // Same optimistic reflection as the button/bulk path so the
                // context-menu flag also confirms immediately and the gesture
                // does not loop until its safety expiry. The menu persists the
                // flag synchronously right after this.
                frontPageWorkspace?.applyFlagState(messageIDs: [messageID], isFlagged: value)
            },
            onDeleteBegin: { [self] in
                frontPageWorkspace?.statusGestureCoordinator.begin(.delete, for: [messageID])
            },
            at: point,
            in: view
        )
    }

    /// Bulk right-click menu for a multi-card Front Page selection. Target
    /// values for Read / Flag are resolved here (majority-flip) from the
    /// selected articles and baked into the menu.
    @MainActor
    private func presentFrontPageBulkMessageContextMenu(
        messageIDs: [UUID],
        at point: NSPoint,
        in view: NSView
    ) {
        guard !messageIDs.isEmpty else { return }
        let articles = messageIDs.compactMap { frontPageWorkspace?.currentSnapshot?.article(id: $0) }
        guard !articles.isEmpty else { return }
        // Derive every count from the *resolved* articles, not the requested
        // IDs: a stale selection (IDs no longer in the snapshot) would otherwise
        // skew the denominator and invert the majority-flip direction.
        let resolvedIDs = articles.map(\.id)
        let count = articles.count
        let flaggedCount = articles.filter(\.isFlagged).count
        let unreadCount = articles.filter(\.isUnread).count
        let actionableIDs = articles.filter(\.isActionable).map(\.id)
        let composerActionIDs = articles
            .filter { !$0.isSentByUser && !$0.isInComposerQueue }
            .map(\.id)
        let confirmationIDs = articles.filter(\.requiresConfirmation).map(\.id)
        let confirmedIDs = articles.filter(\.isConfirmed).map(\.id)
        let replyActionMarksReplied = !actionableIDs.isEmpty
        let confirmationActionMarksConfirmed = !confirmationIDs.isEmpty
        // Already-confirmed targets un-confirm (revert to needs-confirmation) —
        // the confirmation axis stays distinct from the dedicated Resolve item
        // below, which still owns "Mark N Resolved".
        let confirmationActionMarksUnconfirmed = !confirmationActionMarksConfirmed && !confirmedIDs.isEmpty
        let replyActionIDs = replyActionMarksReplied ? actionableIDs : resolvedIDs
        let confirmationActionIDs = confirmationActionMarksConfirmed
            ? confirmationIDs
            : (confirmationActionMarksUnconfirmed ? confirmedIDs : resolvedIDs)

        FrontPageBulkMessageMenu.present(
            at: point,
            in: view,
            context: FrontPageBulkMessageMenu.Context(
                count: count,
                // Majority unread → mark all read; otherwise mark all unread.
                readTargetValue: unreadCount > count / 2,
                // Majority not flagged → flag all; otherwise unflag all.
                flagTargetValue: flaggedCount <= count / 2,
                replyActionTitle: replyActionMarksReplied
                    ? "Mark \(replyActionIDs.count) Replied"
                    : "Mark \(replyActionIDs.count) Reply Needed",
                // Titles track whether each item fronts the Composer, per
                // ComposerOpenOnQueuePreference inverted by ⌥, so the label
                // matches the (preference-aware) closures below. Primary =
                // no-⌥ baseline; the alternate carries the ⌥ inversion.
                composerActionTitle: composerActionIDs.isEmpty
                    ? nil
                    : (ComposerOpenOnQueuePreference.opensComposer(optionHeld: false)
                        ? "Open \(composerActionIDs.count) in Composer"
                        : "Send \(composerActionIDs.count) to Composer"),
                composerOpenActionTitle: composerActionIDs.isEmpty
                    ? nil
                    : (ComposerOpenOnQueuePreference.opensComposer(optionHeld: true)
                        ? "Open \(composerActionIDs.count) in Composer"
                        : "Send \(composerActionIDs.count) to Composer"),
                confirmationActionTitle: {
                    if confirmationActionMarksConfirmed {
                        return "Mark \(confirmationActionIDs.count) Confirmed"
                    }
                    if confirmationActionMarksUnconfirmed {
                        return "Mark \(confirmationActionIDs.count) Unconfirmed"
                    }
                    return "Mark \(confirmationActionIDs.count) Confirmation Needed"
                }(),
                onSetRead: { [self] value in frontPageSetRead(resolvedIDs, value: value) },
                onSetFlagged: { [self] value in
                    frontPageWorkspace?.statusGestureCoordinator.begin(.flag(raising: value), for: resolvedIDs)
                    frontPageSetFlagged(resolvedIDs, value: value)
                },
                onMarkAsSpam: { [self] in _ = frontPageMarkAsSpamMessages(resolvedIDs) },
                onReplyAction: { [self] in
                    if replyActionMarksReplied {
                        frontPageWorkspace?.statusGestureCoordinator.begin(.markReplied, for: replyActionIDs)
                        frontPageSetReplied(replyActionIDs, value: true)
                    } else {
                        frontPageWorkspace?.statusGestureCoordinator.begin(.replyNeeded, for: replyActionIDs)
                        frontPageSetReplyNeeded(replyActionIDs, value: true)
                    }
                },
                onComposerAction: { [self] in frontPageSendToComposer(composerActionIDs, openComposer: ComposerOpenOnQueuePreference.opensComposer(optionHeld: false)) },
                onComposerActionAndOpen: { [self] in frontPageSendToComposer(composerActionIDs, openComposer: ComposerOpenOnQueuePreference.opensComposer(optionHeld: true)) },
                onConfirmationAction: { [self] in
                    if confirmationActionMarksConfirmed {
                        frontPageWorkspace?.statusGestureCoordinator.begin(.markConfirmed, for: confirmationActionIDs)
                        frontPageSetConfirmed(confirmationActionIDs, value: true)
                    } else if confirmationActionMarksUnconfirmed {
                        frontPageSetConfirmed(confirmationActionIDs, value: false)
                    } else {
                        frontPageWorkspace?.statusGestureCoordinator.begin(.confirmationNeeded, for: confirmationActionIDs)
                        frontPageSetConfirmationNeeded(confirmationActionIDs, value: true)
                    }
                },
                onMarkResolved: { [self] in
                    frontPageWorkspace?.statusGestureCoordinator.begin(.resolve, for: resolvedIDs)
                    frontPageSetResolved(resolvedIDs, value: true)
                },
                onDelete: { [self] in _ = frontPageDeleteMessages(resolvedIDs) }
            )
        )
    }

    @MainActor
    private func frontPageSetRead(_ ids: [UUID], value: Bool) {
        guard !ids.isEmpty else { return }
        let dispatcher = makeMailboxMutationDispatcher()
        var anyLocalOnly = false
        var successfullyReadIDs: Set<UUID> = []
        for id in ids {
            if let outcome = try? dispatcher.setRead(messageID: id, value: value) {
                if !outcome.propagatedToServer {
                    anyLocalOnly = true
                }
                frontPageWorkspace?.applyReadStateToFocusedArticle(messageID: id, isRead: value)
                if value {
                    successfullyReadIDs.insert(id)
                }
            }
        }
        retireReadNewStars(messageIDs: successfullyReadIDs)
        if anyLocalOnly { showLocalOnlyMutationNotice(action: value ? "mark read" : "mark unread") }
        performSharedMessageAttentionInvalidation(
            preservingFrontPageProjectDefinitions: true
        )
    }

    @MainActor
    private func meaningAutoMarkReadIfNeeded(
        record: VectorRecord,
        vectorId: Int64,
        trigger: MeaningAutoReadTrigger
    ) {
        guard let messageID = UUID(uuidString: record.messageId) else { return }
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first,
              Self.shouldAutoMarkMeaningMessageRead(
                activeFrame: state.activeFrame,
                trigger: trigger,
                targetVectorId: vectorId,
                hoveredVectorId: state.hoveredVectorId,
                lockedVectorId: state.lockedVectorId,
                hasProjectedHoverTarget: projectedHoverTarget != nil,
                isRead: message.isReadOrFalse
              ) else {
            return
        }

        frontPageSetRead([messageID], value: true)
    }

    @MainActor
    private func frontPageSetFlagged(
        _ ids: [UUID],
        value: Bool,
        registerUndo: Bool = true
    ) {
        let before = messageFlagStates(for: Set(ids))
        guard !before.isEmpty else { return }
        _ = applyFlagStates(
            Dictionary(uniqueKeysWithValues: before.keys.map { ($0, value) }),
            localOnlyAction: value ? "flag" : "unflag"
        )
        let after = messageFlagStates(for: Set(before.keys))
        guard registerUndo, before != after else { return }
        messageUndoTarget.registerSuccessfulAction(
            on: undoManager,
            actionName: value ? "Flag" : "Unflag",
            undo: { [self] in applyFlagStates(before) },
            redo: { [self] in applyFlagStates(after) }
        )
    }

    @MainActor
    private func frontPageSetReplyNeeded(_ ids: [UUID], value: Bool) {
        performUndoableSharedMessageAction(
            ids,
            actionName: value ? "Mark Reply Needed" : "Clear Reply Needed",
            mutation: { repository, id, scope in
                repository.setMessageReplyNeeded(value, messageID: id, accountScopeKey: scope)
            },
            optimisticAction: .replyNeeded(value)
        )
    }

    /// Queues the given messages into the Composer. When `openComposer` is true it
    /// also brings the Composer window to the front, focused on the first message
    /// queued (a bulk send lands on the first; the rest follow in the queue behind
    /// it). Callers derive `openComposer` from `ComposerOpenOnQueuePreference`
    /// (default on) XOR the ⌥ modifier at click time, so the default send fronts
    /// the Composer and ⌥ queues quietly (both inverted when the setting is off).
    @MainActor
    private func frontPageSendToComposer(_ ids: [UUID], openComposer: Bool) {
        guard !ids.isEmpty else { return }
        // A collapsed thread renders one representative gesture for multiple
        // members. They must share completion, or an undrawn sibling can retire
        // the package before its visible representative has finished.
        let departure = makeComposerCardDeparture(for: [])
        var focusMessageID: UUID?
        for id in ids {
            var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == id })
            descriptor.fetchLimit = 1
            guard let message = try? modelContext.fetch(descriptor).first,
                  !message.isSentByUser,
                  ComposerQueueMembership.canToggleNeedsReply(message) else {
                continue
            }
            do {
                try ComposerQueueMembership.setNeedsReply(true, message: message, context: modelContext)
                if focusMessageID == nil { focusMessageID = id }
                beginComposerDispatch(for: id, cardDeparture: departure)
            } catch {
                print("[Constellation] sendToComposer failed: \(String(reflecting: type(of: error)))")
            }
        }
        invalidateSharedMessageAttentionSurfaces()
        if openComposer, let focusMessageID {
            openComposerAfterDispatch(messageID: focusMessageID)
        }
    }

    /// Tail added past a departing gesture's own floor before a Timeline /
    /// Projects card surface (which keeps the acted-on message in its
    /// snapshot) holds before it settles/clears — long enough for the
    /// Collapse/Comet motion to play past its floor.
    private static let departingSettleTail: Double = 0.4

    /// Tail added past a departing gesture's own floor before the Timeline
    /// playhead advances off a departed message — deliberately a beat
    /// BEFORE the gesture settles (`departingSettleTail`), so the reader's
    /// content is already the next message (still faded out under the crumple)
    /// when the gesture clears and the reader fades back in. This orders the two
    /// timers deterministically, so the departed message can never flash back.
    private static let departingAdvanceTail: Double = 0.25

    /// The floor of the departing gesture just begun for `ids` on `coordinator`
    /// (every id in one `begin(...)` call shares the same action and floor, so
    /// the first match is authoritative), plus `tail`. Falls back to the shared
    /// `MessageStatusGesturePhase.departingFloor` if no gesture is found
    /// (defensive; every call site begins the gesture immediately before
    /// reading this). Computed dynamically from the live gesture rather than a
    /// fixed constant because delete's Black hole floor and resolve's
    /// Protostar floor (`blackHoleFloor` / `protostarFloor`) now each run
    /// longer than ignore / send-to-Composer's shared `departingFloor` — a
    /// fixed hold sized for the shared floor would clear a delete or resolve
    /// gesture, and advance the reader off it, before the longer motion
    /// finishes.
    @MainActor
    private static func departingHold(
        for ids: [UUID],
        on coordinator: MessageStatusGestureCoordinator?,
        tail: Double
    ) -> Double {
        let floor = coordinator
            .flatMap { c in ids.lazy.compactMap { c.gesture(for: $0)?.floor }.first }
            ?? MessageStatusGesturePhase.departingFloor
        return floor + tail
    }

    /// The status-gesture coordinator for the currently-active lens's departing
    /// exit animations (delete / resolve / send-to-Composer). Front Page,
    /// Timeline, and Projects each own one; the fire sites route through this so a
    /// gesture lands on whichever card surface is on screen. For non-departing
    /// lenses this resolves to the Front Page coordinator (nil when Front Page
    /// isn't mounted) — identical to the pre-existing behaviour, so those lenses
    /// are unchanged.
    @MainActor
    private var activeDepartingGestureCoordinator: MessageStatusGestureCoordinator? {
        switch state.activeFrame.spatialLens {
        case .timeline:
            return timelineWorkspace?.statusGestureCoordinator
        case .projects:
            // Only the workroom feed and the Deadlines surfaces render the
            // overlay. On the default Time / Gantt surface there is no card to
            // host the Collapse / Comet, so returning nil skips the gesture begin
            // (and its rebuild-hold) and the dot updates immediately, as before —
            // the launch comet still fires from `composerDispatch` for sends.
            guard let workspace = projectsWorkspace, workspace.hasDepartingCardSurface else { return nil }
            return workspace.statusGestureCoordinator
        default:
            return frontPageWorkspace?.statusGestureCoordinator
        }
    }

    /// Schedules the settle for a departing gesture on a card surface that keeps
    /// the acted-on message in its snapshot (Timeline reader; Projects workroom /
    /// Deadlines rows on resolve / send-to-Composer), so the overlay clears once
    /// its motion plays instead of humming until the coordinator's safety window.
    /// Routes to whichever lens is active; no-op elsewhere (Front Page clears via
    /// its snapshot-drop reconcile).
    @MainActor
    private func scheduleActiveLensDepartingSettle(_ ids: [UUID], startedAt: Date) {
        switch state.activeFrame.spatialLens {
        case .timeline:
            if let coordinator = timelineWorkspace?.statusGestureCoordinator {
                coordinator.scheduleDepartingSettle(
                    for: ids, startedAt: startedAt,
                    hold: Self.departingHold(for: ids, on: coordinator, tail: Self.departingSettleTail)
                )
            }
        case .projects:
            if let coordinator = projectsWorkspace?.statusGestureCoordinator {
                coordinator.scheduleDepartingSettle(
                    for: ids, startedAt: startedAt,
                    hold: Self.departingHold(for: ids, on: coordinator, tail: Self.departingSettleTail)
                )
            }
        default:
            break
        }
    }

    @MainActor
    private func makeComposerCardDeparture(for ids: [UUID]) -> ComposerCardDeparture? {
        guard activeDepartingGestureCoordinator != nil else { return nil }
        return ComposerCardDeparture(
            floor: MessageStatusGesturePhase.floor(for: .sentToComposer),
            sourceMessageIDs: Set(ids)
        )
    }

    @MainActor
    private func beginComposerDispatch(for id: UUID, cardDeparture: ComposerCardDeparture? = nil) {
        playComposerSound()
        // Colour the Metal/Canvas comet with the sent message's account colour
        // so each send carries its account's stellar hue (matches the toolbar
        // account chips).
        let tint = composerDispatchTint(for: id)
        let gestureCoordinator = activeDepartingGestureCoordinator
        let departure = cardDeparture ?? makeComposerCardDeparture(for: [id])
        departure?.addSource(id)
        // Meaning / People / Projects draw the Metal/Canvas comet from the node.
        composerDispatch.begin(id, duration: ComposerDispatchPhase.duration, tint: tint, cardDeparture: departure)
        // Front Page and Timeline instead play the card-exit Bolide in place in
        // the reader via the departing-gesture overlay; fire it on whichever
        // lens is active. Timeline keeps the sent message in its snapshot (it
        // isn't removed), so its gesture needs an explicit settle to clear. The
        // Bolide always carries the fixed Ohia yellow accent, not the account
        // colour — it reads as the app's own send confirmation, not a per-
        // account hue.
        let now = Date()
        gestureCoordinator?.begin(.sentToComposer, for: [id], now: now, tintOverride: OhiaColors.ohiaYellow, composerDeparture: departure)
        scheduleActiveLensDepartingSettle([id], startedAt: now)
        // Front Page reader in-place comet + drop the card from the grid (no-op on
        // Timeline — its reader keeps showing the now-queued message).
        frontPageWorkspace?.removeSentToComposerArticles([id])
    }

    /// The account colour for message `id`, used to tint its Metal/Canvas
    /// send-to-Composer comet (Meaning / People / Projects). Theme-adaptive
    /// (`constellationTint`) so pale account hues stay legible on the
    /// light-mode workspaces. Falls back to the pending-reply accent when the
    /// message has no account (e.g. an orphaned row). Resolved once per send,
    /// not per frame. The Front Page / Timeline card-exit Bolide does not use
    /// this — it carries the fixed Ohia yellow accent instead.
    @MainActor
    private func composerDispatchTint(for id: UUID) -> Color {
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
        let message = (try? modelContext.fetch(descriptor))?.first
        return message?.account?.accountColor.constellationTint ?? MessageStatusColors.pendingReply
    }

    @MainActor
    private func playComposerSound() {
        let filename = ComposerSoundPreference.resolvedFilename(
            from: UserDefaults.standard.string(forKey: ComposerSoundPreference.storageKey)
        )
        composerSoundPlayer.play(filename: filename)
    }

    /// Front only after rendered card motion AND its owning surface's transition
    /// complete. The dispatch coordinator owns/cancels this request so an earlier
    /// send cannot open a window over a newer animation. Never replace this with
    /// a sleep: queue preparation starts before the animation, but mounting the
    /// Composer shell competes with the source Canvas for the main actor.
    @MainActor
    private func openComposerAfterDispatch(messageID: UUID) {
        composerDispatch.openAfterDepartures {
            AppCommand.showFocus(messageID: messageID)
            // Once it's up, record where it landed so the next comet aims at it.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                ComposerDispatchHeading.captureComposerCenter()
            }
        }
    }

    @MainActor
    private func frontPageSetReplied(_ ids: [UUID], value: Bool) {
        performUndoableSharedMessageAction(
            ids,
            actionName: value ? "Mark Replied" : "Mark Unreplied",
            mutation: { repository, id, scope in
                repository.setMessageReplied(value, messageID: id, accountScopeKey: scope)
            },
            optimisticAction: .replied(value)
        )
    }

    @MainActor
    private func frontPageSetConfirmationNeeded(_ ids: [UUID], value: Bool) {
        performUndoableSharedMessageAction(
            ids,
            actionName: value ? "Mark Confirmation Needed" : "Clear Confirmation Needed",
            mutation: { repository, id, scope in
                repository.setMessageConfirmationNeeded(value, messageID: id, accountScopeKey: scope)
            },
            optimisticAction: .confirmationNeeded(value)
        )
    }

    @MainActor
    private func frontPageSetConfirmed(_ ids: [UUID], value: Bool) {
        var settledIDs: Set<UUID> = []
        let changed = performUndoableSharedMessageAction(
            ids,
            actionName: value ? "Mark Confirmed" : "Mark Unconfirmed",
            mutation: { repository, id, scope in
                let didChange = repository.setMessageConfirmed(
                    value,
                    messageID: id,
                    accountScopeKey: scope
                )
                if didChange, value { settledIDs.insert(id) }
                return didChange
            },
            optimisticAction: .confirmed(value)
        )
        if changed, value {
            settledIDs.forEach { markNewStarVisited(messageId: $0.uuidString) }
        }
    }

    @MainActor
    private func frontPageSetResolved(_ ids: [UUID], value: Bool) {
        var settledIDs: Set<UUID> = []
        let changed = performUndoableSharedMessageAction(
            ids,
            actionName: value ? "Mark Resolved" : "Reopen",
            mutation: { repository, id, scope in
                let didChange = repository.setMessageResolved(
                    value,
                    messageID: id,
                    accountScopeKey: scope
                )
                if didChange, value { settledIDs.insert(id) }
                return didChange
            },
            optimisticAction: nil
        )
        if changed, value {
            settledIDs.forEach { markNewStarVisited(messageId: $0.uuidString) }
        }
        if changed,
           value,
           ResolvedActionFilterPolicy.criterion(
               stored: state.filter.resolvedCriterion,
               lens: .frontPage
           ) == .excluded {
            frontPageWorkspace?.removeResolvedArticles(Set(ids))
        }
    }

    @MainActor
    @discardableResult
    private func performUndoableSharedMessageAction(
        _ ids: [UUID],
        actionName: String,
        mutation: (ProjectLensActionRepository, UUID, String) -> Bool,
        optimisticAction: FrontPageReaderAttentionAction?
    ) -> Bool {
        let uniqueIDs = Set(ids)
        guard !uniqueIDs.isEmpty else { return false }
        let before = ProjectLensAction.snapshotSharedMessageActions(
            messageIDs: uniqueIDs,
            in: modelContext
        )
        let repository = ProjectLensActionRepository(modelContext: modelContext)
        let scope = frontPageAccountScopeKey
        for id in uniqueIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            if mutation(repository, id, scope), let optimisticAction {
                frontPageWorkspace?.applyAttentionAction(optimisticAction, messageID: id)
            }
        }
        let after = ProjectLensAction.snapshotSharedMessageActions(
            messageIDs: uniqueIDs,
            in: modelContext
        )
        guard before != after else { return false }
        invalidateSharedMessageAttentionSurfaces()
        messageUndoTarget.registerSuccessfulAction(
            on: undoManager,
            actionName: actionName,
            undo: { [self] in restoreSharedMessageActions(before) },
            redo: { [self] in restoreSharedMessageActions(after) }
        )
        return true
    }

    @MainActor
    private func restoreSharedMessageActions(
        _ snapshot: ProjectLensSharedMessageActionSnapshot
    ) -> Bool {
        let repository = ProjectLensActionRepository(modelContext: modelContext)
        guard repository.restoreSharedMessageActions(snapshot) else { return false }
        invalidateSharedMessageAttentionSurfaces()
        return true
    }

    @MainActor
    private func messageFlagStates(for ids: Set<UUID>) -> [UUID: Bool] {
        var states: [UUID: Bool] = [:]
        for id in ids {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let message = try? modelContext.fetch(descriptor).first {
                states[id] = message.flaggedOrFalse
            }
        }
        return states
    }

    @MainActor
    @discardableResult
    private func applyFlagStates(
        _ states: [UUID: Bool],
        localOnlyAction: String? = nil
    ) -> Bool {
        guard !states.isEmpty else { return false }
        let dispatcher = makeMailboxMutationDispatcher()
        var applied: [UUID: Bool] = [:]
        var anyLocalOnly = false
        for (id, value) in states.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            do {
                let outcome = try dispatcher.setFlagged(messageID: id, value: value)
                applied[id] = value
                if !outcome.propagatedToServer { anyLocalOnly = true }
            } catch {
                print("[Constellation] flag restore failed: \(String(reflecting: type(of: error)))")
            }
        }
        for value in [false, true] {
            let ids = Set(applied.compactMap { $0.value == value ? $0.key : nil })
            if !ids.isEmpty {
                frontPageWorkspace?.applyFlagState(messageIDs: ids, isFlagged: value)
            }
        }
        if anyLocalOnly, let localOnlyAction {
            showLocalOnlyMutationNotice(action: localOnlyAction)
        }
        if !applied.isEmpty { invalidateSharedMessageAttentionSurfaces() }
        return !applied.isEmpty
    }

    @MainActor
    @discardableResult
    private func frontPageMarkAsSpamMessages(_ ids: [UUID]) -> Bool {
        markMessagesAsSpam(ids) { [self] movedIDs, _ in
            frontPageWorkspace?.removeDeletedArticles(movedIDs)
            if let selected = lockedRingSelectionMessageId,
               movedIDs.contains(where: { $0.uuidString == selected }) {
                lockedRingSelectionMessageId = nil
            }
            invalidateSharedMessageAttentionSurfaces()
        }
    }

    private struct RemovalAnimationContext {
        let messageIds: Set<String>
        let dyingPeople: Set<String>
        let releasedPeopleFocus: Bool
    }

    @MainActor
    @discardableResult
    private func markMessagesAsSpam(
        _ ids: [UUID],
        afterSuccessfulMove: ((Set<UUID>, RemovalAnimationContext) -> Void)? = nil
    ) -> Bool {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return false }

        if uniqueIDs.count == 1 {
            let targetID = uniqueIDs[0]
            var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == targetID })
            descriptor.fetchLimit = 1
            let subject = (try? modelContext.fetch(descriptor).first)?.subject ?? ""
            guard confirmMarkAsSpamNode(subject: subject) else { return false }
        } else {
            guard confirmMarkAsSpamMessages(count: uniqueIDs.count) else { return false }
        }

        let dispatcher = makeMailboxMutationDispatcher()
        var anyLocalOnly = false
        var junkUnavailable = false
        var acceptedIDs = Set<UUID>()
        var locallyRemovedIDs = Set<UUID>()
        for id in uniqueIDs {
            do {
                let outcome = try dispatcher.markAsSpam(messageID: id)
                acceptedIDs.insert(id)
                if !outcome.propagatedToServer {
                    anyLocalOnly = true
                    locallyRemovedIDs.insert(id)
                }
            } catch MailboxMutationDispatcher.Error.junkDestinationUnavailable {
                junkUnavailable = true
            } catch {
                print("[Constellation] mark as spam failed: \(String(reflecting: type(of: error)))")
            }
        }

        if junkUnavailable { showJunkMoveUnavailableNotice() }
        if anyLocalOnly { showLocalOnlyMutationNotice(action: "move to Spam") }
        if !locallyRemovedIDs.isEmpty {
            let movedMessageIds = Set(locallyRemovedIDs.map(\.uuidString))
            let dyingPeople = captureDyingSnapshots(messageIds: movedMessageIds)
            let releasedPeopleFocus = releasePeopleFocusIfDyingHubWasLocked(
                dyingPeople,
                deletedMessageIds: movedMessageIds
            )
            afterSuccessfulMove?(
                locallyRemovedIDs,
                RemovalAnimationContext(
                    messageIds: movedMessageIds,
                    dyingPeople: dyingPeople,
                    releasedPeopleFocus: releasedPeopleFocus
                )
            )
        }
        return !acceptedIDs.isEmpty
    }

    @MainActor
    @discardableResult
    private func frontPageDeleteMessages(
        _ ids: [UUID],
        confirm: Bool = true,
        registerUndo: Bool = true,
        afterSuccessfulDelete: ((Set<UUID>) -> Void)? = nil
    ) -> Bool {
        guard !ids.isEmpty else { return false }
        let deleteTarget: FrontPageThreadDeleteTarget
        if state.activeFrame.spatialLens == .frontPage, let frontPageWorkspace {
            deleteTarget = FrontPageThreadDeleteTarget.resolve(
                requested: ids,
                selectedCardIDs: frontPageWorkspace.selectedArticleIDs,
                composition: frontPageWorkspace.currentSnapshot?.composition,
                hasFocusedArticle: frontPageWorkspace.focusedArticleID != nil
            )
        } else {
            deleteTarget = FrontPageThreadDeleteTarget(messageIDs: ids, confirmation: nil)
        }
        let ids = deleteTarget.messageIDs

        // A selected Front Page thread keeps its card-level identity and email
        // count; other single and bulk deletes retain their existing prompts.
        // ⌘-Delete passes `confirm: false` to delete immediately without one.
        if confirm {
            if let threadConfirmation = deleteTarget.confirmation {
                guard confirmDeleteThread(threadConfirmation) else { return false }
            } else if ids.count == 1 {
                let targetID = ids[0]
                var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == targetID })
                descriptor.fetchLimit = 1
                let subject = (try? modelContext.fetch(descriptor).first)?.subject ?? ""
                guard confirmDeleteNode(subject: subject) else { return false }
            } else {
                guard confirmDeleteMessages(count: ids.count) else { return false }
            }
        }

        let dispatcher = makeMailboxMutationDispatcher()
        var anyLocalOnly = false
        var trashUnavailable = false
        var deletedIDs = Set<UUID>()
        for id in ids {
            do {
                let outcome = try dispatcher.delete(messageID: id)
                deletedIDs.insert(id)
                if !outcome.propagatedToServer { anyLocalOnly = true }
            } catch MailboxMutationDispatcher.Error.trashDestinationUnavailable {
                trashUnavailable = true
            } catch {
                print("[Constellation] front page delete failed: \(String(reflecting: type(of: error)))")
            }
        }
        if trashUnavailable { showTrashMoveUnavailableNotice() }
        if anyLocalOnly { showLocalOnlyMutationNotice(action: "move to Trash") }
        if !deletedIDs.isEmpty {
            let deletedMessageIds = Set(deletedIDs.map(\.uuidString))
            let dyingPeople = captureDyingSnapshots(messageIds: deletedMessageIds)
            releasePeopleFocusIfDyingHubWasLocked(
                dyingPeople,
                deletedMessageIds: deletedMessageIds
            )
            NewMailArrivalLedger.shared.removeArrivals(messageIds: deletedMessageIds)
            afterSuccessfulDelete?(deletedIDs)
            // Begin the delete masking gesture only now — post-confirmation and
            // post-dispatch — so a cancelled alert never leaves a lingering
            // overlay. The card stays in the snapshot until the rebuild lands, so
            // its red collapse-inward overlay plays during that latency and the
            // per-action exit transition fires when the snapshot drops it. Routes
            // to the active lens's coordinator so the Timeline reader animates too.
            let deleteStart = Date()
            activeDepartingGestureCoordinator?.begin(.delete, for: Array(deletedIDs), now: deleteStart)
            scheduleActiveLensDepartingSettle(Array(deletedIDs), startedAt: deleteStart)
        }
        frontPageWorkspace?.removeDeletedArticles(deletedIDs)
        invalidateSharedMessageAttentionSurfaces()
        if registerUndo, !deletedIDs.isEmpty {
            messageUndoTarget.registerSuccessfulAsyncAction(
                on: undoManager,
                actionName: "Delete",
                messageIDs: deletedIDs,
                undo: { [self] messageIDs in
                    await restoreDeletedMessages(messageIDs)
                },
                redo: { [self] messageIDs in
                    var successfullyDeleted = Set<UUID>()
                    _ = frontPageDeleteMessages(
                        Array(messageIDs),
                        confirm: false,
                        registerUndo: false,
                        afterSuccessfulDelete: { successfullyDeleted.formUnion($0) }
                    )
                    return successfullyDeleted
                }
            )
        }
        return !deletedIDs.isEmpty
    }

    @MainActor
    private func restoreDeletedMessages(_ ids: Set<UUID>) async -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let dispatcher = makeMailboxMutationDispatcher()
        var restoredLocally = Set<UUID>()
        var remoteReferences: [TrashRestoreReference] = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                switch try await dispatcher.restoreFromTrash(messageID: id) {
                case .restoredLocally:
                    restoredLocally.insert(id)
                case .requiresRemotePromotion:
                    var descriptor = FetchDescriptor<Message>(
                        predicate: #Predicate<Message> { $0.id == id }
                    )
                    descriptor.fetchLimit = 1
                    guard let message = try modelContext.fetch(descriptor).first,
                          let reference = TrashRestoreReference(message: message) else {
                        continue
                    }
                    remoteReferences.append(reference)
                }
            } catch {
                print("[Constellation] undo Trash move failed: \(String(reflecting: type(of: error)))")
            }
        }

        if !restoredLocally.isEmpty {
            invalidateSharedMessageAttentionSurfaces()
        }
        if !remoteReferences.isEmpty {
            restoredLocally.formUnion(await restoreRemoteTrash(remoteReferences))
        }
        return restoredLocally
    }

    @MainActor
    private func restoreRemoteTrash(_ references: [TrashRestoreReference]) async -> Set<UUID> {
        // A running move-to-Trash may need a short moment to appear in the
        // provider's Trash mailbox. Reuse the transient Withheld fetch and
        // ingest-first promotion path; never reconstruct vectors or files.
        var restoredMessageIDs = Set<UUID>()
        for attempt in 0..<8 {
            await withheldModel.load(
                accounts: accounts,
                oauthStore: OAuthTokenStore(allowKeychainInteraction: false),
                modelContext: modelContext
            )
            for reference in references where isMessageTrashed(reference.messageID) == false {
                restoredMessageIDs.insert(reference.messageID)
            }
            let pending = references.filter { reference in
                !restoredMessageIDs.contains(reference.messageID)
                    && isMessageTrashed(reference.messageID) == true
            }
            if restoredMessageIDs.count == references.count { return restoredMessageIDs }

            let rows = withheldModel.rows.filter { row in
                guard row.folder == .trash,
                      !row.folderPath.isEmpty,
                      row.uid > 0,
                      row.uidValidity > 0 else {
                    return false
                }
                return pending.contains { reference in
                    reference.accountID == row.accountID
                        && row.localMessageID == reference.messageID
                }
            }
            if !rows.isEmpty {
                _ = await restoreWithheldRowsAndWait(rows)
            }
            for reference in references where isMessageTrashed(reference.messageID) == false {
                restoredMessageIDs.insert(reference.messageID)
            }
            if restoredMessageIDs.count == references.count {
                return restoredMessageIDs
            }
            if attempt < 7 {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Keep the retained messages intact and expose Trash for a manual
        // retry if the provider has not surfaced the moved rows yet.
        setWithheldVisible(true)
        return restoredMessageIDs
    }

    /// Thread-specific confirmation for a selected Front Page package.
    @MainActor
    private func confirmDeleteThread(
        _ confirmation: FrontPageThreadDeleteTarget.Confirmation
    ) -> Bool {
        guard DeletionConfirmationPreference.showsMoveToTrashConfirmation() else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.messageText
        alert.informativeText = confirmation.informativeText
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Count-based confirmation for a bulk Front Page move to Trash.
    @MainActor
    private func confirmDeleteMessages(count: Int) -> Bool {
        guard DeletionConfirmationPreference.showsMoveToTrashConfirmation() else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(count) emails?"
        alert.informativeText = "They will be moved to the account Trash mailbox."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if let firstButton = alert.buttons.first {
            // Make the Delete button the default so Return/Enter confirms. We must
            // NOT set hasDestructiveAction here: it deliberately suppresses the
            // Return key equivalent (that is its whole purpose) and NSAlert re-applies
            // that suppression during layout, which is exactly why Return wasn't
            // confirming. Cancel keeps Escape via NSAlert's automatic assignment.
            firstButton.keyEquivalent = "\r"
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Count-based confirmation for a bulk move to the account Spam/Junk folder.
    @MainActor
    private func confirmMarkAsSpamMessages(count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Mark \(count) emails as spam?"
        alert.informativeText = "They will be moved to the account Spam or Junk mailbox."
        alert.addButton(withTitle: "Mark as spam")
        alert.addButton(withTitle: "Cancel")
        if let firstButton = alert.buttons.first {
            firstButton.hasDestructiveAction = true
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func presentProjectsRowContextMenu(
        row: ProjectRow,
        at point: NSPoint,
        in view: NSView
    ) {
        let repository = MailProjectRepository(modelContext: modelContext)
        projectsWorkspace?.focusProject(row.projectKey)
        ProjectsContextMenu.presentRow(
            at: point,
            in: view,
            context: ProjectsContextMenu.RowContext(
                row: row,
                onConfigure: { [self] in
                    projectsWorkspace?.requestProjectConfiguration(projectID: row.projectID)
                },
                onRename: { [self] in
                    projectsWorkspace?.beginRenaming(row.projectKey)
                },
                onSetPinned: { [self] pinned in
                    guard let workspace = projectsWorkspace else { return }
                    performProjectsLifecycleMutation(
                        workspace: workspace,
                        action: pinned ? .pin : .unpin
                    ) {
                        try repository.setPinned(projectID: row.projectID, pinned)
                    }
                },
                onSetResolved: { [self] resolved in
                    guard let workspace = projectsWorkspace else { return }
                    performProjectsLifecycleMutation(
                        workspace: workspace,
                        action: resolved ? .resolve : .reopen
                    ) {
                        try repository.setResolved(projectID: row.projectID, resolved)
                    }
                },
                onDelete: { [self] in
                    projectsWorkspace?.requestProjectDeletion(row)
                }
            )
        )
    }

    @MainActor
    private func presentNodeContextMenu(
        proxy: HitProxy,
        messageID: UUID,
        at point: NSPoint,
        in view: NSView
    ) {
        presentMessageContextMenu(
            messageID: messageID,
            vectorIdForOverlayRelease: proxy.vectorId,
            at: point,
            in: view
        )
    }

    /// Lens-agnostic context-menu presenter. The constellation scene
    /// calls this via `presentNodeContextMenu` with the right-clicked
    /// node's vectorId so the locked overlay can release on delete; the
    /// Timeline email pane passes `vectorIdForOverlayRelease: nil`
    /// because no constellation node owns the click.
    @MainActor
    private func presentMessageContextMenu(
        messageID: UUID,
        vectorIdForOverlayRelease: Int64?,
        includeCopyAction: Bool = false,
        includesMessageProjectAction: Bool = true,
        readTargetIDs: [UUID]? = nil,
        extraItems: [ConstellationNodeContextMenu.Context.ExtraItem] = [],
        onAfterMessageMutation: (() -> Void)? = nil,
        onAfterDelete: (() -> Void)? = nil,
        // Lens-scoped masking hooks (Front Page passes these). `onFlagBegin` is
        // called with the new flagged value before the flag mutation; `onDeleteBegin`
        // after a confirmed, successful delete dispatch. Other callers pass nil.
        onFlagBegin: ((Bool) -> Void)? = nil,
        onDeleteBegin: (() -> Void)? = nil,
        at point: NSPoint,
        in view: NSView
    ) {
        // Hover popup must close: the menu visually replaces it, and a
        // residual tether line under the menu reads as broken.
        state.hoveredVectorId = nil
        hoverNodePoint = .zero

        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == messageID })
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first else { return }

        let messageId = messageID.uuidString
        let currentClassification = effectiveClassification(messageId: messageId, message: message)
        let currentCustomKeys = effectiveCustomCategoryKeys(messageId: messageId, message: message)
        let messageQueuedInComposer = ComposerQueueMembership.isInQueue(message)
        let projectDestinations = makeProjectMenuDestinations(
            messageID: messageID,
            threadID: message.thread?.id,
            onAfterMutation: onAfterMessageMutation
        )
        let customEntries = customCategoryStore.descriptors.map { descriptor in
            ConstellationNodeContextMenu.Context.CustomCategoryEntry(
                key: descriptor.key,
                title: CustomCategoryStore.menuLabel(for: descriptor),
                isChecked: currentCustomKeys.contains(descriptor.key)
            )
        }

        let dispatcher = makeMailboxMutationDispatcher()
        var menuExtraItems = extraItems
        if MailingListIgnoreRuleService.isEligibleListMessage(message) {
            menuExtraItems.append(
                ConstellationNodeContextMenu.Context.ExtraItem(
                    title: "Ignore emails like this",
                    systemSymbolName: "eye.slash"
                ) { [self] in
                    beginListIgnore(
                        messageID: messageID,
                        vectorIdForOverlayRelease: vectorIdForOverlayRelease,
                        onAfterMessageMutation: onAfterMessageMutation,
                        onAfterDelete: onAfterDelete
                    )
                }
            )
        }

        let context = ConstellationNodeContextMenu.Context(
            message: message,
            currentClassification: currentClassification,
            onSetRead: { [self] value in
                if let readTargetIDs {
                    frontPageSetRead(readTargetIDs, value: value)
                } else {
                    do {
                        let outcome = try dispatcher.setRead(messageID: messageID, value: value)
                        if !outcome.propagatedToServer {
                            showLocalOnlyMutationNotice(action: value ? "mark read" : "mark unread")
                        }
                        if value {
                            retireReadNewStars(messageIDs: [messageID])
                        }
                        onAfterMessageMutation?()
                    } catch {
                        print("[Constellation] setRead failed: \(String(reflecting: type(of: error)))")
                    }
                }
            },
            onSetFlagged: { [self] value in
                onFlagBegin?(value)
                frontPageSetFlagged([messageID], value: value)
                onAfterMessageMutation?()
            },
            // Visible on any inbound message — needs-reply is no longer required.
            // When already queued the item navigates ("Open in Composer"); when
            // not yet queued it adds it ("Send to Composer"). Sent mail is the
            // only exclusion: there is nothing to draft a reply to.
            composerQueueActionVisible: !message.isSentByUser,
            composerQueueActionEnabled: ComposerQueueMembership.canToggleNeedsReply(message),
            composerQueueActionIsQueued: messageQueuedInComposer,
            onSendToComposer: { [self] in
                do {
                    try ComposerQueueMembership.setNeedsReply(
                        true,
                        message: message,
                        context: modelContext
                    )
                    // Default item (no ⌥). Fronts the Composer when the
                    // "Open Composer when queued" setting is on (the default).
                    let opens = ComposerOpenOnQueuePreference.opensComposer(optionHeld: false)
                    beginComposerDispatch(for: messageID)
                    onAfterMessageMutation?()
                    if opens { openComposerAfterDispatch(messageID: messageID) }
                } catch {
                    print("[Constellation] setNeedsReply failed: \(String(reflecting: type(of: error)))")
                }
            },
            onSendToComposerAndOpen: { [self] in
                do {
                    try ComposerQueueMembership.setNeedsReply(
                        true,
                        message: message,
                        context: modelContext
                    )
                    // ⌥ alternate: inverts the default fronting decision — quiet
                    // when the setting is on, opens when it is off.
                    let opens = ComposerOpenOnQueuePreference.opensComposer(optionHeld: true)
                    beginComposerDispatch(for: messageID)
                    onAfterMessageMutation?()
                    if opens { openComposerAfterDispatch(messageID: messageID) }
                } catch {
                    print("[Constellation] setNeedsReply failed: \(String(reflecting: type(of: error)))")
                }
            },
            onOpenInComposer: {
                // The message is already in the queue; jump to the Composer
                // focused on its draft instead of re-adding it.
                AppCommand.showFocus(messageID: messageID)
            },
            messageProjectDestinations: includesMessageProjectAction ? projectDestinations.message : nil,
            threadProjectDestinations: projectDestinations.thread,
            onSetPurpose: { [self] purpose in
                applyUserClassification(
                    messageId: messageId,
                    classification: .userAssigned(purpose: purpose),
                    customCategoryKeys: currentCustomKeys
                )
                onAfterMessageMutation?()
            },
            customCategories: customEntries,
            onToggleCustomCategory: { [self] key in
                var nextCustom = currentCustomKeys
                if nextCustom.contains(key) {
                    nextCustom.remove(key)
                } else {
                    nextCustom.insert(key)
                }
                applyUserClassification(
                    messageId: messageId,
                    classification: currentClassification,
                    customCategoryKeys: nextCustom
                )
                onAfterMessageMutation?()
            },
            onMarkAsSpam: { [self] in
                let moved = markMessagesAsSpam([messageID]) { movedIDs, removalContext in
                    guard movedIDs.contains(messageID) else { return }
                    if let vectorId = vectorIdForOverlayRelease,
                       state.lockedVectorId == vectorId,
                       !removalContext.releasedPeopleFocus {
                        scheduleLockedDeletionReturnAfterAnimation(
                            messageIds: removalContext.messageIds,
                            dyingPeople: removalContext.dyingPeople,
                            lockedVectorId: vectorId
                        )
                    }
                    onAfterDelete?()
                }
                if moved {
                    Task { await refreshSceneData() }
                }
            },
            onDelete: { [self] in
                _ = frontPageDeleteMessages([messageID]) { _ in
                    onDeleteBegin?()
                    let deletedMessageIds = Set([messageID.uuidString])
                    let dyingPeople = captureDyingSnapshots(messageIds: deletedMessageIds)
                    let releasedPeopleFocus = releasePeopleFocusIfDyingHubWasLocked(
                        dyingPeople,
                        deletedMessageIds: deletedMessageIds
                    )
                    // The locked overlay (if attached to this node) releases
                    // after a successful dispatch so failed Trash moves leave
                    // the still-present message inspectable.
                    if let vectorId = vectorIdForOverlayRelease,
                       state.lockedVectorId == vectorId,
                       !releasedPeopleFocus {
                        scheduleLockedDeletionReturnAfterAnimation(
                            messageIds: deletedMessageIds,
                            dyingPeople: dyingPeople,
                            lockedVectorId: vectorId
                        )
                    }
                    // Lens-specific post-delete hook — the Timeline
                    // pane uses this to advance its playhead to the
                    // next chronological message so the email pane
                    // doesn't keep displaying the deleted one. The
                    // scene path passes nil and the click-source
                    // hover ring releases on the next render.
                    onAfterDelete?()
                }
            },
            includeCopyAction: includeCopyAction,
            extraItems: menuExtraItems
        )

        ConstellationNodeContextMenu.present(at: point, in: view, context: context)
    }

    @MainActor
    private func makeProjectMenuDestinations(
        messageID: UUID,
        threadID: UUID?,
        onAfterMutation: (() -> Void)?
    ) -> (
        message: [ConstellationNodeContextMenu.ProjectDestination],
        thread: [ConstellationNodeContextMenu.ProjectDestination]?
    ) {
        let readContext = ModelContext(modelContext.container)
        do {
            let projects = try readContext.fetch(FetchDescriptor<MailProject>())
            let targetMessageID = messageID
            let memberships = try readContext.fetch(FetchDescriptor<MailProjectMembership>(
                predicate: #Predicate { $0.messageID == targetMessageID }
            ))
            let messageProjectIDs = Set(memberships.map(\.projectID))

            let threadProjectIDs: Set<UUID>
            if let threadID {
                let decisions = try readContext.fetch(FetchDescriptor<MailProjectDecision>())
                threadProjectIDs = Set(decisions.compactMap { decision in
                    guard decision.targetKind == .thread,
                          decision.targetID == threadID,
                          decision.decision == .include else {
                        return nil
                    }
                    return decision.projectID
                })
            } else {
                threadProjectIDs = []
            }

            let messageDestinations = projects.map { project in
                ConstellationNodeContextMenu.ProjectDestination(
                    id: project.id,
                    title: project.displayName,
                    isPinned: project.isPinned,
                    pinSortIndex: project.pinSortIndex,
                    resolvedAt: project.resolvedAt,
                    isIncluded: messageProjectIDs.contains(project.id)
                ) { [self, projectID = project.id] in
                    do {
                        let writeContext = ModelContext(modelContext.container)
                        let repository = ManualProjectMembershipRepository(modelContext: writeContext)
                        try repository.setMessageDecision(
                            projectID: projectID,
                            messageID: messageID,
                            included: true
                        )
                        onAfterMutation?()
                    } catch {
                        NSSound.beep()
                        print("[Constellation] add message to project failed: \(String(reflecting: type(of: error)))")
                    }
                }
            }

            let threadDestinations = threadID.map { threadID in
                projects.map { project in
                    ConstellationNodeContextMenu.ProjectDestination(
                        id: project.id,
                        title: project.displayName,
                        isPinned: project.isPinned,
                        pinSortIndex: project.pinSortIndex,
                        resolvedAt: project.resolvedAt,
                        isIncluded: threadProjectIDs.contains(project.id)
                    ) { [self, projectID = project.id] in
                        do {
                            let writeContext = ModelContext(modelContext.container)
                            let repository = ManualProjectMembershipRepository(modelContext: writeContext)
                            try repository.addThread(projectID: projectID, threadID: threadID)
                            onAfterMutation?()
                        } catch {
                            NSSound.beep()
                            print("[Constellation] add thread to project failed: \(String(reflecting: type(of: error)))")
                        }
                    }
                }
            }

            return (messageDestinations, threadDestinations)
        } catch {
            print("[Constellation] project menu snapshot failed: \(String(reflecting: type(of: error)))")
            return ([], threadID == nil ? nil : [])
        }
    }

    @MainActor
    private func beginListIgnore(
        messageID: UUID,
        vectorIdForOverlayRelease: Int64? = nil,
        onAfterMessageMutation: (() -> Void)? = nil,
        onAfterDelete: (() -> Void)? = nil
    ) {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first,
              let draft = makeMailingListIgnoreRuleService().draftRule(for: message) else {
            return
        }

        let lockedVectorId: Int64? = vectorIdForOverlayRelease ?? {
            guard let candidate = state.lockedVectorId,
                  let record = visibleRecordCache[candidate] ?? citationSourceRecord(vectorId: candidate),
                  record.messageId == messageID.uuidString else {
                return nil
            }
            return candidate
        }()
        beginListIgnore(
            draft: draft,
            messageID: messageID,
            vectorIdForOverlayRelease: lockedVectorId,
            onAfterMessageMutation: onAfterMessageMutation,
            onAfterDelete: onAfterDelete
        )
    }

    /// Confirms, then files a list-ignore. Every Ignore affordance in every
    /// lens — control-column disc and right-click item alike — funnels through
    /// here, so the prompt in `confirmListIgnoreRule` is the single gate.
    ///
    /// The prompt is not suppressible, unlike delete's: filing a rule silently
    /// trashes *future* mail from the list, and this dialog is the only place
    /// that scope is disclosed. Once confirmed, the Cinder exit plays and the
    /// message moves to Trash. The rule scope, technical evidence, and
    /// per-message history stay inspectable — and adjustable (broaden / narrow
    /// / revoke / restore) — in Settings → Lists.
    @MainActor
    private func beginListIgnore(
        draft: MailingListIgnoreRuleDraft,
        messageID: UUID,
        vectorIdForOverlayRelease: Int64?,
        onAfterMessageMutation: (() -> Void)? = nil,
        onAfterDelete: (() -> Void)? = nil
    ) {
        let dispatch = ListIgnoreDispatch(
            messageID: messageID,
            vectorIdForOverlayRelease: vectorIdForOverlayRelease,
            onAfterMessageMutation: onAfterMessageMutation,
            onAfterDelete: onAfterDelete
        )
        confirmListIgnoreRule(dispatch, draft: draft)
    }

    /// Modal confirmation for filing a list-ignore rule. Mirrors the delete
    /// alert's idiom (warning style, default button confirms on Return, Escape
    /// cancels) and adds a smaller secondary note spelling out that the rule
    /// covers the whole list and where it can be undone.
    ///
    /// Deliberately has no suppression checkbox — see `beginListIgnore`.
    @MainActor
    private func confirmListIgnoreAlert(draft: MailingListIgnoreRuleDraft) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning

        let listName = Self.listIgnoreDisplayName(for: draft)
        alert.messageText = "Ignore “\(listName)”?"

        let trimmedSubject = draft.evidenceSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySubject = trimmedSubject.isEmpty ? "(no subject)" : trimmedSubject
        alert.informativeText = """
        “\(displaySubject)” will be moved to Trash now, and future messages \
        from this list will be moved automatically.
        """

        alert.accessoryView = Self.listIgnoreNoteView()
        alert.addButton(withTitle: "Ignore")
        alert.addButton(withTitle: "Cancel")
        if let confirmButton = alert.buttons.first {
            // Same reasoning as `confirmDeleteNode`: set the key equivalent
            // rather than `hasDestructiveAction`, which suppresses Return.
            confirmButton.keyEquivalent = "\r"
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The list's friendliest available name, falling back through the draft's
    /// resolved label and raw `List-ID` so the title is never empty.
    static func listIgnoreDisplayName(for draft: MailingListIgnoreRuleDraft) -> String {
        for candidate in [draft.listDisplayName, draft.displayLabel, draft.listId] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "this mailing list"
    }

    /// The small print under the alert body: what Ignore actually does, and
    /// where to undo it.
    private static func listIgnoreNoteView() -> NSView {
        let note = NSTextField(wrappingLabelWithString: """
        Ignoring files a rule for the whole list, not just this message. \
        You can review, narrow, or revoke it in Settings → Lists.
        """)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.isEditable = false
        note.isSelectable = false
        note.drawsBackground = false
        // NSAlert lays accessory views out at a fixed width, so size to fit
        // the standard alert content column and let the height follow.
        let width: CGFloat = 280
        note.preferredMaxLayoutWidth = width
        let height = note.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        note.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return note
    }

    @MainActor
    private func confirmListIgnoreRule(
        _ review: ListIgnoreDispatch,
        draft: MailingListIgnoreRuleDraft
    ) {
        // Ask before anything is mutated or animated — a cancel must leave the
        // message exactly where it was, so this precedes the Cinder exit.
        guard confirmListIgnoreAlert(draft: draft) else { return }

        let activeLens = state.activeFrame.spatialLens
        let ignoreCoordinator: MessageStatusGestureCoordinator? = switch activeLens {
        case .frontPage, .timeline:
            activeDepartingGestureCoordinator
        default:
            nil
        }
        let ignoreStart = Date()
        ignoreCoordinator?.begin(.ignore, for: [review.messageID], now: ignoreStart)
        do {
            let outcome = try makeMailingListIgnoreRuleService()
                .createRuleAndApplyToEvidence(draft: draft)
            let deletedMessageIds = Set([review.messageID.uuidString])
            let dyingPeople = captureDyingSnapshots(messageIds: deletedMessageIds)
            let releasedPeopleFocus = releasePeopleFocusIfDyingHubWasLocked(
                dyingPeople,
                deletedMessageIds: deletedMessageIds
            )
            if let vectorId = review.vectorIdForOverlayRelease,
               state.lockedVectorId == vectorId,
               !releasedPeopleFocus {
                scheduleLockedDeletionReturnAfterAnimation(
                    messageIds: deletedMessageIds,
                    dyingPeople: dyingPeople,
                    lockedVectorId: vectorId
                )
            }
            NewMailArrivalLedger.shared.removeArrivals(messageIds: deletedMessageIds)
            if !outcome.propagatedToServer {
                showLocalOnlyMutationNotice(action: "move ignored message to Trash")
            }
            review.onAfterMessageMutation?()
            review.onAfterDelete?()
            if state.activeFrame.spatialLens == .projects {
                projectsData.invalidateAndRefresh()
                syncNewStarNavigatorWithCurrentMessageIndex()
            } else if state.activeFrame.spatialLens == .frontPage {
                frontPageWorkspace?.removeDeletedArticles([review.messageID])
                let hold = ignoreCoordinator?.remainingDepartingHold() ?? 0
                frontPageData.invalidateAndRefresh(holdingFor: hold)
                syncNewStarNavigatorWithCurrentMessageIndex()
            } else if state.activeFrame.spatialLens == .timeline {
                scheduleActiveLensDepartingSettle([review.messageID], startedAt: ignoreStart)
                timelineData.invalidateAndRefreshIfBound()
                let advanceDelay = Self.departingHold(
                    for: [review.messageID], on: ignoreCoordinator, tail: Self.departingAdvanceTail
                )
                Task { @MainActor [weak workspace = timelineWorkspace] in
                    try? await Task.sleep(for: .seconds(advanceDelay))
                    workspace?.advancePlayheadAfterDeletion(of: review.messageID)
                }
            } else if Self.usesMetalScene(state.activeFrame) {
                Task { await refreshSceneData() }
            }
        } catch MailboxMutationDispatcher.Error.trashDestinationUnavailable {
            ignoreCoordinator?.clear(review.messageID)
            showTrashMoveUnavailableNotice()
        } catch {
            ignoreCoordinator?.clear(review.messageID)
            print("[Constellation] list ignore rule creation failed: \(String(reflecting: type(of: error)))")
        }
    }

    // MARK: - Edit-menu parity for the right-click context menu

    /// The currently locked node's UUID, mirrored into the locked-node
    /// AppStorage key by `enterSelectedNodeFocus` /
    /// `leaveSelectedNodeFocus` and read here when an Edit-menu item
    /// fires.
    @MainActor
    private var lockedNodeMessageID: UUID? {
        guard !lockedNodeIDStorage.isEmpty,
              let uuid = UUID(uuidString: lockedNodeIDStorage) else { return nil }
        return uuid
    }

    @MainActor
    private var sendAgainCommandTarget: SendAgainCommandTarget? {
        guard !sendAgainInFlight,
              let messageID = selectedSentMessageIDForSendAgain else { return nil }
        return SendAgainCommandTarget { immediately in
            handleSendAgain(messageID: messageID, immediately: immediately)
        }
    }

    @MainActor
    private var focusedEmailPrintCommandTarget: FocusedEmailPrintCommandTarget? {
        guard !focusedEmailPrintInFlight,
              let selection = focusedEmailPrintSelection else { return nil }
        return FocusedEmailPrintCommandTarget {
            handleFocusedEmailPrint(selection: selection)
        }
    }

    @MainActor
    private func handleFocusedEmailPrint(selection: FocusedEmailPrintSelection) {
        guard !focusedEmailPrintInFlight else { return }
        focusedEmailPrintInFlight = true
        Task { @MainActor in
            defer { focusedEmailPrintInFlight = false }
            await FocusedEmailPrintCoordinator.print(
                selection: selection,
                modelContext: modelContext
            )
        }
    }

    @MainActor
    private var focusedEmailPrintSelection: FocusedEmailPrintSelection? {
        let metalMessageID = state.lockedVectorId.flatMap { vectorID in
            (visibleRecordCache[vectorID] ?? citationSourceRecord(vectorId: vectorID))?.messageId
        }.flatMap(UUID.init(uuidString:))
        let peopleMessageID = liveLockPersonFocus == nil
            ? nil
            : lockedRingSelectionMessageId.flatMap(UUID.init(uuidString:))

        let projectsMessageID: UUID?
        let projectsDeadlineMessageID: UUID?
        let projectsContextTitle: String?
        if let workspace = projectsWorkspace {
            projectsMessageID = workspace.workroomExpandedMessageID
                ?? workspace.messageReadout.flatMap { readout in
                    readout.expanded && readout.expandedMode == .message
                        ? readout.messageID
                        : nil
                }
            if workspace.lensTab == .deadlines,
               let openedDeadlineID = workspace.openedDeadlineID,
               let entry = workspace.deadlineTracker().entry(id: openedDeadlineID) {
                projectsDeadlineMessageID = entry.representativeMessageID
                projectsContextTitle = entry.title
            } else {
                projectsDeadlineMessageID = nil
                projectsContextTitle = workspace.focusedRow?.displayLabel
                    ?? workspace.workroomAnchorRow?.displayLabel
            }
        } else {
            projectsMessageID = nil
            projectsDeadlineMessageID = nil
            projectsContextTitle = nil
        }

        return FocusedEmailPrintSelectionPolicy.resolve(
            activeFrame: state.activeFrame,
            metalMessageID: metalMessageID,
            peopleSelectedMessageID: peopleMessageID,
            frontPageMessageID: frontPageWorkspace?.focusedArticleID,
            timelineMessageID: timelineWorkspace?.playheadMessageID,
            projectsMessageID: projectsMessageID,
            projectsDeadlineMessageID: projectsDeadlineMessageID,
            projectsContextTitle: projectsContextTitle
        )
    }

    @MainActor
    private var selectedSentMessageIDForSendAgain: UUID? {
        switch state.activeFrame.spatialLens {
        case .frontPage:
            guard let workspace = frontPageWorkspace else { return nil }
            if let focused = workspace.focusedArticle {
                return focused.isSentByUser ? focused.id : nil
            }
            let selected = workspace.selectedArticles
            guard selected.count == 1, let article = selected.first else { return nil }
            return article.isSentByUser ? article.id : nil

        case .timeline:
            guard let message = timelineWorkspace?.playheadMessage,
                  message.isSentByUser else { return nil }
            return message.messageID

        case .projects:
            guard let workspace = projectsWorkspace,
                  let snapshot = workspace.currentSnapshot else { return nil }
            let messageID = workspace.workroomExpandedMessageID
                ?? workspace.messageReadout.flatMap {
                    $0.isPinned || $0.expanded ? $0.messageID : nil
                }
            guard let messageID,
                  snapshot.messageFilterRows[messageID.uuidString]?.isSentByUser == true else {
                return nil
            }
            return messageID

        default:
            let rawMessageID: String?
            if state.activeFrame.spatialLens == .people, liveLockPersonFocus != nil {
                rawMessageID = lockedRingSelectionMessageId
            } else {
                rawMessageID = lockedNodeIDStorage
            }
            guard let rawMessageID,
                  currentMessageIndex[rawMessageID]?.isSentByUser == true else {
                return nil
            }
            return UUID(uuidString: rawMessageID)
        }
    }

    @MainActor
    private func handleSendAgain(messageID: UUID, immediately: Bool) {
        guard !sendAgainInFlight else { return }
        sendAgainInFlight = true
        Task { @MainActor in
            defer { sendAgainInFlight = false }
            do {
                let context = ModelContext(modelContext.container)
                var descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate<Message> { $0.id == messageID }
                )
                descriptor.fetchLimit = 1
                guard let message = try context.fetch(descriptor).first,
                      message.isSentByUser else {
                    return
                }
                let prepared = try await SendAgainDraftFactory.prepare(
                    from: message,
                    context: context
                )
                if immediately {
                    let dispatcher = SendDispatcher(
                        context: context,
                        jobQueue: JobQueue()
                    )
                    do {
                        _ = try dispatcher.enqueueCompose(
                            draft: prepared.draft,
                            account: prepared.account,
                            identity: prepared.identity
                        )
                    } catch {
                        AppCommand.requestComposerCompose(draftID: prepared.draft.id)
                        AppCommand.showComposer()
                        throw error
                    }
                } else {
                    AppCommand.requestComposerCompose(draftID: prepared.draft.id)
                    AppCommand.showComposer()
                }
            } catch {
                showSendAgainFailure(error)
            }
        }
    }

    @MainActor
    private func showSendAgainFailure(_ error: Swift.Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't send this message again"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private func handleLockedNodeToggleReadFromMenu() {
        guard let messageID = lockedNodeMessageID else { return }
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == messageID })
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first else { return }
        let dispatcher = makeMailboxMutationDispatcher()
        let next = !message.isReadOrFalse
        do {
            let outcome = try dispatcher.setRead(messageID: messageID, value: next)
            if !outcome.propagatedToServer {
                showLocalOnlyMutationNotice(action: next ? "mark read" : "mark unread")
            }
            if next {
                retireReadNewStars(messageIDs: [messageID])
            }
        } catch {
            print("[Constellation] menu setRead failed: \(String(reflecting: type(of: error)))")
        }
    }

    @MainActor
    private func handleLockedNodeMarkAsSpamFromMenu() {
        guard let messageID = lockedNodeMessageID else { return }
        let moved = markMessagesAsSpam([messageID]) { [self] movedIDs, removalContext in
            guard movedIDs.contains(messageID) else { return }
            if (state.lockedVectorId != nil || liveLockPersonFocus != nil),
               !removalContext.releasedPeopleFocus {
                scheduleLockedDeletionReturnAfterAnimation(
                    messageIds: removalContext.messageIds,
                    dyingPeople: removalContext.dyingPeople,
                    lockedVectorId: state.lockedVectorId
                )
            }
        }
        if moved {
            Task { await refreshSceneData() }
        }
    }

    /// Edit-menu / notification entry point. `confirm` is carried in the
    /// notification's userInfo so ⌘-Delete can request an immediate delete.
    @MainActor
    private func handleLockedNodeDeleteFromMenu(confirm: Bool) {
        _ = deleteLockedNode(confirm: confirm)
    }

    /// Move the locked node to Trash. Shared by the Edit menu, the ⌘-Delete
    /// shortcut (`confirm: false`), and the plain-Delete shortcut
    /// (`confirm: true`). Returns whether a delete was actually performed so a
    /// keyboard handler can consume the key only when it acted.
    @MainActor
    @discardableResult
    private func deleteLockedNode(confirm: Bool) -> Bool {
        guard let messageID = lockedNodeMessageID else { return false }
        return frontPageDeleteMessages([messageID], confirm: confirm) { _ in
            let deletedMessageIds = Set([messageID.uuidString])
            let dyingPeople = captureDyingSnapshots(messageIds: deletedMessageIds)
            let releasedPeopleFocus = releasePeopleFocusIfDyingHubWasLocked(
                dyingPeople,
                deletedMessageIds: deletedMessageIds
            )
            if !releasedPeopleFocus {
                scheduleLockedDeletionReturnAfterAnimation(
                    messageIds: deletedMessageIds,
                    dyingPeople: dyingPeople,
                    lockedVectorId: state.lockedVectorId
                )
            }
        }
    }

    /// Resolve the active lens's keyboard-delete target and route it through
    /// the same delete the lens's Delete button uses. In the People lens the
    /// selected ring email is the target; every other lens acts on the locked
    /// node (the shared LockedNodeOverlay target, identical to the Edit-menu
    /// "Delete Selected Node"). Returns whether a delete was performed.
    @MainActor
    private func deleteSelectedSceneMessage(confirm: Bool) -> Bool {
        if state.activeFrame.spatialLens == .people,
           let raw = lockedRingSelectionMessageId,
           let id = UUID(uuidString: raw) {
            return frontPageDeleteMessages(
                [id],
                confirm: confirm,
                afterSuccessfulDelete: { _ in lockedRingSelectionMessageId = nil }
            )
        }
        return deleteLockedNode(confirm: confirm)
    }

    /// True when the key window's first responder is editing text, so the
    /// Delete key must fall through to the field editor (backspace) instead of
    /// deleting a message. The scene's keyboard catcher deliberately lets the
    /// Search field's key events reach `onKeyDown` for navigation, so the
    /// Delete handler re-checks here to avoid deleting a node while the user is
    /// editing a search query.
    @MainActor
    private func isTextInputResponderFocused() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current is NSTextView || current is NSTextField || current is NSSearchField {
                return true
            }
            responder = current.nextResponder
        }
        return false
    }

    @MainActor
    private func handleLockedNodeClassificationFacetFromMenu(notification: Notification) {
        guard let raw = notification.userInfo?["facet"] as? String,
              let messageID = lockedNodeMessageID else { return }
        let messageId = messageID.uuidString
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == messageID })
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first else { return }
        let current = effectiveClassification(messageId: messageId, message: message)
        let currentCustom = effectiveCustomCategoryKeys(messageId: messageId, message: message)
        if raw.hasPrefix("purpose."),
           let purpose = MailPurpose(rawValue: String(raw.dropFirst("purpose.".count))) {
            applyUserClassification(
                messageId: messageId,
                classification: .userAssigned(purpose: purpose),
                customCategoryKeys: currentCustom
            )
        } else if CustomCategoryKeysJSON.canonicalKeys([raw]).first == raw,
                  customCategoryStore.allKeys.contains(raw) {
            var nextCustom = currentCustom
            if nextCustom.contains(raw) {
                nextCustom.remove(raw)
            } else {
                nextCustom.insert(raw)
            }
            applyUserClassification(
                messageId: messageId,
                classification: current,
                customCategoryKeys: nextCustom
            )
        }
    }

    /// Resolve the canonical classification the menu should checkmark on
    /// entry. Prefers the in-memory override so a saved manual edit appears
    /// immediately while a snapshot refresh is pending.
    @MainActor
    private func effectiveClassification(messageId: String, message: Message) -> MailClassification? {
        classificationByMessageId[messageId]
            ?? MailClassificationJSON.decode(message.analysis?.mailClassificationJSON)
    }

    @MainActor
    private func effectiveClassification(
        messageId: String,
        fallbackRow row: MessageFilterRow?
    ) -> MailClassification? {
        classificationByMessageId[messageId] ?? row?.mailClassification
    }

    /// Custom-key counterpart of `effectiveClassification(messageId:message:)`.
    /// Prefers the in-memory override, falls back to the stored custom-key JSON, and
    /// always restricts to the live catalog so removed categories vanish.
    @MainActor
    private func effectiveCustomCategoryKeys(messageId: String, message: Message) -> Set<String> {
        if let overridden = summaryCustomKeysByMessageId[messageId] {
            return overridden.intersection(customCategoryStore.allKeys)
        }
        return Set(CustomCategoryKeysJSON.decode(message.analysis?.customCategoryKeysJSON))
            .intersection(customCategoryStore.allKeys)
    }

    @MainActor
    private func effectiveCustomCategoryKeys(messageId: String, fallbackRow row: MessageFilterRow?) -> Set<String> {
        if let overridden = summaryCustomKeysByMessageId[messageId] {
            return overridden.intersection(customCategoryStore.allKeys)
        }
        return row?.customCategoryKeys.intersection(customCategoryStore.allKeys) ?? []
    }

    /// Modal NSAlert for moving a message to Trash. Returns true on user
    /// confirmation. Plain AppKit so the dialog is identical to the other
    /// macOS confirmation surfaces.
    @MainActor
    private func confirmDeleteNode(subject: String) -> Bool {
        guard DeletionConfirmationPreference.showsMoveToTrashConfirmation() else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this email?"
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySubject = trimmedSubject.isEmpty ? "(no subject)" : trimmedSubject
        alert.informativeText = "“\(displaySubject)” will be moved to the account Trash mailbox."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if let firstButton = alert.buttons.first {
            // Make the Delete button the default so Return/Enter confirms. We must
            // NOT set hasDestructiveAction here: it deliberately suppresses the
            // Return key equivalent (that is its whole purpose) and NSAlert re-applies
            // that suppression during layout, which is exactly why Return wasn't
            // confirming. Cancel keeps Escape via NSAlert's automatic assignment.
            firstButton.keyEquivalent = "\r"
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Modal NSAlert for moving a message to the account Spam/Junk folder.
    /// This is a mailbox move, not an Ohia category assignment.
    @MainActor
    private func confirmMarkAsSpamNode(subject: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Mark this email as spam?"
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySubject = trimmedSubject.isEmpty ? "(no subject)" : trimmedSubject
        alert.informativeText = "“\(displaySubject)” will be moved to the account Spam or Junk mailbox."
        alert.addButton(withTitle: "Mark as spam")
        alert.addButton(withTitle: "Cancel")
        if let firstButton = alert.buttons.first {
            firstButton.hasDestructiveAction = true
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Surface a quiet AppKit notification when a mutation couldn't
    /// reach the server (metadata-only account, or a row that
    /// predates IMAP origin tracking). Local state still changed.
    @MainActor
    private func showLocalOnlyMutationNotice(action: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Couldn't \(action) on the server"
        let isTrashMove = action.localizedCaseInsensitiveContains("Trash")
        let isSpamMove = action.localizedCaseInsensitiveContains("Spam")
            || action.localizedCaseInsensitiveContains("Junk")
        if isTrashMove {
            alert.informativeText = "Ohia could not resolve a server Trash mailbox or server-side reference, so the change applies only to Ohia. The server copy is unchanged."
        } else if isSpamMove {
            alert.informativeText = "Ohia could not resolve a server Spam or Junk mailbox or server-side reference, so the change applies only to Ohia. The server copy is unchanged."
        } else {
            alert.informativeText = "This message has no server-side reference, so the change applies only to Ohia. The server copy is unchanged."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private func showTrashMoveUnavailableNotice() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't move to Trash"
        alert.informativeText = "Ohia could not establish a stable server-side identity or find the account's real Trash mailbox, so the message was left in place."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private func showJunkMoveUnavailableNotice() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't move to Spam"
        alert.informativeText = "Ohia could not find a server Spam or Junk mailbox for this account, so the message was left in place."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Lowercased set of every address known to belong to the local user — every
    /// `Account.emailAddress` and every `Identity.address` across configured accounts.
    /// Forwarded into the locked-email card so the recipients line drops the user
    /// themselves.
    @MainActor
    private var userAddressSet: Set<String> {
        var addresses: Set<String> = []
        for account in accounts {
            let primary = account.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !primary.isEmpty {
                addresses.insert(primary)
            }
            for identity in account.identities {
                let value = identity.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !value.isEmpty {
                    addresses.insert(value)
                }
            }
        }
        return addresses
    }

    @MainActor
    private func lockedSelectionIndicatorPoint(vectorId: Int64) -> CGPoint? {
        guard let world = lockedSelectionWorldPosition(vectorId: vectorId),
              viewSize.width > 1,
              viewSize.height > 1,
              let projected = ScreenProjection.project(
                world: world,
                camera: cameraController.state,
                viewSize: viewSize,
                fovYRadians: .pi / 3
              ) else {
            return lockedNodeSelectionFallbackPoint
        }
        return projected
    }

    @MainActor
    private func lockedSelectionWorldPosition(vectorId: Int64) -> SIMD3<Float>? {
        if let proxy = renderPacket.hitProxies.first(where: { $0.vectorId == vectorId }) {
            return proxy.worldPosition
        }
        if let satellite = renderPacket.satellites.first(where: { $0.vectorId == vectorId }) {
            return satellite.position
        }
        return renderPacket.stars.first { $0.representativeVectorId == vectorId }?.position
    }

    @MainActor
    private func renderedNodeColor(for proxy: HitProxy) -> SIMD4<Float> {
        renderedNodeColor(vectorId: proxy.vectorId, messageId: proxy.messageId)
    }

    @MainActor
    private func renderedNodeColor(vectorId: Int64, messageId: String?) -> SIMD4<Float> {
        if let satellite = renderPacket.satellites.first(where: { $0.vectorId == vectorId }) {
            return satellite.color
        }
        if let star = renderPacket.stars.first(where: { $0.representativeVectorId == vectorId }) {
            return star.color
        }
        if let messageId,
           let star = renderPacket.stars.first(where: { $0.messageId == messageId }) {
            return star.color
        }
        if let messageId,
           let color = snapshotCache.snapshot(
            for: state.activeFrame,
            maxAge: .greatestFiniteMagnitude
           )?.colorByMessageId[messageId] {
            return color
        }
        if let record = visibleRecordCache[vectorId] ?? searchResultRecordCache[vectorId],
           let color = snapshotCache.snapshot(
            for: state.activeFrame,
            maxAge: .greatestFiniteMagnitude
           )?.colorByMessageId[record.messageId] {
            return color
        }
        return ConstellationRenderBuilder.stableSemanticColor(for: messageId ?? "\(vectorId)")
    }

    private func swiftUIColor(from color: SIMD4<Float>) -> Color {
        Color(
            .sRGB,
            red: Double(clampedColorChannel(color.x)),
            green: Double(clampedColorChannel(color.y)),
            blue: Double(clampedColorChannel(color.z)),
            opacity: Double(clampedColorChannel(color.w))
        )
    }

    private func clampedColorChannel(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    @MainActor
    private var detailFrameForTransition: CGRect {
        // The focused transition scene now lives inside the detail slot
        // of the body's ConstellationSidebarContainer. Click coordinates,
        // the focused scene's GeometryReader, and the locked card all
        // share the detail-area space — so transitionPoint becomes the
        // identity and the sidebar offset is no longer applied here.
        Self.resolvedDetailFrameForTransition(
            shouldShowWithheldSidebar: shouldShowWithheldSidebar,
            searchDetailFrame: searchDetailFrameInTransitionSpace,
            withheldDetailFrame: withheldDetailFrameInTransitionSpace,
            viewSize: viewSize
        )
    }

    static func resolvedDetailFrameForTransition(
        shouldShowWithheldSidebar: Bool,
        searchDetailFrame: CGRect,
        withheldDetailFrame: CGRect,
        viewSize: CGSize
    ) -> CGRect {
        let activeFrame = shouldShowWithheldSidebar
            ? withheldDetailFrame
            : searchDetailFrame
        if activeFrame.width > 1,
           activeFrame.height > 1 {
            return CGRect(x: 0, y: 0, width: activeFrame.width, height: activeFrame.height)
        }
        return CGRect(
            x: 0,
            y: 0,
            width: max(viewSize.width, 1),
            height: max(viewSize.height, 1)
        )
    }

    @MainActor
    private func transitionPointIfPresent(fromDetailPoint point: CGPoint?) -> CGPoint? {
        guard let point else { return nil }
        return transitionPoint(fromDetailPoint: point)
    }

    @MainActor
    private func transitionPoint(fromDetailPoint point: CGPoint) -> CGPoint {
        let frame = detailFrameForTransition
        return CGPoint(x: point.x + frame.minX, y: point.y + frame.minY)
    }

    @MainActor
    private func detailPoint(fromTransitionPoint point: CGPoint) -> CGPoint {
        let frame = detailFrameForTransition
        return CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    @MainActor
    private func focusClickPendingPoint(for pending: PendingFocusClick) -> CGPoint? {
        if let fallbackPoint = pending.fallbackPoint {
            return fallbackPoint
        }
        if let world = pending.world,
           viewSize.width > 1,
           viewSize.height > 1,
           let projected = ScreenProjection.project(
                world: world,
                camera: cameraController.state,
                viewSize: viewSize,
                fovYRadians: .pi / 3
           ) {
            return projected
        }
        return nil
    }

    @MainActor
    private func beginPendingNotificationFocusNavigation() {
        guard AppCommand.pendingNotificationFocusMessageID() != nil else { return }
        // A deep link (e.g. an "Open in Ohia" calendar-note link) always
        // wants the Timeline lens, regardless of whichever lens the window
        // last had active. This is the single point every entry into
        // notification-focus navigation passes through — cold launch,
        // already-open window re-activation, and lifecycle retries alike —
        // so switching the frame here, before the routing below reads
        // `state.activeFrame`, covers all of them.
        if AppCommand.consumePendingNotificationFocusForcesTimeline() {
            selectFrame(.timeline)
        }
        notificationFocusRefreshRequested = false
        completePendingNotificationFocusNavigation()
    }

    /// Consumes the persisted macOS-notification target only after the
    /// restored lens can accept that exact message. The UUID latch survives a
    /// cold launch; unlike beacon navigation, this path must never substitute
    /// `newStarNavigator.pending.first` when a grouped notification selected a
    /// different primary message.
    @MainActor
    private func completePendingNotificationFocusNavigation() {
        guard !onboardingMode,
              let messageID = AppCommand.pendingNotificationFocusMessageID() else {
            return
        }

        let messageId = messageID.uuidString
        newStarNavigator.noteInboundMessageIDs([messageId])
        syncNewStarNavigatorWithCurrentMessageIndex()
        guard activeLensIsReady else { return }

        switch StarburstLensRoutingPolicy.route(activeFrame: state.activeFrame) {
        case .frontPageWorkspace:
            guard focusNotificationMessageInFrontPage(messageID) else {
                guard !retirePendingNotificationFocusIfMessageIsMissing(messageID) else { return }
                requestPendingNotificationFocusRefresh(messageID: messageID)
                return
            }
        case .projectsWorkspace:
            guard focusNotificationMessageInProjects(messageID) else {
                guard !retirePendingNotificationFocusIfMessageIsMissing(messageID) else { return }
                requestPendingNotificationFocusRefresh(messageID: messageID)
                return
            }
        case .timelineWorkspace:
            guard focusNotificationMessageInTimeline(messageID) else {
                guard !retirePendingNotificationFocusIfMessageIsMissing(messageID) else { return }
                requestPendingNotificationFocusRefresh(messageID: messageID)
                return
            }
        case .metalMessageFocus:
            guard queuedNotificationFocusMessageID != messageID else { return }
            guard focusNotificationMessageInMetalLens(messageID) else {
                guard !retirePendingNotificationFocusIfMessageIsMissing(messageID) else { return }
                requestPendingNotificationFocusRefresh(messageID: messageID)
                return
            }
            queuedNotificationFocusMessageID = messageID
            return
        }

        finishPendingNotificationFocus(messageID)
    }

    @MainActor
    private func finishPendingNotificationFocus(_ messageID: UUID) {
        guard AppCommand.pendingNotificationFocusMessageID() == messageID else { return }
        notificationFocusRefreshRequested = false
        AppCommand.clearPendingNotificationFocusMessageID()
        markNewStarVisited(messageId: messageID.uuidString)
    }

    /// A notification is created from a persisted `Message`, so absence from
    /// the authoritative SwiftData store after one lens refresh means the
    /// target was deleted or the store was reset after delivery. Retire that
    /// stale command instead of suppressing the startup Composer forever.
    @MainActor
    private func retirePendingNotificationFocusIfMessageIsMissing(
        _ messageID: UUID
    ) -> Bool {
        guard notificationFocusRefreshRequested,
              AppCommand.pendingNotificationFocusMessageID() == messageID else {
            return false
        }
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == messageID
            }
        )
        descriptor.fetchLimit = 1
        guard let messages = try? modelContext.fetch(descriptor),
              messages.isEmpty else {
            return false
        }
        finishPendingNotificationFocus(messageID)
        return true
    }

    @MainActor
    private func focusNotificationMessageInFrontPage(_ messageID: UUID) -> Bool {
        guard let snapshot = currentFrontPageNewStarSnapshot() else { return false }
        return openFrontPageReaderForNewStar(messageID: messageID, in: snapshot)
    }

    @MainActor
    private func focusNotificationMessageInProjects(_ messageID: UUID) -> Bool {
        guard let workspace = projectsWorkspace,
              let snapshot = workspace.currentSnapshot,
              ProjectsDataController.signatureMatchesCurrentFilter(
                  snapshot: snapshot,
                  filter: state.filter
              ) else {
            return false
        }
        return workspace.openLinksForMessage(
            messageID,
            in: snapshot,
            openEmailReadout: true
        )
    }

    @MainActor
    private func focusNotificationMessageInTimeline(_ messageID: UUID) -> Bool {
        guard let workspace = timelineWorkspace,
              workspace.currentSnapshot?.messageDateLookup[messageID] != nil else {
            return false
        }
        return workspace.focusMessage(
            messageID,
            maximumViewportSpan: Self.timelineSearchWarpViewportSpan
        )
    }

    @MainActor
    private func focusNotificationMessageInMetalLens(_ messageID: UUID) -> Bool {
        let messageId = messageID.uuidString
        guard let candidate = newStarNavigator.candidate(messageId: messageId) else {
            // Keep the exact UUID latched while ingestion catches up. A
            // notification click never switches lenses just because its node
            // is not renderable yet.
            return false
        }
        // A notification is an explicit request for this email, not the
        // beacon's correspondent-level navigation. In People, permit the
        // existing exact-email focus path; all other Metal lenses use their
        // normal message-node focus.
        let world = frameAwarePosition(
            vectorId: candidate.vectorId,
            fallbackRecord: candidate.record
        ) ?? candidate.world
        let sourceColor = renderedNodeColor(
            vectorId: candidate.vectorId,
            messageId: candidate.messageId
        )
        let queuedFrame = state.activeFrame
        guard queueSelectedNodeFocus(
            vectorId: candidate.vectorId,
            fallbackWorld: world,
            sourceColor: sourceColor,
            startZoomImmediately: true,
            allowsPeopleEmailFocus: Self.notificationFocusAllowsPeopleEmailFocus(
                activeFrame: state.activeFrame
            ),
            commitIsStillValid: {
                AppCommand.pendingNotificationFocusMessageID() == messageID
                    && state.activeFrame == queuedFrame
            },
            onCommit: { result in
                // The fly-to mark only needs to survive the flight: it
                // force-includes the target past aperture culling until the
                // lock (whose own `lockedVectorId` inclusion takes over)
                // commits or the attempt resolves. A retry path re-marks.
                highlighter.remove(vectorIds: [candidate.vectorId])
                completeQueuedNotificationMetalFocus(
                    messageID: messageID,
                    result: result
                )
            }
        ) else {
            return false
        }
        highlighter.mark(vectorIds: [candidate.vectorId])
        return true
    }

    @MainActor
    private func completeQueuedNotificationMetalFocus(
        messageID: UUID,
        result: SelectedNodeFocusCommitResult
    ) {
        guard queuedNotificationFocusMessageID == messageID else { return }
        queuedNotificationFocusMessageID = nil
        guard AppCommand.pendingNotificationFocusMessageID() == messageID else { return }

        switch result {
        case .committed:
            finishPendingNotificationFocus(messageID)
        case .unavailable:
            guard !retirePendingNotificationFocusIfMessageIsMissing(messageID) else { return }
            notificationFocusRefreshRequested = false
            requestPendingNotificationFocusRefresh(messageID: messageID)
        case .superseded:
            // Preserve the persisted intent without overriding the newer user
            // action that superseded this delayed focus click.
            break
        }
    }

    nonisolated static func notificationFocusAllowsPeopleEmailFocus(
        activeFrame: FrameKey
    ) -> Bool {
        activeFrame.spatialLens == .people
    }

    @MainActor
    private func requestPendingNotificationFocusRefresh(messageID: UUID) {
        guard !notificationFocusRefreshRequested else { return }
        notificationFocusRefreshRequested = true
        switch StarburstLensRoutingPolicy.route(activeFrame: state.activeFrame) {
        case .frontPageWorkspace:
            requestFrontPageRefreshForCurrentStateIfActive()
        case .projectsWorkspace:
            projectsData.invalidateAndRefresh()
        case .timelineWorkspace:
            guard let workspace = timelineWorkspace else { return }
            _ = workspace.focusMessage(
                messageID,
                date: notificationFocusFallbackDate(messageID),
                maximumViewportSpan: Self.timelineSearchWarpViewportSpan
            )
            workspace.currentSnapshot = nil
            timelineData.invalidateAll(resolveRollingWindow: true)
            requestTimelineRefreshForCurrentStateIfActive()
        case .metalMessageFocus:
            Task { await refreshSceneData(updateColorLookup: true) }
        }
    }

    @MainActor
    private func notificationFocusFallbackDate(_ messageID: UUID) -> Date? {
        if let candidate = newStarNavigator.candidate(messageId: messageID.uuidString) {
            return candidate.receivedAt
        }
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == messageID
            }
        )
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first else { return nil }
        return message.receivedAt ?? message.sentAt ?? message.ingestedAt
    }

    @MainActor
    private func visitNextNewStar(candidate explicitCandidate: NewStarCandidate? = nil) {
        guard let candidate = explicitCandidate ?? newStarNavigator.pending.first else { return }
        guard let target = newStarFocusTarget(for: candidate) else {
            Task { await refreshSceneData(updateColorLookup: true) }
            return
        }
        let queuedFrame = state.activeFrame
        guard queueSelectedNodeFocus(
            vectorId: target.vectorId,
            fallbackWorld: target.world,
            sourceColor: target.sourceColor,
            startZoomImmediately: true,
            personFocus: target.personFocus,
            allowsPeopleEmailFocus: target.allowsPeopleEmailFocus,
            initialPeopleRingSelectionMessageId: target.initialPeopleRingSelectionMessageId,
            commitIsStillValid: {
                state.activeFrame == queuedFrame
                    && NewMailArrivalLedger.shared.unvisitedArrivalIds.contains(candidate.messageId)
            },
            onCommit: { result in
                // Same fly-to-window lifetime as the notification path
                // above: release the force-include mark once the focus
                // attempt resolves; a retry-after-refresh re-marks.
                highlighter.remove(vectorIds: [target.vectorId])
                completeQueuedNewStarMetalFocus(
                    candidate: candidate,
                    frame: queuedFrame,
                    result: result
                )
            }
        ) else {
            return
        }
        highlighter.mark(vectorIds: [target.vectorId])
    }

    @MainActor
    private func completeQueuedNewStarMetalFocus(
        candidate: NewStarCandidate,
        frame: FrameKey,
        result: SelectedNodeFocusCommitResult
    ) {
        let hasRetriedAfterRefresh = pendingMetalNewStar?.messageId == candidate.messageId
            && pendingMetalNewStar?.frame == frame
            && pendingMetalNewStar?.hasRetriedAfterRefresh == true
        switch StarburstMetalFocusCompletionPolicy.disposition(
            for: result,
            hasRetriedAfterRefresh: hasRetriedAfterRefresh
        ) {
        case .consumeBadge:
            pendingMetalNewStar = nil
            markNewStarVisited(messageId: candidate.messageId)
        case .retryAfterRefresh:
            pendingMetalNewStar = PendingMetalNewStar(
                messageId: candidate.messageId,
                frame: frame,
                hasRetriedAfterRefresh: true
            )
            Task { await refreshSceneData(frame: frame, updateColorLookup: true) }
        case .retainBadge:
            // A newer user action owns focus now, or the single refreshed
            // retry still could not commit. Keep the arrival unvisited, but
            // do not override that action or enter a refresh/retry loop.
            pendingMetalNewStar = nil
        }
    }

    @MainActor
    private func newStarFocusTarget(for candidate: NewStarCandidate) -> NewStarFocusTarget? {
        let renderedWorld = renderedNewStarWorld(
            messageId: candidate.messageId,
            vectorId: candidate.vectorId,
            fallback: candidate.world
        )
        let sourceColor = renderedNodeColor(vectorId: candidate.vectorId, messageId: candidate.messageId)
        guard state.activeFrame.spatialLens == .people else {
            return NewStarFocusTarget(
                vectorId: candidate.vectorId,
                world: renderedWorld,
                sourceColor: sourceColor,
                personFocus: nil,
                allowsPeopleEmailFocus: false,
                initialPeopleRingSelectionMessageId: nil
            )
        }

        let row = currentMessageIndex[candidate.messageId]
            ?? UUID(uuidString: candidate.messageId).flatMap(newStarMessageFilterRow(for:))
        if let hub = peopleHubForMessage(messageId: candidate.messageId, row: row) {
            return NewStarFocusTarget(
                vectorId: candidate.vectorId,
                world: renderedWorld,
                sourceColor: sourceColor,
                personFocus: lockedPersonFocus(for: hub),
                allowsPeopleEmailFocus: false,
                initialPeopleRingSelectionMessageId:
                    StarburstPeopleFocusSelectionPolicy.initialSelectionMessageId(
                        activeFrame: state.activeFrame,
                        hasCorrespondentFocus: true,
                        arrivalMessageId: candidate.messageId
                    )
            )
        }

        return NewStarFocusTarget(
            vectorId: candidate.vectorId,
            world: renderedWorld,
            sourceColor: sourceColor,
            personFocus: nil,
            allowsPeopleEmailFocus: true,
            initialPeopleRingSelectionMessageId: nil
        )
    }

    @MainActor
    private func renderedNewStarWorld(
        messageId: String,
        vectorId: Int64,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        renderPacket.stars.first(where: { $0.messageId == messageId })?.position
            ?? renderPacket.hitProxies.first(where: { $0.messageId == messageId })?.worldPosition
            ?? renderPacket.satellites.first(where: { $0.vectorId == vectorId })?.position
            ?? renderPacket.hitProxies.first(where: { $0.vectorId == vectorId })?.worldPosition
            ?? fallback
    }

    @MainActor
    private func peopleHubForMessage(
        messageId: String,
        row: MessageFilterRow?
    ) -> PersonHubInstance? {
        Self.peopleHubForMessage(
            messageId: messageId,
            row: row,
            userAddressSet: userAddressSet,
            hubs: renderPacket.personHubs
        )
    }

    nonisolated static func peopleHubForMessage(
        messageId: String,
        row: MessageFilterRow?,
        userAddressSet: Set<String>,
        hubs: [PersonHubInstance]
    ) -> PersonHubInstance? {
        let normalizedUsers = Set(userAddressSet.map(PeopleRingMessageScope.normalizedEmail))
        let sender = PeopleRingMessageScope.normalizedEmail(row?.fromAddress ?? "")
        if !sender.isEmpty,
           normalizedUsers.contains(sender) == false,
           let hub = hubs.first(where: {
               PeopleRingMessageScope.normalizedEmail($0.email) == sender
                   && ($0.messageIds.isEmpty || $0.messageIds.contains(messageId))
           }) {
            return hub
        }

        let containingHubs = hubs.filter {
            $0.messageIds.contains(messageId)
        }
        if !sender.isEmpty,
           let hub = containingHubs.first(where: {
               PeopleRingMessageScope.normalizedEmail($0.email) == sender
           }) {
            return hub
        }
        return containingHubs.sorted {
            if $0.reciprocalScore != $1.reciprocalScore {
                return $0.reciprocalScore > $1.reciprocalScore
            }
            let leftCount = $0.sentCount + $0.receivedCount + $0.appearanceCount
            let rightCount = $1.sentCount + $1.receivedCount + $1.appearanceCount
            if leftCount != rightCount { return leftCount > rightCount }
            return $0.email < $1.email
        }.first
    }

    nonisolated static func askCitationAllowsEmailFocus(activeFrame: FrameKey) -> Bool {
        activeFrame.spatialLens == .people
    }

    private func normalizedEmail(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private func visitNextNewStarInProjects(
        candidate explicitCandidate: NewStarCandidate? = nil
    ) -> Bool {
        guard let candidate = explicitCandidate ?? newStarNavigator.pending.first else { return false }
        guard let messageID = UUID(uuidString: candidate.messageId) else { return false }
        return routeProjectsNewStar(messageID: messageID, ledgerMessageId: candidate.messageId)
    }

    /// Beacon routing inside the Projects lens. An arrival that belongs to a
    /// project flies to that project's focused view with the message
    /// highlighted. An arrival that provably belongs to no project hands off
    /// to where the mail actually lives: the Front Page reader (switching
    /// lens) — a beacon press must always land on the message, never
    /// silently no-op.
    ///
    /// "Provably" is load-bearing: a fresh arrival is embargo-filtered out
    /// of every snapshot built before its announcement, and
    /// `invalidateAndRefresh` deliberately leaves the stale snapshot mounted
    /// while the recompute runs — concluding "no project" during that
    /// window would misroute project mail to the Front Page, irreversibly
    /// (the arrival gets opened and marked visited there). So the verdict
    /// requires a snapshot matching the live filter with no refresh in
    /// flight; anything less parks the arrival for the snapshot-change hook
    /// to re-route.
    @MainActor
    private func routeProjectsNewStar(messageID: UUID, ledgerMessageId: String) -> Bool {
        if openProjectsLinkForNewStar(messageID: messageID) {
            markNewStarVisited(messageId: ledgerMessageId)
            return true
        }
        let snapshotIsTrustworthy: Bool
        if let snapshot = projectsWorkspace?.currentSnapshot,
           !projectsData.hasRefreshInFlight,
           ProjectsDataController.signatureMatchesCurrentFilter(snapshot: snapshot, filter: state.filter) {
            snapshotIsTrustworthy = true
        } else {
            snapshotIsTrustworthy = false
        }
        guard snapshotIsTrustworthy else {
            pendingProjectsNewStarMessageID = messageID
            if !projectsData.hasRefreshInFlight {
                projectsData.invalidateAndRefresh()
            }
            return true
        }
        // The arrival belongs to no project: hand off to the Front Page and
        // hydrate that one article instead of waiting for a page rebuild.
        pendingProjectsNewStarMessageID = nil
        selectFrame(.frontPage)
        beginTargetedFrontPageNewStarHydration(
            messageID: messageID,
            ledgerMessageId: ledgerMessageId
        )
        return true
    }

    @MainActor
    private func visitNextNewStarInTimeline(
        candidate explicitCandidate: NewStarCandidate? = nil
    ) -> Bool {
        guard let candidate = explicitCandidate ?? newStarNavigator.pending.first else { return false }
        guard let messageID = UUID(uuidString: candidate.messageId) else { return false }
        return visitNewStarInTimeline(
            messageID: messageID,
            ledgerMessageId: candidate.messageId,
            fallbackDate: candidate.receivedAt
        )
    }

    @MainActor
    private func visitNewStarInTimeline(
        messageID: UUID,
        ledgerMessageId: String,
        fallbackDate: Date
    ) -> Bool {
        if openTimelineMessageForNewStar(messageID: messageID) {
            markNewStarVisited(messageId: ledgerMessageId)
            return true
        }

        pendingTimelineNewStar = PendingTimelineNewStar(
            messageID: messageID,
            fallbackDate: fallbackDate
        )
        prepareTimelineNewStarRefresh(
            messageID: messageID,
            fallbackDate: fallbackDate
        )
        return true
    }

    @MainActor
    private func visitNextNewStarInFrontPage(
        candidate explicitCandidate: NewStarCandidate? = nil
    ) -> Bool {
        guard let candidate = explicitCandidate ?? newStarNavigator.pending.first else { return false }
        guard let messageID = UUID(uuidString: candidate.messageId) else { return false }
        return visitNewStarInFrontPage(
            messageID: messageID,
            ledgerMessageId: candidate.messageId
        )
    }

    @MainActor
    private func visitNewStarInFrontPage(
        messageID: UUID,
        ledgerMessageId: String
    ) -> Bool {
        if let snapshot = currentFrontPageNewStarSnapshot(),
           openFrontPageReaderForNewStar(messageID: messageID, in: snapshot) {
            markNewStarVisited(messageId: ledgerMessageId)
            return true
        }

        beginTargetedFrontPageNewStarHydration(
            messageID: messageID,
            ledgerMessageId: ledgerMessageId
        )
        return true
    }

    /// Commits the reader takeover synchronously, then hydrates only the
    /// requested article. A full Front Page rebuild is a last-resort fallback,
    /// never a prerequisite for responding to the beacon click.
    @MainActor
    private func beginTargetedFrontPageNewStarHydration(
        messageID: UUID,
        ledgerMessageId: String
    ) {
        cancelPendingFrontPageNewStarHydration(clearPendingMessage: false)
        pendingFrontPageNewStarMessageID = messageID
        guard state.activeFrame.spatialLens == .frontPage,
              let workspace = frontPageWorkspace else {
            requestFrontPageRefreshForCurrentStateIfActive()
            return
        }

        frontPageData.ensureBound(
            workspace: workspace,
            modelContext: modelContext,
            vectorStore: services.vectorStore
        )
        workspace.focusArticle(messageID)
        let sequence = pendingFrontPageNewStarHydrationSequence
        pendingFrontPageNewStarHydrationTask = Task { @MainActor in
            let article = await frontPageData.loadArticleForFocus(messageID: messageID)
            guard Task.isCancelled == false,
                  sequence == pendingFrontPageNewStarHydrationSequence,
                  state.activeFrame.spatialLens == .frontPage,
                  pendingFrontPageNewStarMessageID == messageID,
                  workspace.focusedArticleID == messageID else {
                if sequence == pendingFrontPageNewStarHydrationSequence {
                    pendingFrontPageNewStarHydrationTask = nil
                    if pendingFrontPageNewStarMessageID == messageID {
                        pendingFrontPageNewStarMessageID = nil
                    }
                }
                return
            }

            pendingFrontPageNewStarHydrationTask = nil
            guard let article else {
                workspace.dismissUnresolvedArticleFocus(ifMatching: messageID)
                frontPageData.invalidateCacheForNextRequest()
                requestFrontPageRefreshForCurrentStateIfActive()
                return
            }
            pendingFrontPageNewStarMessageID = nil
            workspace.focusArticle(article)
            markNewStarVisited(messageId: ledgerMessageId)
        }
    }

    @MainActor
    private func cancelPendingFrontPageNewStarHydration(clearPendingMessage: Bool) {
        pendingFrontPageNewStarHydrationSequence &+= 1
        pendingFrontPageNewStarHydrationTask?.cancel()
        pendingFrontPageNewStarHydrationTask = nil
        if clearPendingMessage {
            pendingFrontPageNewStarMessageID = nil
        }
    }

    @MainActor
    private func openFirstFrontPageReaderForNewStar(in snapshot: FrontPageSnapshot) -> Bool {
        guard let workspace = frontPageWorkspace else { return false }
        let messageIDs = newStarNavigator.pending.compactMap { UUID(uuidString: $0.messageId) }
        guard let result = workspace.openFirstArticleForMessage(messageIDs, in: snapshot) else {
            return false
        }
        cancelPendingFrontPageNewStarHydration(clearPendingMessage: true)
        for skippedID in result.skipped {
            markNewStarVisited(messageId: skippedID.uuidString)
        }
        markNewStarVisited(messageId: result.opened.uuidString)
        return true
    }

    @MainActor
    private func retirePendingFrontPageNewStarIfHidden(messageID: UUID) {
        cancelPendingFrontPageNewStarHydration(clearPendingMessage: true)
        markNewStarVisited(messageId: messageID.uuidString)
    }

    @MainActor
    private func completePendingProjectsNewStarNavigation() {
        guard state.activeFrame.spatialLens == .projects,
              let messageID = pendingProjectsNewStarMessageID else {
            return
        }
        _ = routeProjectsNewStar(messageID: messageID, ledgerMessageId: messageID.uuidString)
    }

    @MainActor
    private func completePendingFrontPageNewStarNavigation() {
        guard state.activeFrame.spatialLens == .frontPage,
              let messageID = pendingFrontPageNewStarMessageID,
              let snapshot = currentFrontPageNewStarSnapshot() else {
            return
        }
        if openFrontPageReaderForNewStar(messageID: messageID, in: snapshot) {
            markNewStarVisited(messageId: messageID.uuidString)
            return
        }
        guard Self.shouldRetireMissingFrontPageNewStarCandidate(
            hasFrontPageRefreshInFlightOrQueued: frontPageData.hasRefreshInFlightOrQueued
        ) else {
            return
        }
        retirePendingFrontPageNewStarIfHidden(messageID: messageID)
        _ = openFirstFrontPageReaderForNewStar(in: snapshot)
    }

    @MainActor
    private func completePendingTimelineNewStarNavigation() {
        guard state.activeFrame.spatialLens == .timeline,
              let pending = pendingTimelineNewStar else {
            return
        }
        if openTimelineMessageForNewStar(messageID: pending.messageID) {
            markNewStarVisited(messageId: pending.messageID.uuidString)
            return
        }
        guard timelineWorkspace?.currentSnapshot != nil else {
            return
        }
        retirePendingTimelineNewStarAndAdvance(pending)
    }

    @MainActor
    private func retryPendingTimelineNewStarNavigationIfNeeded() {
        guard state.activeFrame.spatialLens == .timeline,
              let pending = pendingTimelineNewStar else {
            return
        }
        if openTimelineMessageForNewStar(messageID: pending.messageID) {
            markNewStarVisited(messageId: pending.messageID.uuidString)
            return
        }
        guard timelineWorkspace?.currentSnapshot == nil else {
            return
        }
        prepareTimelineNewStarRefresh(
            messageID: pending.messageID,
            fallbackDate: pending.fallbackDate
        )
    }

    @MainActor
    private func retirePendingTimelineNewStarAndAdvance(_ pending: PendingTimelineNewStar) {
        pendingTimelineNewStar = nil
        markNewStarVisited(messageId: pending.messageID.uuidString)
        _ = visitNextNewStarInTimeline()
    }

    nonisolated static func shouldRetireMissingFrontPageNewStarCandidate(
        hasFrontPageRefreshInFlightOrQueued: Bool
    ) -> Bool {
        hasFrontPageRefreshInFlightOrQueued == false
    }

    @MainActor
    private func completePendingTimelineAskCitationNavigation() {
        guard state.activeFrame.spatialLens == .timeline,
              let pending = pendingTimelineAskCitation,
              let workspace = timelineWorkspace,
              workspace.focusMessage(
                  pending.messageID,
                  date: pending.fallbackDate,
                  maximumViewportSpan: Self.timelineSearchWarpViewportSpan
              ) else {
            return
        }
        pendingTimelineAskCitation = nil
    }

    @MainActor
    private func completePendingProjectsAskCitationNavigation() {
        guard state.activeFrame.spatialLens == .projects,
              let messageID = pendingProjectsAskCitationMessageID,
              let workspace = projectsWorkspace,
              let snapshot = workspace.currentSnapshot,
              ProjectsDataController.signatureMatchesCurrentFilter(
                  snapshot: snapshot,
                  filter: state.filter
              ),
              workspace.openLinksForMessage(messageID, in: snapshot, openEmailReadout: true) else {
            return
        }
        pendingProjectsAskCitationMessageID = nil
    }

    @MainActor
    private func completePendingFrontPageAskCitationNavigation() {
        guard state.activeFrame.spatialLens == .frontPage,
              let messageID = pendingFrontPageAskCitationMessageID,
              let workspace = frontPageWorkspace,
              let snapshot = workspace.currentSnapshot,
              FrontPageDataController.signatureMatchesCurrentFilter(
                  snapshot: snapshot,
                  filter: state.filter,
                  selectedTimeRange: state.selectedTimeRange,
                  unreadOnly: workspace.unreadOnly
              ),
              let articleID = frontPageData.displayArticleID(
                  forMatchedMessageID: messageID,
                  in: snapshot
              ),
              workspace.focusArticleDisplayingSearchMatch(articleID) else {
            return
        }
        pendingFrontPageAskCitationMessageID = nil
    }

    @MainActor
    private func openTimelineMessageForNewStar(messageID: UUID) -> Bool {
        guard state.activeFrame.spatialLens == .timeline,
              let workspace = timelineWorkspace,
              workspace.currentSnapshot?.messageDateLookup[messageID] != nil,
              workspace.focusMessage(
                  messageID,
                  maximumViewportSpan: Self.timelineSearchWarpViewportSpan
              ) else {
            return false
        }
        pendingTimelineNewStar = nil
        return true
    }

    @MainActor
    private func prepareTimelineNewStarRefresh(
        messageID: UUID,
        fallbackDate: Date
    ) {
        guard state.activeFrame.spatialLens == .timeline,
              let workspace = timelineWorkspace else {
            return
        }
        _ = workspace.focusMessage(
            messageID,
            date: fallbackDate,
            maximumViewportSpan: Self.timelineSearchWarpViewportSpan
        )
        workspace.currentSnapshot = nil
        timelineData.invalidateAll(resolveRollingWindow: true)
        requestTimelineRefreshForCurrentStateIfActive()
    }

    @MainActor
    private func openProjectsLinkForNewStar(messageID: UUID) -> Bool {
        guard let workspace = projectsWorkspace,
              let snapshot = workspace.currentSnapshot,
              workspace.openLinksForMessage(messageID, in: snapshot) else {
            return false
        }
        pendingProjectsNewStarMessageID = nil
        return true
    }

    @MainActor
    private func currentFrontPageNewStarSnapshot() -> FrontPageSnapshot? {
        guard let workspace = frontPageWorkspace,
              let snapshot = workspace.currentSnapshot,
              FrontPageDataController.signatureMatchesCurrentFilter(
                snapshot: snapshot,
                filter: state.filter,
                selectedTimeRange: state.selectedTimeRange,
                unreadOnly: workspace.unreadOnly
              ) else {
            return nil
        }
        return snapshot
    }

    @MainActor
    private func openFrontPageReaderForNewStar(
        messageID: UUID,
        in snapshot: FrontPageSnapshot
    ) -> Bool {
        guard let workspace = frontPageWorkspace,
              workspace.openArticleForMessage(messageID, in: snapshot) else {
            return false
        }
        cancelPendingFrontPageNewStarHydration(clearPendingMessage: true)
        return true
    }

    @MainActor
    private func markNewStarVisited(messageId: String) {
        newStarNavigator.markVisited(messageId: messageId)
        // The ledger is the one account both badges render from; its
        // mirror updates the dock tile.
        NewMailArrivalLedger.shared.markVisited(messageId: messageId)
    }

    @MainActor
    private func handleEmailSummaryInvalidation() {
        invalidateVisibleEmailSummaries()
        let ledger = NewMailArrivalLedger.shared
        var readIDs: Set<UUID> = []
        for messageID in ledger.unvisitedArrivalIds.compactMap(UUID.init(uuidString:)) {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == messageID }
            )
            descriptor.fetchLimit = 1
            if let message = try? modelContext.fetch(descriptor).first,
               message.isReadOrFalse {
                readIDs.insert(messageID)
            }
        }
        retireReadNewStars(messageIDs: readIDs)
    }

    @MainActor
    private func retireReadNewStars(messageIDs: Set<UUID>) {
        guard messageIDs.isEmpty == false else { return }
        for messageID in messageIDs {
            newStarNavigator.markVisited(messageId: messageID.uuidString)
        }
        NewMailArrivalLedger.shared.retireReadArrivals(
            messageIds: Set(messageIDs.map(\.uuidString))
        )
    }

    /// Resolves the exact ledger-backed arrival that owns the visible badge.
    /// Normally the navigator already has the candidate. The reconstruction
    /// path covers the short cross-process observation gap where the hot-path
    /// arrival reconciler has seen the worker's committed ready row, while
    /// this view's long-lived SwiftData context still reports its older
    /// processing state and therefore did not enqueue it during `sync`.
    @MainActor
    private func navigationCandidateForBadgedArrival(
        messageId: String
    ) -> NewStarCandidate? {
        if let candidate = newStarNavigator.candidate(messageId: messageId) {
            return candidate
        }
        guard let messageID = UUID(uuidString: messageId),
              let row = currentMessageIndex[messageId]
                ?? newStarMessageFilterRow(for: messageID),
              let record = representativeNewStarRecords(for: [messageId]).first else {
            return nil
        }
        return NewStarCandidate.announcedArrival(
            messageId: messageId,
            record: record,
            row: row
        )
    }

    @MainActor
    private func completePendingMetalNewStarNavigation(
        requestRefreshIfUnavailable: Bool,
        isDirectBeaconClick: Bool = false
    ) {
        guard let pending = pendingMetalNewStar,
              pending.frame == state.activeFrame,
              NewMailArrivalLedger.shared.unvisitedArrivalIds.contains(pending.messageId) else {
            pendingMetalNewStar = nil
            return
        }
        guard StarburstFocusSupersessionPolicy.mayQueueFocus(
            hasPendingFocus: pendingFocusClick != nil,
            isDirectBeaconClick: isDirectBeaconClick
        ) else {
            return
        }
        // The ready queue already owns the exact placed candidate in the
        // common case. Fly to it immediately; rebuilding the queue here used
        // to synchronously rehydrate SwiftData action state and query the
        // vector store on every beacon click.
        if let candidate = newStarNavigator.candidate(messageId: pending.messageId) {
            visitNextNewStar(candidate: candidate)
            return
        }
        syncNewStarNavigatorWithCurrentMessageIndex()
        // Announce patches every cached snapshot, but a frame whose
        // snapshot predates this window (or a click racing the announce
        // turn) can still miss the row — hydrate it now so the click
        // completes in this turn instead of waiting on a full rebuild.
        if currentMessageIndex[pending.messageId] == nil,
           let messageID = UUID(uuidString: pending.messageId) {
            upsertAnnouncedArrivalsIntoSnapshotCache(messageIDs: [messageID])
            syncNewStarNavigatorWithCurrentMessageIndex()
        }
        guard currentMessageIndex[pending.messageId] != nil,
              let candidate = navigationCandidateForBadgedArrival(messageId: pending.messageId) else {
            if requestRefreshIfUnavailable {
                Task {
                    await refreshSceneData(
                        frame: pending.frame,
                        updateColorLookup: true,
                        revealCachedSnapshotFirst: true
                    )
                }
            }
            return
        }
        visitNextNewStar(candidate: candidate)
    }

    @MainActor
    private func routeVectorlessMetalArrivalToFrontPage(messageId: String) -> Bool {
        guard let messageID = UUID(uuidString: messageId),
              let records = try? services.vectorStore.vectorsForMessage(messageId: messageId),
              records.isEmpty else {
            return false
        }
        pendingMetalNewStar = nil
        selectFrame(.frontPage)
        beginTargetedFrontPageNewStarHydration(
            messageID: messageID,
            ledgerMessageId: messageId
        )
        return true
    }

    // MARK: - Starburst button — manual-refresh + nav-to-next-ready

    /// A latched failure supplies its state-specific hover text even if a live
    /// formation notice exists. Otherwise live-forming text wins.
    @MainActor
    private var starburstCapsuleText: String? {
        if manualRefresh.state.isFailure { return manualRefresh.state.capsuleText }
        if let live = newStarNavigator.formationNoticeText { return live }
        return manualRefresh.state.capsuleText
    }

    /// Maps the coordinator's terminal-failure states to the view's
    /// FailureKind so the capsule picks up its warning tint.
    @MainActor
    private var starburstFailureKind: NewStarFormationNoticeView.FailureKind? {
        switch manualRefresh.state {
        case .transientFailure: return .transient
        case .authFailure:      return .auth
        case .idle, .searching, .newMail, .empty: return nil
        }
    }

    /// Account UUIDs Territory currently shows. Mirrors the inverse-set
    /// logic ConstellationTopBar uses to compute `territoryDisplayed`.
    @MainActor
    private var territoryDisplayedAccountIDs: Set<UUID> {
        let hidden = Set(
            territoryHiddenRaw.split(separator: ",").compactMap {
                UUID(uuidString: String($0))
            }
        )
        return Set(accounts.map(\.id).filter { !hidden.contains($0) })
    }

    /// Contextual click: a latched failure clears and retries first. Otherwise
    /// the canonical arrival badge wins (Front Page opens
    /// the story reader, Projects opens the message's project Links view, and
    /// Metal lenses fly to that exact arrival);
    /// during a manual refresh, the click acks-flickers; otherwise it kicks a
    /// manual IMAP poll across the Territory-displayed IMAP accounts.
    @MainActor
    private func handleStarburstClick() {
        let ledger = NewMailArrivalLedger.shared
        let oldestFirstArrivalIDs = oldestFirstBadgedArrivalIDs(
            ledger.unvisitedArrivalIds
        )
        switch StarburstClickIntentPolicy.resolve(
            unvisitedArrivalIdsInOldestFirstOrder: oldestFirstArrivalIDs,
            isSearching: manualRefresh.state == .searching,
            hasFailure: manualRefresh.state.isFailure
        ) {
        case .navigateToArrival(let messageId):
            navigateToBadgedArrival(messageId: messageId)
        case .acknowledgeSearch:
            manualRefresh.acknowledgeClick()
        case .manualRefresh:
            let displayed = territoryDisplayedAccountIDs
            let scoped = accounts.filter { displayed.contains($0.id) }
            manualRefresh.request(
                accounts: scoped,
                sessionManager: sessionManager,
                allowsIMAPWork: hasCompletedFirstIngestion || hasReachedOnboardingWitnessPanel
            )
        }
    }

    /// Opens one exact badged arrival in the active lens: Front Page opens
    /// the story reader, Projects opens the message's project Links view,
    /// Timeline focuses the message, and Metal lenses fly to it. Shared by
    /// the Beacon click and its right-click Go To commands.
    @MainActor
    private func navigateToBadgedArrival(messageId: String) {
        guard let messageID = UUID(uuidString: messageId) else {
            markNewStarVisited(messageId: messageId)
            return
        }
        switch StarburstLensRoutingPolicy.route(activeFrame: state.activeFrame) {
        case .frontPageWorkspace:
            _ = visitNewStarInFrontPage(
                messageID: messageID,
                ledgerMessageId: messageId
            )
        case .projectsWorkspace:
            _ = routeProjectsNewStar(
                messageID: messageID,
                ledgerMessageId: messageId
            )
        case .timelineWorkspace:
            _ = visitNewStarInTimeline(
                messageID: messageID,
                ledgerMessageId: messageId,
                fallbackDate: notificationFocusFallbackDate(messageID) ?? Date.now
            )
        case .metalMessageFocus:
            pendingMetalNewStar = PendingMetalNewStar(
                messageId: messageId,
                frame: state.activeFrame,
                hasRetriedAfterRefresh: false
            )
            if newStarNavigator.candidate(messageId: messageId) != nil {
                completePendingMetalNewStarNavigation(
                    requestRefreshIfUnavailable: true,
                    isDirectBeaconClick: true
                )
                return
            }
            if routeVectorlessMetalArrivalToFrontPage(messageId: messageId) {
                return
            }
            completePendingMetalNewStarNavigation(
                requestRefreshIfUnavailable: true,
                isDirectBeaconClick: true
            )
        }
    }

    /// Runs a Beacon right-click command against the arrivals the menu showed
    /// that are still badged. Go To commands ignore a latched failure or an
    /// in-flight check, because the person picked an email explicitly. Clear
    /// commands empty the badge first, then apply the requested read state
    /// through the same mutation path as every other mark-read action, which
    /// also syncs the server.
    @MainActor
    private func handleBeaconMenuCommand(_ request: BeaconArrivalMenuRequest) {
        let targetIDs = BeaconArrivalMenuPolicy.stillBadged(
            capturedArrivalIds: request.arrivalIds,
            currentlyBadgedIds: NewMailArrivalLedger.shared.unvisitedArrivalIds
        )
        guard targetIDs.isEmpty == false else { return }
        switch request.command {
        case .goToNewest, .goToOldest:
            if let target = BeaconArrivalMenuPolicy.navigationTarget(
                for: request.command,
                oldestFirstArrivalIds: beaconMenuOldestFirstArrivalIDs(targetIDs)
            ) {
                navigateToBadgedArrival(messageId: target)
            }
        case .clear, .clearAndMarkRead, .clearAndMarkUnread:
            clearBadgedArrivals(targetIDs)
            if let readState = BeaconArrivalMenuPolicy.readStateAfterClearing(for: request.command) {
                applyClearedArrivalReadState(readState, to: targetIDs)
            }
        }
    }

    /// Visits the arrivals without opening them, so the Beacon and Dock
    /// badges drop them in one update. Navigation parked for one of them is
    /// dropped too, so a lens refresh that lands later cannot open it or
    /// switch lenses for it. A Front Page reader already took over at click
    /// time, so its article hydration is left to finish.
    @MainActor
    private func clearBadgedArrivals(_ messageIDs: [String]) {
        let cleared = Set(messageIDs)
        for messageId in cleared {
            newStarNavigator.markVisited(messageId: messageId)
        }
        NewMailArrivalLedger.shared.markVisited(messageIds: cleared)
        if let pending = pendingMetalNewStar, cleared.contains(pending.messageId) {
            pendingMetalNewStar = nil
        }
        if let pendingID = pendingProjectsNewStarMessageID,
           cleared.contains(pendingID.uuidString) {
            pendingProjectsNewStarMessageID = nil
        }
        if let pending = pendingTimelineNewStar,
           cleared.contains(pending.messageID.uuidString) {
            pendingTimelineNewStar = nil
        }
    }

    /// Marking read writes every cleared arrival, which also ends its
    /// new-arrival treatment. Badged mail is almost always unread already,
    /// so marking unread writes only the messages read since they arrived
    /// instead of queueing a no-op server change for each one.
    @MainActor
    private func applyClearedArrivalReadState(_ value: Bool, to messageIDs: [String]) {
        let ids = messageIDs.compactMap(UUID.init(uuidString:))
        guard value == false else {
            frontPageSetRead(ids, value: true)
            return
        }
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { ids.contains($0.id) }
        )
        do {
            let readIDs = try modelContext.fetch(descriptor)
                .filter(\.isReadOrFalse)
                .map(\.id)
            frontPageSetRead(readIDs, value: false)
        } catch {
            // Without current read state, write every cleared arrival; an
            // already-unread message makes a harmless no-op change.
            print("[Constellation] beacon menu read-state lookup failed: \(String(reflecting: type(of: error)))")
            frontPageSetRead(ids, value: false)
        }
    }

    /// Orders arrivals for a right-click Go To command. The click path stays
    /// fetch-free, so arrivals outside the active lens's index sort last
    /// there. An explicit Newest or Oldest command instead pays for one
    /// batched lookup of those dates, so it names the real ends of the badge
    /// by received date, and an arrival the store no longer holds is skipped.
    @MainActor
    private func beaconMenuOldestFirstArrivalIDs(_ arrivalIDs: [String]) -> [String] {
        var receivedAtByMessageId = knownBadgedArrivalDates(arrivalIDs)
        let missingIDs = arrivalIDs
            .filter { receivedAtByMessageId[$0] == nil }
            .compactMap(UUID.init(uuidString:))
        var lookupSucceeded = true
        if missingIDs.isEmpty == false {
            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { missingIDs.contains($0.id) }
            )
            do {
                for message in try modelContext.fetch(descriptor) {
                    // Same date the lens index uses, so both sources agree.
                    receivedAtByMessageId[message.id.uuidString] =
                        message.receivedAt ?? message.ingestedAt
                }
            } catch {
                lookupSucceeded = false
                print("[Constellation] beacon menu date lookup failed: \(String(reflecting: type(of: error)))")
            }
        }
        return BeaconArrivalMenuPolicy.oldestFirstTargets(
            arrivalIds: arrivalIDs,
            receivedAtByMessageId: receivedAtByMessageId,
            dropsUndated: lookupSucceeded
        )
    }

    /// Received dates for badged arrivals that the ready queue or the active
    /// lens's message index already holds. Never touches the store.
    @MainActor
    private func knownBadgedArrivalDates(_ messageIDs: [String]) -> [String: Date] {
        var receivedAtByMessageId = Dictionary(
            uniqueKeysWithValues: newStarNavigator.pending.map { ($0.messageId, $0.receivedAt) }
        )
        for messageId in messageIDs where receivedAtByMessageId[messageId] == nil {
            if let row = currentMessageIndex[messageId] {
                receivedAtByMessageId[messageId] = row.receivedAt ?? row.ingestedAt
            }
        }
        return receivedAtByMessageId
    }

    @MainActor
    private func oldestFirstBadgedArrivalIDs(_ messageIDs: [String]) -> [String] {
        let receivedAtByMessageId = knownBadgedArrivalDates(messageIDs)
        return StarburstArrivalOrderingPolicy.oldestFirst(
            unvisitedArrivalIds: messageIDs,
            receivedAtByMessageId: receivedAtByMessageId
        )
    }

    /// Grey the recenter disc for one second after a press so the camera move
    /// reads as in flight. `recenterCooldownSeq` makes overlapping requests
    /// safe — only the most-recent request's trailing reset runs.
    @MainActor
    private func beginRecenterCooldown() {
        recenterCooldownSeq &+= 1
        let mySeq = recenterCooldownSeq
        recenterCooldownActive = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if mySeq == recenterCooldownSeq {
                recenterCooldownActive = false
            }
        }
    }

    private enum DefaultCameraReason: Equatable {
        case startup
        case userReset
        case filterChange

        var animated: Bool {
            switch self {
            case .startup:
                return false
            case .userReset, .filterChange:
                return true
            }
        }
    }

    /// Re-frame the camera only for explicit default-camera intents.
    /// Scene refreshes, frame-burst completions, new-node rendering, and
    /// lens changes preserve the user's current camera unless a People or
    /// Meaning filter change has installed its updated render packet.
    @MainActor
    private func recenterCamera() {
        if recenterLockedNodeCameraIfNeeded() {
            return
        }
        let frame = state.activeFrame
        Task {
            await applyDefaultConstellationCameraIfNeeded(frame: frame, reason: .userReset)
        }
    }

    @MainActor
    @discardableResult
    private func recenterLockedNodeCameraIfNeeded() -> Bool {
        guard state.lockedVectorId != nil else {
            return false
        }
        if peopleLiveFocusExitInFlight {
            return true
        }

        if state.activeFrame.spatialLens == .people,
           let personFocus = liveLockPersonFocus {
            guard peopleLiveFocusControlsVisible else {
                return true
            }
            let refreshed = refreshedLivePeopleFocus(personFocus)
            liveLockPersonFocus = refreshed
            let target = refreshed.worldPosition
            if let targetCamera = peopleSaturnPortraitRecenterCameraState(
                anchorHubWorld: target,
                forEmail: refreshed.email,
                fallbackRingNormal: refreshed.ringNormal
            ) {
                warpAnimator.engage(to: targetCamera, profile: .glide)
                return true
            }
            let targetCamera = lockedNodeRecenterCameraState(focusing: target)
            warpAnimator.engage(to: targetCamera, profile: .glide)
            return true
        }

        guard let target = lockedNodeRecenterWorld() else {
            return true
        }
        if state.lockedVectorId != nil {
            selectedNodeFocusWorld = target
        }
        let targetCamera = lockedNodeRecenterCameraState(focusing: target)
        warpAnimator.engage(to: targetCamera, profile: .glide)
        return true
    }

    @MainActor
    private func lockedNodeRecenterWorld() -> SIMD3<Float>? {
        if let selectedNodeFocusWorld {
            return selectedNodeFocusWorld
        }
        guard let lockedVectorId = state.lockedVectorId else {
            return nil
        }
        return lockedSelectionWorldPosition(vectorId: lockedVectorId)
            ?? frameAwarePosition(vectorId: lockedVectorId)
    }

    @MainActor
    private func lockedNodeRecenterCameraState(focusing center: SIMD3<Float>) -> CameraState {
        // People solar-system email-node locks recenter to the same
        // fixed front-facing framing their entry used, not a
        // density-derived fit.
        if state.activeFrame.spatialLens == .people,
           let sun = renderPacket.personSun {
            return LiveFocusFramingPolicy.peopleSolarTargetCamera(
                center: center,
                current: cameraController.state,
                eclipticNormal: sun.eclipticNormal
            )
        }
        let contextPositions = renderPacket.stars
            .filter { $0.signal.lockFocus > 0 }
            .map(\.position)
            + renderPacket.satellites
            .filter { $0.signal.lockFocus > 0 }
            .map(\.position)
        let focusRadius = Self.lockedNodeRecenterFocusRadius(
            center: center,
            contextPositions: contextPositions
        )
        return SelectedNodeFocusCameraMath.cameraState(
            focusing: center,
            from: cameraController.state,
            focusRadius: focusRadius
        )
    }

    @MainActor
    @discardableResult
    private func applyDefaultConstellationCameraIfNeeded(
        frame: FrameKey,
        reason: DefaultCameraReason
    ) async -> Bool {
        let resolvedFrame = frame.spatialLens
        switch reason {
        case .startup:
            guard !onboardingMode,
                  !framesWithSessionCameraState.contains(resolvedFrame),
                  state.lockedVectorId == nil else {
                return false
            }
        case .userReset:
            guard !onboardingMode else { return false }
        case .filterChange:
            guard !onboardingMode,
                  state.lockedVectorId == nil else {
                return false
            }
        }
        guard viewSize.width > 1, viewSize.height > 1 else { return false }
        if warpAnimator.isWarping {
            guard reason == .filterChange else { return false }
            warpAnimator.cancel()
        }
        guard state.activeFrame.spatialLens == resolvedFrame else { return false }

        var targetCameraState = cameraStateForCurrentRenderPacket(frame: resolvedFrame)
        if targetCameraState == nil {
            let filter = ConstellationFilterResolver.effectiveSceneFilter(
                baseFilter: state.filter,
                selectedTimeRange: state.selectedTimeRange
            )
            let visualFilter = Self.visualSceneFilter(frame: resolvedFrame, filter: filter)
            let snapshot = await constellationSnapshot(for: resolvedFrame)
            targetCameraState = await initialConstellationCameraState(
                frame: resolvedFrame,
                filter: visualFilter,
                snapshot: snapshot,
                viewSize: viewSize
            )
        }
        guard state.activeFrame.spatialLens == resolvedFrame,
              let cameraState = targetCameraState else {
            return false
        }

        warpAnimator.onComplete = nil
        warpAnimator.onProgress = nil
        if reason.animated {
            warpAnimator.engage(to: cameraState, profile: .glide)
        } else {
            cameraController.snap(to: cameraState)
        }
        framesWithSessionCameraState.insert(resolvedFrame)
        recordCameraState(cameraState, for: resolvedFrame, persist: true)
        lastPlannedCameraSignature = CameraPlanningSignature(cameraState)
        if reason == .startup {
            didFrameInitialConstellationCamera = true
        }
        return true
    }

    @MainActor
    private func cameraStateForCurrentRenderPacket(frame: FrameKey) -> CameraState? {
        let resolvedFrame = frame.spatialLens
        guard renderPacketFrame.spatialLens == resolvedFrame else { return nil }
        let positions = Self.cameraFramingPositions(from: renderPacket, frame: resolvedFrame)
        return ConstellationCameraFraming.cameraState(
            fitting: positions,
            frame: resolvedFrame,
            viewSize: viewSize
        )
    }

    @MainActor
    private func peopleLiveFocusExitRecenterCamera() -> CameraState? {
        guard state.activeFrame.spatialLens == .people else { return nil }
        return cameraStateForCurrentRenderPacket(frame: .people)
    }

    @MainActor
    private func reframeLivePeopleFocusIfNeeded(expectedKey: PeopleLiveFocusReframeKey) async {
        guard PeopleLiveFocusReframePolicy.shouldReframe(
            activeFrame: state.activeFrame,
            renderPacketFrame: renderPacketFrame,
            lockedVectorId: state.lockedVectorId,
            hasLivePersonFocus: liveLockPersonFocus != nil,
            renderPacketFilter: renderPacketFilter,
            currentFilter: state.filter
        ) else {
            return
        }

        let sequence = lockRevealSequence
        while warpAnimator.isWarping {
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  lockRevealSequence == sequence,
                  peopleLiveFocusReframeKey == expectedKey else {
                return
            }
        }

        guard lockRevealSequence == sequence,
              peopleLiveFocusReframeKey == expectedKey,
              var focus = liveLockPersonFocus else {
            return
        }

        focus = refreshedLivePeopleFocus(focus)
        liveLockPersonFocus = focus

        if let selectedMessageId = lockedRingSelectionMessageId,
           !peopleRingMessageIds(for: focus).contains(selectedMessageId) {
            lockedRingSelectionMessageId = nil
        }

        guard let approach = peopleSaturnPortraitApproach(
            anchorHubWorld: focus.worldPosition,
            forEmail: focus.email,
            fallbackRingNormal: focus.ringNormal
        ) else {
            return
        }
        guard simd_distance(cameraController.state.position, approach)
                > Self.peopleLiveFocusReframeDistanceThreshold else {
            return
        }
        warpAnimator.engage(to: approach, lookAt: focus.worldPosition, profile: .glide)
    }

    @MainActor
    private func refreshedLivePeopleFocus(_ focus: LockedPersonFocus) -> LockedPersonFocus {
        guard let hub = Self.matchingPersonHub(forEmail: focus.email, in: renderPacket.personHubs) else {
            return LockedPersonFocus(
                email: focus.email,
                displayName: focus.displayName,
                worldPosition: focus.worldPosition,
                messageIds: currentPeopleScopeMessageIds(involving: focus.email),
                ringNormal: focus.ringNormal,
                outerRingEdgeRadius: focus.outerRingEdgeRadius
            )
        }

        let outerEdge = hub.rings.map { $0.radius + $0.thickness }.max() ?? 0
        return LockedPersonFocus(
            email: hub.email,
            displayName: hub.displayName,
            worldPosition: hub.position,
            messageIds: currentPeopleScopeMessageIds(for: hub),
            ringNormal: hub.ringNormal,
            outerRingEdgeRadius: outerEdge
        )
    }

    /// Camera approach point for the People-correspondent portrait
    /// frame: a front-facing stand-off along the ring-plane normal
    /// (hemisphere-corrected toward the current camera) that fits the
    /// hub plus its surrounding ring bands inside the viewport with
    /// breathing room for the locked-overlay chrome.
    ///
    /// Used by the People-lens lock as the single warp target. The
    /// axis is deliberately NOT the camera→hub bearing: in the solar
    /// system that bearing gets shallower the farther a planet orbits
    /// from the sun, so far planets were framed near edge-on (reading
    /// as smaller/farther) while near-sun planets got a face-on
    /// portrait. The front-facing axis gives every planet an identical
    /// composition — the same one the in-lock recenter control
    /// produces — regardless of where in the system it sits. The
    /// neutral geometry fit is tightened a little so entry reads as
    /// moving toward the correspondent, while exit restores the default
    /// People recenter camera captured before the scene narrows.
    ///
    /// Stand-off is derived from the hub's radius plus the longest
    /// ring radius found in the current render packet. Falls back
    /// to a hub-radius heuristic when ring data hasn't landed yet
    /// (e.g. before the narrowed packet rebuild) so we still
    /// produce a reasonable portrait.
    @MainActor
    private func peopleSaturnPortraitApproach(
        anchorHubWorld: SIMD3<Float>,
        forEmail email: String,
        fallbackRingNormal: SIMD3<Float>? = nil
    ) -> SIMD3<Float>? {
        let metrics = peopleSaturnPortraitMetrics(
            forEmail: email
        )
        guard let metrics else { return nil }
        let standoff = PeopleLiveFocusTransitionPolicy.entryPortraitStandoff(
            systemStandoff: metrics.systemStandoff
        )
        let axis = PeoplePortraitCameraPolicy.portraitApproachAxis(
            ringNormal: metrics.ringNormal ?? fallbackRingNormal,
            cameraPosition: cameraController.state.position,
            center: anchorHubWorld
        )
        return anchorHubWorld + axis * standoff
    }

    @MainActor
    private func peopleSaturnPortraitRecenterCameraState(
        anchorHubWorld: SIMD3<Float>,
        forEmail email: String,
        fallbackRingNormal: SIMD3<Float>
    ) -> CameraState? {
        guard let metrics = peopleSaturnPortraitMetrics(
            forEmail: email
        ) else {
            return nil
        }
        return PeoplePortraitCameraPolicy.frontFacingCameraState(
            center: anchorHubWorld,
            ringNormal: metrics.ringNormal ?? fallbackRingNormal,
            standoff: metrics.systemStandoff,
            cameraPosition: cameraController.state.position
        )
    }

    @MainActor
    private func peopleSaturnPortraitMetrics(
        forEmail email: String
    ) -> (systemStandoff: Float, ringNormal: SIMD3<Float>?)? {
        let normalized = PeopleRingMessageScope.normalizedEmail(email)
        guard !normalized.isEmpty else { return nil }
        let matchedHub = Self.matchingPersonHub(forEmail: normalized, in: renderPacket.personHubs)
        let hubRadius = max(matchedHub?.radius ?? 0.020, 0.005)
        let ringOuterEdges = renderPacket.personRings
            .filter { PeopleRingMessageScope.normalizedEmail($0.email) == normalized }
            .filter { $0.arcEndFraction == 0 }
            .map { $0.radius + $0.thickness }
        let ringExtent = PeoplePortraitCameraPolicy.systemExtent(
            hubRadius: hubRadius,
            ringOuterEdges: ringOuterEdges
        )
        return (
            PeoplePortraitCameraPolicy.standoffDistance(systemExtent: ringExtent),
            matchedHub?.ringNormal
        )
    }

    nonisolated static func cameraFramingPositions(
        from packet: ConstellationRenderPacket,
        frame: FrameKey
    ) -> [SIMD3<Float>] {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(
            packet.stars.count
                + packet.satellites.count
                + packet.nebulae.count * 7
                + packet.personHubs.count * 7
                + packet.meaningClusterHubs.count * 7
                + packet.personAtoms.count
        )

        positions.append(contentsOf: packet.stars.map(\.position))
        positions.append(contentsOf: packet.satellites.map(\.position))
        for nebula in packet.nebulae {
            positions.append(contentsOf: framingPoints(around: nebula.position, radius: nebula.radius))
        }
        positions.append(contentsOf: packet.semanticDensityFields.flatMap {
            framingPoints(around: $0.position, radius: $0.radius)
        })
        positions.append(contentsOf: packet.arcLabels.map(\.position))

        // `.timeline` framing previously folded strata ribbon endpoints into
        // the camera-fit corpus. The lens no longer mounts the Metal scene,
        // so no ribbon framing is needed here.
        if frame.spatialLens == .people {
            if let sun = packet.personSun {
                // Solar system: frame the OCCUPIED orbital extent — every
                // body's full path reach (aphelion), not just its current
                // position, so planets can never orbit out of the default
                // framing. Floored at the one-month band radius so a small
                // all-fresh system still reads as a system, not a close-up
                // of the sun's face.
                var maxExtent: Float = 0.85
                for hub in packet.personHubs {
                    let reach: Float
                    if let orbit = hub.orbit {
                        reach = orbit.aphelion
                    } else {
                        reach = simd_length(hub.position - sun.position)
                    }
                    maxExtent = max(maxExtent, reach + max(hub.radius, hub.maxRingRadius))
                }
                positions.append(contentsOf: framingPoints(around: sun.position, radius: maxExtent))
            } else {
                for hub in packet.personHubs {
                    let radius = max(hub.radius, hub.maxRingRadius)
                    positions.append(contentsOf: framingPoints(around: hub.position, radius: radius))
                }
            }
            positions.append(contentsOf: packet.personAtoms.map(\.position))
        }
        if frame.spatialLens == .meaning {
            for hub in packet.meaningClusterHubs {
                positions.append(contentsOf: framingPoints(around: hub.position, radius: hub.radius))
                positions.append(contentsOf: hub.memberHalos.map(\.position))
            }
        }
        return positions
    }

    private nonisolated static func framingPoints(
        around position: SIMD3<Float>,
        radius: Float
    ) -> [SIMD3<Float>] {
        let radius = max(0, radius)
        guard radius > 0 else { return [position] }
        return [
            position,
            position + SIMD3<Float>(radius, 0, 0),
            position - SIMD3<Float>(radius, 0, 0),
            position + SIMD3<Float>(0, radius, 0),
            position - SIMD3<Float>(0, radius, 0),
            position + SIMD3<Float>(0, 0, radius),
            position - SIMD3<Float>(0, 0, radius)
        ]
    }

    @MainActor
    private func handleLiveInboundReadyForLensPresentation(
        _ notification: Notification
    ) {
        guard let event = Self.liveInboundPayload(from: notification) else { return }
        ConstellationLog.logger.notice(
            "readyForLensPresentation received messageIDs=\(event.messageIDs.map(\.uuidString).joined(separator: ","), privacy: .public) activeLens=\(state.activeFrame.spatialLens.rawValue, privacy: .public) alreadyRendered=\(event.messageIDs.filter { renderedLiveInboundMessageIDs.contains($0.uuidString) }.map(\.uuidString).joined(separator: ","), privacy: .public)"
        )
        Self.performSameTurnLiveInboundPendingRegistration(
            registerPending: {
                for messageID in event.messageIDs
                where NewMailArrivalLedger.shared.isAnnounced(messageID: messageID) == false {
                    pendingLiveInboundPresentations[messageID.uuidString] = event
                }
            },
            acknowledge: {
                acknowledgeRenderedLiveInboundMessages()
            }
        )

        switch state.activeFrame.spatialLens {
        case .frontPage:
            requestFrontPageRefreshForCurrentStateIfActive()
        case .projects:
            projectsData.invalidateAndRefresh()
        case .timeline:
            requestTimelineRefreshForCurrentStateIfActive()
        default:
            guard state.selectedTimeRange.refreshesOnNewPlacements || onboardingMode else {
                return
            }
            Task {
                await refreshSceneData(
                    updateColorLookup: true,
                    revealCachedSnapshotFirst: false
                )
            }
        }
    }

    @MainActor
    private func handleLiveInboundNotification(_ notification: Notification) {
        guard let event = Self.liveInboundPayload(from: notification) else { return }
        handleLiveInboundEvent(event)
        requestFrontPageRefreshForCurrentStateIfActive()
        guard Self.usesMetalScene(state.activeFrame),
              state.selectedTimeRange.refreshesOnNewPlacements || onboardingMode else { return }
        Task { await refreshSceneData(updateColorLookup: true, revealCachedSnapshotFirst: true) }
    }

    /// Both arrival notifications are delivered synchronously inside the
    /// announce turn, before either handler's refresh Task runs — so by the
    /// time the reveal pass reads the snapshot cache, `handleLiveInboundEvent`
    /// has already patched the arrival row in. The reveal pass renders the
    /// node from the patched cache in one packet build; the canonical pass
    /// that follows reconciles store truth.
    @MainActor
    private func handleArrivalVisibilityChanged() {
        guard Self.usesMetalScene(state.activeFrame),
              state.selectedTimeRange.refreshesOnNewPlacements || onboardingMode else {
            return
        }
        // Reveal-first only when there is an announced arrival to reveal.
        // Pure embargo ticks (a message newly *hidden* by detection) keep
        // the single canonical pass: installing a packet from an
        // arbitrarily-old cached snapshot buys nothing there and could
        // briefly resurface state a mid-flight rebuild is replacing.
        // Read the gate INSIDE the Task: this notification posts before
        // `announce()` appends to `unvisitedArrivalIds`, so a synchronous
        // read would see 0 for the very arrival being announced — by the
        // time the Task body runs, the announce turn has completed.
        Task {
            await refreshSceneData(
                updateColorLookup: true,
                revealCachedSnapshotFirst: NewMailArrivalLedger.shared.unvisitedCount > 0
            )
        }
    }

    @MainActor
    private func handleLiveInboundEvent(_ event: IMAPLiveInboundPayload) {
        // Patch the announced arrivals into every cached frame snapshot in
        // this same main-actor turn. The alert the user just heard must
        // coincide with a renderable, navigable node: the reveal refresh
        // pass and the starburst click both read the cache, so neither
        // waits for the seconds-long canonical snapshot rebuild.
        upsertAnnouncedArrivalsIntoSnapshotCache(messageIDs: event.messageIDs)
        newStarNavigator.noteInboundMessageIDs(event.messageIDs.map(\.uuidString))
        syncNewStarNavigatorWithCurrentMessageIndex()
        // No dock-tile write here: the arrival ledger already mirrored the
        // dock badge in the same turn that posted this notification.
    }

    @MainActor
    private var liveInboundPresentationObservationKey: LiveInboundPresentationObservationKey {
        LiveInboundPresentationObservationKey(
            activeFrame: state.activeFrame.spatialLens,
            pendingMessageIDs: pendingLiveInboundPresentations.keys.sorted(),
            renderedMessageIDs: renderedLiveInboundMessageIDs.sorted(),
            surfaceMarker: liveInboundPresentationSurfaceMarker
        )
    }

    @MainActor
    private var focusedArrivalBadgeObservationKey: FocusedArrivalBadgeObservationKey {
        let metalMessageID = state.lockedVectorId.flatMap { vectorID in
            (visibleRecordCache[vectorID] ?? citationSourceRecord(vectorId: vectorID))?.messageId
        }
        let frontPageReaderMessageID = frontPageWorkspace?.focusedArticleID?.uuidString
        let frontPageThreadMessageIDs = focusedFrontPageThreadMessageIDs
        let timelineMessageID = timelineWorkspace?.playheadMessageID?.uuidString
        let projectsMessageIDs = focusedProjectsMessageIDs

        return FocusedArrivalBadgeObservationKey(
            focusedMessageIDs: Self.focusedArrivalMessageIDs(
                activeFrame: state.activeFrame,
                metalMessageID: metalMessageID,
                frontPageReaderMessageID: frontPageReaderMessageID,
                frontPageThreadMessageIDs: frontPageThreadMessageIDs,
                timelineMessageID: timelineMessageID,
                projectsMessageIDs: projectsMessageIDs
            ),
            unvisitedArrivalIDs: Set(NewMailArrivalLedger.shared.unvisitedArrivalIds)
        )
    }

    @MainActor
    private var focusedFrontPageThreadMessageIDs: Set<String> {
        guard let workspace = frontPageWorkspace,
              let openThreadID = workspace.openThreadID,
              let snapshot = workspace.currentSnapshot else {
            return []
        }

        if let lead = snapshot.composition.lead, lead.id == openThreadID {
            return Set(lead.thread?.members.map { $0.id.uuidString } ?? [])
        }
        if let feature = snapshot.composition.features.first(where: { $0.id == openThreadID }) {
            return Set(feature.thread?.members.map { $0.id.uuidString } ?? [])
        }
        for section in snapshot.composition.sections {
            if let article = section.articles.first(where: { $0.id == openThreadID }) {
                return Set(article.thread?.members.map { $0.id.uuidString } ?? [])
            }
        }
        return []
    }

    @MainActor
    private var focusedProjectsMessageIDs: Set<String> {
        guard let workspace = projectsWorkspace else { return [] }
        var messageIDs: Set<String> = []

        if let messageID = workspace.workroomExpandedMessageID {
            messageIDs.insert(messageID.uuidString)
        }
        if let readout = workspace.messageReadout,
           readout.expanded,
           readout.expandedMode == .message {
            messageIDs.insert(readout.messageID.uuidString)
        }
        if workspace.lensTab == .deadlines,
           let openedDeadlineID = workspace.openedDeadlineID,
           let entry = workspace.deadlineTracker().entry(id: openedDeadlineID) {
            messageIDs.insert(entry.representativeMessageID.uuidString)
        }
        return messageIDs
    }

    @MainActor
    private var liveInboundPresentationSurfaceMarker: TimeInterval {
        switch state.activeFrame.spatialLens {
        case .frontPage:
            return frontPageWorkspace?.currentSnapshot?.builtAt.timeIntervalSinceReferenceDate ?? 0
        case .projects:
            return projectsWorkspace?.currentSnapshot?.builtAt.timeIntervalSinceReferenceDate ?? 0
        case .timeline:
            return timelineWorkspace?.currentSnapshot?.builtAt.timeIntervalSinceReferenceDate ?? 0
        default:
            return renderPacket.generatedAt
        }
    }

    @MainActor
    private func acknowledgeRenderedLiveInboundMessages() {
        guard pendingLiveInboundPresentations.isEmpty == false else { return }
        let observedFrame = state.activeFrame.spatialLens

        guard Task.isCancelled == false,
              state.activeFrame.spatialLens == observedFrame else {
            return
        }

        let presented = Self.presentedLiveInboundMessageIDs(
            pendingMessageIDs: Set(pendingLiveInboundPresentations.keys),
            activeFrame: observedFrame,
            frontPageMessageIDs: observedFrame == .frontPage
                ? renderedLiveInboundMessageIDs
                : [],
            projectsMessageIDs: Set(
                projectsWorkspace?.currentSnapshot?.visibleRows
                    .flatMap(\.messageIDs)
                    .map(\.uuidString) ?? []
            ),
            timelineMessageIDs: Set(
                timelineWorkspace?.currentSnapshot?.messageDateLookup.keys
                    .map(\.uuidString) ?? []
            ),
            metalMessageIDs: renderPacketFrame.spatialLens == observedFrame
                ? renderedLiveInboundMessageIDs
                : []
        )
        let stagedPresented = presented.filter { messageID in
            guard let id = UUID(uuidString: messageID) else { return false }
            return NewMailArrivalLedger.shared.isStagedForLensPresentation(messageID: id)
                && NewMailArrivalLedger.shared.isAnnounced(messageID: id) == false
        }
        ConstellationLog.logger.notice(
            "acknowledge pending=\(Array(pendingLiveInboundPresentations.keys).joined(separator: ","), privacy: .public) frame=\(observedFrame.rawValue, privacy: .public) presented=\(presented.joined(separator: ","), privacy: .public) stagedPresented=\(stagedPresented.joined(separator: ","), privacy: .public)"
        )
        guard stagedPresented.isEmpty == false else { return }

        let grouped = Dictionary(grouping: stagedPresented) { messageID in
            let event = pendingLiveInboundPresentations[messageID]!
            return LiveInboundPresentationGroup(
                accountID: event.accountID,
                folder: event.folder,
                observedAt: event.observedAt
            )
        }
        for messageID in stagedPresented {
            pendingLiveInboundPresentations.removeValue(forKey: messageID)
        }
        for (group, messageIDs) in grouped {
            let ids = messageIDs.compactMap(UUID.init(uuidString:))
            guard ids.isEmpty == false else { continue }
            let event = IMAPLiveInboundPayload(
                accountID: group.accountID,
                folder: group.folder,
                count: ids.count,
                messageIDs: ids,
                observedAt: group.observedAt
            )
            NotificationCenter.default.post(
                name: .ohiaLiveInboundDidRenderInActiveLens,
                object: nil,
                userInfo: Self.liveInboundUserInfo(for: event)
            )
        }
    }

    /// The per-card `onGeometryChange` witness (`noteFrontPageMessagesPresented`)
    /// only re-fires on a size transition from zero to non-zero, so it never
    /// re-fires for a message added to a thread package whose outer card was
    /// already mounted — the classic case for a reply arriving into an
    /// existing conversation. This is the data-level counterpart: it fires
    /// the instant the installed snapshot's composition actually contains the
    /// arrival, independent of any card's mount/geometry timing, LazyVStack
    /// viewport laziness, or scroll position. Both witnesses feed the same
    /// idempotent acknowledge path, so neither can double-fire the alert.
    @MainActor
    private func noteFrontPageSnapshotInstalled(_ snapshot: FrontPageSnapshot?) {
        guard state.activeFrame.spatialLens == .frontPage, let snapshot else { return }
        let pending = Set(pendingLiveInboundPresentations.keys)
        guard pending.isEmpty == false else { return }
        let matched = pending.intersection(Self.allRepresentedMessageIDs(in: snapshot.composition))
        guard matched.isEmpty == false else { return }
        ConstellationLog.logger.notice(
            "noteFrontPageSnapshotInstalled matches pending: \(matched.joined(separator: ","), privacy: .public)"
        )
        Self.performSameTurnLiveInboundAcknowledgement(
            recordPresentation: {
                renderedLiveInboundMessageIDs.formUnion(matched)
            },
            acknowledge: {
                acknowledgeRenderedLiveInboundMessages()
            }
        )
    }

    /// Every message id the composition will actually render: standalone
    /// articles plus every member of every thread package (not just each
    /// package's representative id).
    nonisolated static func allRepresentedMessageIDs(in composition: FrontPageComposition) -> Set<String> {
        var ids: Set<String> = []
        func addArticle(_ article: FrontPageComposedArticle) {
            ids.insert(article.id.uuidString)
            if let thread = article.thread {
                for member in thread.members {
                    ids.insert(member.id.uuidString)
                }
            }
        }
        if let lead = composition.lead { addArticle(lead) }
        composition.features.forEach(addArticle)
        // `shownArticles`, not `articles`: a section's budget-limited overflow
        // (unexpanded "show more") has no card on screen at all — counting it
        // as presented would fire the alert for something not navigable,
        // defeating the whole point of a render witness.
        for section in composition.sections {
            section.shownArticles.forEach(addArticle)
        }
        return ids
    }

    @MainActor
    private func noteFrontPageMessagesPresented(_ messageIDs: Set<String>) {
        guard state.activeFrame.spatialLens == .frontPage else { return }
        if pendingLiveInboundPresentations.keys.contains(where: messageIDs.contains) {
            ConstellationLog.logger.notice(
                "noteFrontPageMessagesPresented matches pending: \(messageIDs.joined(separator: ","), privacy: .public)"
            )
        }
        Self.performSameTurnLiveInboundAcknowledgement(
            recordPresentation: {
                renderedLiveInboundMessageIDs.formUnion(messageIDs)
            },
            acknowledge: {
                acknowledgeRenderedLiveInboundMessages()
            }
        )
    }

    @MainActor
    private func noteCurrentMetalPacketDrawn() {
        let frame = state.activeFrame.spatialLens
        guard Self.usesMetalScene(frame),
              renderPacketFrame.spatialLens == frame else {
            return
        }
        let pending = Set(pendingLiveInboundPresentations.keys)
        guard pending.isEmpty == false else { return }
        Self.performSameTurnLiveInboundAcknowledgement(
            recordPresentation: {
                renderedLiveInboundMessageIDs.formUnion(
                    renderPacket.stars.lazy.map(\.messageId).filter(pending.contains)
                )
            },
            acknowledge: {
                acknowledgeRenderedLiveInboundMessages()
            }
        )
    }

    /// Runs the render witness and its unified-arrival acknowledgement without
    /// yielding to the task scheduler. A presented message must not sit visible
    /// while badge, sound, and system notification wait behind unrelated work.
    @MainActor
    static func performSameTurnLiveInboundAcknowledgement(
        recordPresentation: () -> Void,
        acknowledge: () -> Void
    ) {
        recordPresentation()
        acknowledge()
    }

    /// Completes the inverse event ordering too: a lens may have already
    /// reported the mounted message by the time its readiness event reaches
    /// this view. Consume that existing render witness immediately instead of
    /// waiting for SwiftUI to schedule the observation-key task.
    @MainActor
    static func performSameTurnLiveInboundPendingRegistration(
        registerPending: () -> Void,
        acknowledge: () -> Void
    ) {
        registerPending()
        acknowledge()
    }

    nonisolated static func presentedLiveInboundMessageIDs(
        pendingMessageIDs: Set<String>,
        activeFrame: FrameKey,
        frontPageMessageIDs: Set<String>,
        projectsMessageIDs: Set<String>,
        timelineMessageIDs: Set<String>,
        metalMessageIDs: Set<String>
    ) -> Set<String> {
        let installed: Set<String>
        switch activeFrame.spatialLens {
        case .frontPage:
            installed = frontPageMessageIDs
        case .projects:
            installed = projectsMessageIDs
        case .timeline:
            installed = timelineMessageIDs
        default:
            installed = metalMessageIDs
        }
        return pendingMessageIDs.intersection(installed)
    }

    nonisolated static func focusedArrivalMessageIDs(
        activeFrame: FrameKey,
        metalMessageID: String?,
        frontPageReaderMessageID: String?,
        frontPageThreadMessageIDs: Set<String>,
        timelineMessageID: String?,
        projectsMessageIDs: Set<String>
    ) -> Set<String> {
        switch activeFrame.spatialLens {
        case .frontPage:
            var messageIDs = frontPageThreadMessageIDs
            if let frontPageReaderMessageID {
                messageIDs.insert(frontPageReaderMessageID)
            }
            return messageIDs
        case .timeline:
            return timelineMessageID.map { [$0] } ?? []
        case .projects:
            return projectsMessageIDs
        default:
            return metalMessageID.map { [$0] } ?? []
        }
    }

    /// Hydrates each announced arrival's canonical `MessageFilterRow` from
    /// SwiftData (one row fetch per arrival — arrivals are rare events) and
    /// patches it into every cached frame snapshot, with the same
    /// account-hue/aging color the canonical rebuild will bake. Announced
    /// ids only: an embargoed row must never enter a visible surface, and
    /// the ledger's announce gate has already verified pipeline readiness
    /// and placement for these ids.
    @MainActor
    private func upsertAnnouncedArrivalsIntoSnapshotCache(messageIDs: [UUID]) {
        var rows: [String: MessageFilterRow] = [:]
        var colors: [String: SIMD4<Float>] = [:]
        var meaningColors: [String: SIMD4<Float>] = [:]
        let accountColorIndex = accountColorIndexByAccountId()
        let now = Date.now
        for messageID in messageIDs {
            guard NewMailArrivalLedger.shared.isAnnounced(messageID: messageID),
                  let row = newStarMessageFilterRow(for: messageID) else { continue }
            let key = messageID.uuidString
            rows[key] = row
            let colorIndex = row.accountId.flatMap { accountColorIndex[$0] }
            meaningColors[key] = AccountColorPalette.rgb(
                for: AccountColorPalette.color(forIndex: colorIndex), brightness: 1.0
            )
            colors[key] = ConstellationSnapshotLoader.timelineColor(
                date: row.receivedAt ?? row.ingestedAt,
                reference: now,
                color: AccountColorPalette.color(forIndex: colorIndex)
            )
        }
        guard rows.isEmpty == false else { return }
        snapshotCache.upsertArrivals(rows: rows, colors: colors, meaningColors: meaningColors)
    }

    static func liveInboundPayload(from notification: Notification) -> IMAPLiveInboundPayload? {
        let userInfo = notification.userInfo ?? [:]
        let accountID: UUID?
        if let id = userInfo["accountID"] as? UUID {
            accountID = id
        } else if let raw = userInfo["accountID"] as? String {
            accountID = UUID(uuidString: raw)
        } else {
            accountID = nil
        }
        guard let accountID else { return nil }

        let folder = userInfo["folder"] as? String ?? "INBOX"
        let ids: [UUID]
        if let uuidIDs = userInfo["messageIDs"] as? [UUID] {
            ids = uuidIDs
        } else if let rawIDs = userInfo["messageIDs"] as? [String] {
            ids = rawIDs.compactMap(UUID.init(uuidString:))
        } else {
            ids = []
        }
        guard ids.isEmpty == false else { return nil }

        let count = max(userInfo["count"] as? Int ?? ids.count, ids.count)
        let observedAt = userInfo["observedAt"] as? Date ?? Date.now
        return IMAPLiveInboundPayload(
            accountID: accountID,
            folder: folder,
            count: count,
            messageIDs: ids,
            observedAt: observedAt
        )
    }

    private static func liveInboundUserInfo(
        for event: IMAPLiveInboundPayload
    ) -> [AnyHashable: Any] {
        [
            "accountID": event.accountID,
            "folder": event.folder,
            "count": event.count,
            "messageIDs": event.messageIDs,
            "observedAt": event.observedAt
        ]
    }

    @MainActor
    private func selectNodeForDetailFocus(
        _ proxy: HitProxy,
        screenPoint: CGPoint,
        personFocus: LockedPersonFocus? = nil
    ) {
        // Solar-system People scenes can be stopped mid-orbit, displaced
        // from the packet's orbital epoch. Every position captured at
        // click time (flight target, source preview, pin) must be the
        // LIVE rendered position — the locked replan then bakes the same
        // pose at the frozen clock, so the whole entry stays seamless.
        // Identity outside the solar system / at zero displacement.
        let liveProxy = HitProxy(
            messageId: proxy.messageId,
            vectorId: proxy.vectorId,
            worldPosition: metalRenderer.peopleLiveWorldPosition(for: proxy),
            radiusPixels: proxy.radiusPixels
        )
        let sourceColor = renderedNodeColor(for: liveProxy)
        let transitionPoint = transitionPoint(fromDetailPoint: screenPoint)
        installFocusSourcePreview(
            proxy: liveProxy,
            clickPoint: screenPoint,
            transitionClickPoint: transitionPoint,
            sourceColor: sourceColor
        )
        queueSelectedNodeFocus(
            vectorId: liveProxy.vectorId,
            fallbackWorld: liveProxy.worldPosition,
            initialScreenPoint: screenPoint,
            initialTransitionPoint: transitionPoint,
            sourceColor: sourceColor,
            startZoomImmediately: true,
            personFocus: personFocus
        )
    }

    @MainActor
    private func selectPersonHub(_ hub: PersonHubInstance, screenPoint: CGPoint) {
        guard let messageId = hub.representativeMessageId,
              let vectorId = hub.representativeVectorId else { return }
        hoveredPersonEmail = nil
        // Live (possibly displaced) hub position — see the note in
        // `selectNodeForDetailFocus`.
        let livePosition = metalRenderer.peopleLiveHubPosition(
            email: hub.email,
            basePosition: hub.position
        )
        let proxy = HitProxy(
            messageId: messageId,
            vectorId: vectorId,
            worldPosition: livePosition,
            radiusPixels: max(18, hub.radius * 1_100)
        )
        // Outer EDGE of the outermost ring band = mid-line radius +
        // half-width thickness. The dial wedge samples this radius (not
        // `hub.maxRingRadius`, which is the mid-line) so the inner-arc
        // leader traces the visible outer fringe of the Saturn rings,
        // not the centre line buried inside the band.
        selectNodeForDetailFocus(proxy, screenPoint: screenPoint, personFocus: lockedPersonFocus(for: hub))
        markNewStarVisited(messageId: messageId)
    }

    @MainActor
    private func lockedPersonFocus(for hub: PersonHubInstance) -> LockedPersonFocus {
        let outermostRing = hub.rings.max(by: { $0.radius < $1.radius })
        let outerEdge: Float = outermostRing.map { $0.radius + $0.thickness } ?? 0
        return LockedPersonFocus(
            email: hub.email,
            displayName: hub.displayName,
            // Live rendered position: this value becomes the portrait's
            // `pinnedHubWorldPosition`, and the locked replan (built at
            // the frozen orbital clock) must agree with it exactly.
            worldPosition: metalRenderer.peopleLiveHubPosition(
                email: hub.email,
                basePosition: hub.position
            ),
            messageIds: currentPeopleScopeMessageIds(for: hub),
            ringNormal: hub.ringNormal,
            outerRingEdgeRadius: outerEdge
        )
    }

    @MainActor
    private func personHub(for proxy: HitProxy) -> PersonHubInstance? {
        guard proxy.messageId.hasPrefix(Self.personProxyMessagePrefix) else { return nil }
        let email = String(proxy.messageId.dropFirst(Self.personProxyMessagePrefix.count))
        return renderPacket.personHubs.first { $0.email == email }
    }

    @MainActor
    private func meaningClusterHub(for proxy: HitProxy) -> MeaningClusterHubInstance? {
        guard proxy.messageId.hasPrefix(Self.meaningClusterProxyMessagePrefix) else { return nil }
        let idString = String(proxy.messageId.dropFirst(Self.meaningClusterProxyMessagePrefix.count))
        guard let clusterId = Int64(idString) else { return nil }
        return renderPacket.meaningClusterHubs.first { $0.clusterId == clusterId }
    }

    /// Single writer for the hovered Meaning cluster: keeps the SwiftUI
    /// hover-card state and the renderer's nucleus-flare lane in lockstep
    /// (mirrors `setHoveredOrbitPathHub` on the People lens).
    @MainActor
    private func setHoveredMeaningCluster(_ clusterId: Int64?) {
        hoveredMeaningClusterId = clusterId
        metalRenderer.setHoveredMeaningCluster(clusterId: clusterId)
    }

    @MainActor
    private func showMeaningClusterHover(
        _ hub: MeaningClusterHubInstance,
        at point: CGPoint,
        anchorWorld: SIMD3<Float>? = nil
    ) {
        state.hoveredVectorId = nil
        hoveredPersonEmail = nil
        setHoveredMeaningCluster(hub.clusterId)
        meaningClusterHoverHeight = 0
        meaningClusterHoverBodyHeight = 0
        // Anchor the leader to the hovered nucleus's projected centroid,
        // not to the cursor's hit point inside the cluster blob.
        // Falls back to the cursor point if projection fails (camera
        // frustum cull etc.).
        let projected = ScreenProjection.project(
            world: anchorWorld ?? hub.position,
            camera: cameraController.state,
            viewSize: viewSize,
            fovYRadians: .pi / 3
        ) ?? point
        hoverNodePoint = projected
        hoverPosition = Self.placeHoverPopupAdjacent(
            nodePoint: projected,
            viewSize: viewSize
        ).center
    }

    // MARK: - Meaning-lens cluster filter

    /// Single-click toggle on a Meaning-lens cluster hub. Clicking the
    /// already-focused cluster clears the filter (restoring the slider);
    /// clicking any other cluster focuses the scene on it. Engage/clear both
    /// dismiss any open cluster hover popup so it doesn't linger over the
    /// freshly filtered scene.
    @MainActor
    private func toggleMeaningClusterFilter(clusterId: Int64) {
        if state.filter.clusterIds == [clusterId] {
            clearMeaningClusterFilter()
        } else {
            engageMeaningClusterFilter(clusterId)
        }
    }

    /// Replace the cluster scope with exactly this cluster (right-click menu).
    @MainActor
    private func focusMeaningClusterFilter(_ clusterId: Int64) {
        engageMeaningClusterFilter(clusterId)
    }

    /// Engage (or switch to) a single-cluster scope with a focus-style camera
    /// warp toward the cluster — the same entrance the locked-node overlay uses,
    /// so filtering to a cluster feels like flying into it. The pre-filter
    /// camera is captured on the first engage so `clearMeaningClusterFilter`
    /// can reverse-warp back out.
    @MainActor
    private func engageMeaningClusterFilter(_ clusterId: Int64) {
        dismissMeaningClusterHover()
        let targetIds: Set<Int64> = [clusterId]
        guard state.filter.clusterIds != targetIds else { return }

        // Frame the cluster from the *current* (pre-filter) packet, where its
        // hub still exists. Filtering doesn't move nodes, so the framing stays
        // valid once the scene contracts to the cluster.
        let target = clusterFocusTargetCamera(clusterId: clusterId)
        // Capture the return camera only when we'll actually warp in, so the
        // exit warp stays symmetric with the entrance (warp in ⇔ warp out).
        if clusterFilterRestoreCamera == nil, target != nil {
            clusterFilterRestoreCamera = cameraController.state
            clusterFilterSourceHubs = renderPacket.meaningClusterHubs
        }

        guard let target else {
            applyMeaningClusterFilterIds(targetIds, suppressingFilterCameraReset: false)
            return
        }

        clusterFilterTransitionSequence += 1
        let sequence = clusterFilterTransitionSequence
        var didScheduleFilterApplication = false

        pendingMeaningClusterEngageId = clusterId
        warpAnimator.engage(to: target, profile: .meaningFocus)
        clusterFilterWarpSequence = sequence
        warpAnimator.onProgress = { progress in
            let decision = Self.meaningClusterFilterProgressDecision(
                progress: progress,
                didApplyFilter: didScheduleFilterApplication,
                sequence: sequence,
                currentSequence: sequence,
                activeFrame: .meaning
            )
            if decision.shouldApplyFilter {
                didScheduleFilterApplication = true
                Task { @MainActor in
                    guard clusterFilterTransitionSequence == sequence,
                          state.activeFrame.spatialLens == .meaning else { return }
                    applyMeaningClusterFilterIds(targetIds, suppressingFilterCameraReset: true)
                    if pendingMeaningClusterEngageId == clusterId {
                        pendingMeaningClusterEngageId = nil
                    }
                }
            }
            return decision.keepProgressCallback
        }
        warpAnimator.onComplete = {
            let shouldApplyFilter = !didScheduleFilterApplication
            if shouldApplyFilter {
                didScheduleFilterApplication = true
            }
            Task { @MainActor in
                guard clusterFilterTransitionSequence == sequence else { return }
                if shouldApplyFilter,
                   state.activeFrame.spatialLens == .meaning {
                    applyMeaningClusterFilterIds(targetIds, suppressingFilterCameraReset: true)
                }
                if pendingMeaningClusterEngageId == clusterId {
                    pendingMeaningClusterEngageId = nil
                }
                if clusterFilterWarpSequence == sequence {
                    finishMeaningClusterFilterWarp(sequence: sequence)
                }
            }
        }
    }

    /// Drop this cluster from the active scope; clears the dimension entirely
    /// (and reverse-warps out) when it was the only cluster.
    @MainActor
    private func removeMeaningClusterFilter(_ clusterId: Int64) {
        var ids = state.filter.clusterIds ?? []
        ids.remove(clusterId)
        if ids.isEmpty {
            clearMeaningClusterFilter()
        } else {
            dismissMeaningClusterHover()
            applyMeaningClusterFilterIds(ids, suppressingFilterCameraReset: false)
        }
    }

    /// Clear the cluster scope, reverse-warping the camera back to where it was
    /// before the filter engaged (mirroring node-focus exit), and restore the
    /// cluster-display slider.
    @MainActor
    private func clearMeaningClusterFilter() {
        dismissMeaningClusterHover()
        pendingMeaningClusterEngageId = nil
        let restore = clusterFilterRestoreCamera
        clusterFilterRestoreCamera = nil
        clusterFilterSourceHubs = []
        clusterFilterTransitionSequence += 1
        let sequence = clusterFilterTransitionSequence
        if let restore {
            warpAnimator.engage(to: restore, profile: .meaningFocus)
            clusterFilterWarpSequence = sequence
            warpAnimator.onComplete = {
                Task { @MainActor in
                    guard clusterFilterTransitionSequence == sequence else { return }
                    finishMeaningClusterFilterWarp(sequence: sequence)
                }
            }
            applyMeaningClusterFilterIds(nil, suppressingFilterCameraReset: true)
        } else {
            clusterFilterWarpSequence = nil
            applyMeaningClusterFilterIds(nil, suppressingFilterCameraReset: false)
        }
    }

    @MainActor
    private func applyMeaningClusterFilterIds(
        _ clusterIds: Set<Int64>?,
        suppressingFilterCameraReset: Bool
    ) {
        let application = Self.meaningClusterFilterApplication(
            currentClusterIds: state.filter.clusterIds,
            targetClusterIds: clusterIds,
            suppressingFilterCameraReset: suppressingFilterCameraReset
        )
        guard application.shouldMutate else { return }
        if application.shouldSuppressCameraReset {
            suppressFilterCameraReset = true
            if state.activeFrame.spatialLens == .meaning {
                var targetFilter = state.filter
                targetFilter.clusterIds = clusterIds
                pendingFilterCameraReset = filterCameraResetSignature(
                    frame: state.activeFrame,
                    filter: targetFilter
                )
            }
        }
        state.filter.clusterIds = clusterIds
    }

    @MainActor
    private func finishMeaningClusterFilterWarp(sequence: Int) {
        guard clusterFilterTransitionSequence == sequence else { return }
        if clusterFilterWarpSequence == sequence {
            clusterFilterWarpSequence = nil
        }
        Task { await applyPendingFilterCameraResetIfReady(for: state.activeFrame) }
    }

    nonisolated static func meaningClusterFilterProgressDecision(
        progress: Float,
        didApplyFilter: Bool,
        sequence: Int,
        currentSequence: Int,
        activeFrame: FrameKey
    ) -> (shouldApplyFilter: Bool, keepProgressCallback: Bool) {
        guard sequence == currentSequence,
              activeFrame.spatialLens == .meaning,
              !didApplyFilter else {
            return (false, false)
        }
        if progress >= LiveFocusFramingPolicy.sceneContractionProgress {
            return (true, false)
        }
        return (false, true)
    }

    nonisolated static func meaningClusterFilterApplication(
        currentClusterIds: Set<Int64>?,
        targetClusterIds: Set<Int64>?,
        suppressingFilterCameraReset: Bool
    ) -> (shouldMutate: Bool, shouldSuppressCameraReset: Bool) {
        let shouldMutate = currentClusterIds != targetClusterIds
        return (
            shouldMutate,
            shouldMutate && suppressingFilterCameraReset
        )
    }

    nonisolated static func shouldCancelMeaningClusterFilterWarpForFrameSwitch(
        from activeFrame: FrameKey,
        to resolvedFrame: FrameKey,
        activeWarpSequence: Int?,
        currentTransitionSequence: Int,
        isWarping: Bool
    ) -> Bool {
        isWarping
            && activeFrame.spatialLens == .meaning
            && resolvedFrame.spatialLens != .meaning
            && activeWarpSequence == currentTransitionSequence
    }

    /// Target camera framing a cluster's members for the focus-style warp.
    /// Reuses the Meaning live-focus framing policy so a cluster fills the view
    /// with the same zoom depth as a node neighbourhood. Falls back to framing
    /// the centroid alone when the hub carries no member halos.
    @MainActor
    private func clusterFocusTargetCamera(clusterId: Int64) -> CameraState? {
        func clusterHub(in hubs: [MeaningClusterHubInstance]) -> MeaningClusterHubInstance? {
            hubs.first { $0.clusterId == clusterId }
        }
        guard let hub = clusterHub(in: renderPacket.meaningClusterHubs)
            ?? clusterHub(in: clusterFilterSourceHubs) else {
            return nil
        }
        return Self.meaningClusterFocusTargetCamera(
            hub: hub,
            current: cameraController.state
        )
    }

    static func meaningClusterFocusTargetCamera(
        hub: MeaningClusterHubInstance,
        current: CameraState
    ) -> CameraState {
        let contextPositions = LiveFocusFramingPolicy.contextPositions(
            center: hub.position,
            candidates: hub.memberHalos.map(\.position)
        )
        let focusRadius = LiveFocusFramingPolicy.focusRadius(
            center: hub.position,
            contextPositions: contextPositions
        )
        return LiveFocusFramingPolicy.targetCamera(
            center: hub.position,
            current: current,
            focusRadius: focusRadius
        )
    }

    /// Dismiss any lingering cluster hover popup. Clearing the filter removes
    /// the chip from the hierarchy, and SwiftUI does not reliably deliver the
    /// chip's `.onHover(false)` on removal — so the popup the chip-hover opened
    /// would otherwise persist over the unfiltered scene with nothing under the
    /// cursor. Called from every filter-clearing path (chip ✕, Esc, menu).
    @MainActor
    private func dismissMeaningClusterHover() {
        setHoveredMeaningCluster(nil)
        hoverNodePoint = .zero
    }

    /// The cluster's rendered ramp hue, read from the live packet so chip
    /// and hover-card accents always match the gas on screen. Falls back to
    /// the palette's anchor base when the hub isn't in the packet (culled,
    /// ambient, or a multi-cluster scope).
    @MainActor
    private func meaningClusterTint(for clusterId: Int64?) -> SIMD3<Float> {
        if let clusterId,
           let hub = (renderPacket.meaningClusterHubs + clusterFilterSourceHubs)
            .first(where: { $0.clusterId == clusterId }) {
            return hub.color
        }
        return MeaningClusterLensPalette.resolve(isDarkAppearance: colorScheme == .dark).base
    }

    /// Human-readable title for a cluster, disambiguated against other live
    /// labels so the chip / menu / tooltip never present two groups as one.
    /// Roster callers pass `disambiguatedTitles` from one batch pass over the
    /// presented labels instead of disambiguating each cluster separately.
    @MainActor
    private func meaningClusterTitle(
        for clusterId: Int64,
        disambiguatedTitles: [Int64: String]? = nil
    ) -> String {
        let disambiguated: String?
        if let disambiguatedTitles {
            disambiguated = disambiguatedTitles[clusterId]
        } else {
            disambiguated = MeaningClusterTitleDisambiguator.title(
                for: clusterId,
                labelsByClusterId: meaningClusterPresentationLabels(including: clusterId)
            )
        }
        if let disambiguated {
            return disambiguated
        }
        if let cluster = clusters.first(where: { $0.id == clusterId }) {
            let terms = MeaningClusterLabel.persistedLabelTerms(from: cluster.label)
            if let title = MeaningClusterLabel.fallbackTitle(from: terms) {
                return title
            }
            if let persisted = cluster.label, !persisted.isEmpty {
                return persisted
            }
        }
        return "Cluster"
    }

    @MainActor
    private func meaningClusterPresentationLabels(
        including clusterId: Int64? = nil
    ) -> [Int64: MeaningClusterLabel] {
        var presentedIDs = Set(
            (renderPacket.meaningClusterHubs + clusterFilterSourceHubs).map(\.clusterId)
        )
        if let clusterId {
            presentedIDs.insert(clusterId)
        }
        return meaningLabeler.labelsByClusterId.filter { presentedIDs.contains($0.key) }
    }

    /// Messages in the engaged cluster scope that pass every other filter.
    /// The exact count arrives off the main actor with each cluster-scoped
    /// packet (`scheduleMeaningClusterScopeMessageCount`), so a view update
    /// never scans the message index. Until that count describes the live
    /// filter the chip shows its pending mark rather than an approximation.
    @MainActor
    private func meaningClusterFilteredMessageCount() -> Int? {
        guard let stored = meaningClusterScopeMessageCount,
              stored.filter == state.filter,
              stored.selectedTimeRange == state.selectedTimeRange else {
            return nil
        }
        return stored.count
    }

    /// Recounts the engaged cluster scope on the concurrent executor each
    /// time a Meaning packet installs, using the same index and visual
    /// filter the packet was planned from. Clears the count when no cluster
    /// scope is engaged.
    @MainActor
    private func scheduleMeaningClusterScopeMessageCount(
        filter: VectorFilter,
        selectedTimeRange: TimeRangePreset,
        visualFilter: VectorFilter,
        messageIndex: [String: MessageFilterRow]
    ) {
        meaningClusterScopeMessageCountTask?.cancel()
        guard filter.clusterIds?.isEmpty == false else {
            meaningClusterScopeMessageCountTask = nil
            if meaningClusterScopeMessageCount != nil {
                meaningClusterScopeMessageCount = nil
            }
            return
        }
        meaningClusterScopeMessageCountTask = Task { @MainActor in
            let count = await Task.detached(priority: .userInitiated) {
                Self.countMeaningClusterScopeMessages(
                    messageIndex: messageIndex,
                    filter: visualFilter
                )
            }.value
            guard !Task.isCancelled else { return }
            let result = MeaningClusterScopeMessageCount(
                filter: filter,
                selectedTimeRange: selectedTimeRange,
                count: count
            )
            if meaningClusterScopeMessageCount != result {
                meaningClusterScopeMessageCount = result
            }
        }
    }

    nonisolated static func countMeaningClusterScopeMessages(
        messageIndex: [String: MessageFilterRow],
        filter: VectorFilter
    ) -> Int {
        var count = 0
        for row in messageIndex.values
        where ConstellationMessageFilter.matches(row, filter: filter) {
            count += 1
        }
        return count
    }

    /// Descriptor the Meaning column renders in place of the cluster slider
    /// while a cluster filter is engaged. `nil` outside the Meaning lens or
    /// when no cluster scope is set (slider shows).
    @MainActor
    private var activeMeaningClusterFilter: MeaningClusterFilterDescriptor? {
        guard state.activeFrame.spatialLens == .meaning,
              let ids = state.filter.clusterIds, !ids.isEmpty else {
            return nil
        }
        let count = meaningClusterFilteredMessageCount()
        if ids.count == 1, let clusterId = ids.first {
            return MeaningClusterFilterDescriptor(
                clusterId: clusterId,
                title: meaningClusterTitle(for: clusterId),
                messageCount: count,
                tint: meaningClusterTint(for: clusterId)
            )
        }
        return MeaningClusterFilterDescriptor(
            clusterId: nil,
            title: "\(ids.count) clusters",
            messageCount: count,
            tint: meaningClusterTint(for: nil)
        )
    }

    /// Rows for the cluster list popover, in the renderer's cluster order.
    /// While scoped, the pre-filter hubs keep the same roster available so a
    /// second selection can widen the filter instead of disappearing.
    @MainActor
    private var meaningClusterListEntries: [MeaningClusterListEntry] {
        guard state.activeFrame.spatialLens == .meaning,
              meaningClusterPipelineStatus.isReadyForDisplay,
              effectiveMeaningClusterDisplayCount > ClusterDetectPayload.noMeaningTargetClusters
        else { return [] }
        // Pending engage folds into the active set so a clicked row checks
        // itself immediately instead of ~2 seconds later when the warp's
        // deferred filter write lands.
        var active = state.filter.clusterIds ?? []
        if let pendingMeaningClusterEngageId {
            active.insert(pendingMeaningClusterEngageId)
        }
        let scopeEngaged = pendingMeaningClusterEngageId != nil
            || state.filter.clusterIds?.isEmpty == false
        let roster = Self.meaningClusterListRoster(
            renderedHubs: renderPacket.meaningClusterHubs,
            retainedBroadHubs: clusterFilterSourceHubs,
            scopeEngaged: scopeEngaged
        )
        let liveClusterIds = Set(clusters.map(\.id))
        // One batch title pass and one tint lookup table for the whole
        // roster: both are read on every view update while Meaning is open.
        let disambiguatedTitles = MeaningClusterTitleDisambiguator.titles(
            labelsByClusterId: meaningClusterPresentationLabels()
        )
        var tintByClusterId: [Int64: SIMD3<Float>] = [:]
        for hub in renderPacket.meaningClusterHubs + clusterFilterSourceHubs
        where tintByClusterId[hub.clusterId] == nil {
            tintByClusterId[hub.clusterId] = hub.color
        }
        let ambientTint = meaningClusterTint(for: nil)
        return roster.compactMap { row in
            guard liveClusterIds.contains(row.clusterId) else { return nil }
            return MeaningClusterListEntry(
                clusterId: row.clusterId,
                title: meaningClusterTitle(
                    for: row.clusterId,
                    disambiguatedTitles: disambiguatedTitles
                ),
                visibleMessageCount: row.visibleCount,
                tint: tintByClusterId[row.clusterId] ?? ambientTint,
                isActive: active.contains(row.clusterId)
            )
        }
    }

    /// One list row per rendered cluster, preserving renderer rank, with the
    /// cluster's visible support in the roster's scope (the same count the
    /// hover card reports). An engaged scope reads from its retained broad
    /// packet, so rows keep the counts measured before the cluster filter.
    nonisolated static func meaningClusterListRoster(
        renderedHubs: [MeaningClusterHubInstance],
        retainedBroadHubs: [MeaningClusterHubInstance],
        scopeEngaged: Bool
    ) -> [(clusterId: Int64, visibleCount: Int)] {
        let source = scopeEngaged && !retainedBroadHubs.isEmpty
            ? retainedBroadHubs
            : renderedHubs
        var seen: Set<Int64> = []
        return source.compactMap { hub -> (clusterId: Int64, visibleCount: Int)? in
            guard seen.insert(hub.clusterId).inserted else { return nil }
            return (clusterId: hub.clusterId, visibleCount: hub.memberCount)
        }
    }

    nonisolated static func meaningClusterListClusterIds(
        renderedHubs: [MeaningClusterHubInstance],
        retainedBroadHubs: [MeaningClusterHubInstance],
        scopeEngaged: Bool
    ) -> [Int64] {
        meaningClusterListRoster(
            renderedHubs: renderedHubs,
            retainedBroadHubs: retainedBroadHubs,
            scopeEngaged: scopeEngaged
        ).map(\.clusterId)
    }

    /// Resolved action for one multi-select toggle from the cluster list.
    enum MeaningClusterScopeToggleAction: Equatable {
        /// Empty scope → first cluster: the warped single-cluster engage.
        case engage(Int64)
        /// Widen or narrow an existing scope in place, no flight.
        case apply(Set<Int64>)
        /// The last cluster left the scope: standard clear + restore warp.
        case clear
    }

    /// The effective scope is what the user believes is selected: the
    /// applied filter ids intersected with the live cluster records (ids
    /// from a superseded detection run are dropped, so stale scope can
    /// never strand an unclearable filter), plus any engage still in
    /// flight (its filter write is deferred to the warp's contraction
    /// point — without folding it in, a second toggle within the ~2 s
    /// flight would silently replace the first selection).
    nonisolated static func meaningClusterScopeToggleAction(
        appliedIds: Set<Int64>?,
        pendingEngageId: Int64?,
        toggledId: Int64,
        liveClusterIds: Set<Int64>
    ) -> MeaningClusterScopeToggleAction {
        var effective = (appliedIds ?? []).intersection(liveClusterIds)
        if let pendingEngageId {
            effective.insert(pendingEngageId)
        }
        if effective.contains(toggledId) {
            effective.remove(toggledId)
            return effective.isEmpty ? .clear : .apply(effective)
        }
        if effective.isEmpty {
            return .engage(toggledId)
        }
        effective.insert(toggledId)
        return .apply(effective)
    }

    /// Multi-select toggle from the cluster list. Entering scope from empty
    /// keeps the single-cluster camera warp; widening or narrowing an
    /// existing scope re-filters in place with no flight; removing the last
    /// cluster restores the pre-filter camera via the standard clear path.
    @MainActor
    private func toggleMeaningClusterScopeMembership(_ clusterId: Int64) {
        switch Self.meaningClusterScopeToggleAction(
            appliedIds: state.filter.clusterIds,
            pendingEngageId: pendingMeaningClusterEngageId,
            toggledId: clusterId,
            liveClusterIds: Set(clusters.map(\.id))
        ) {
        case .engage(let id):
            engageMeaningClusterFilter(id)
        case .clear:
            clearMeaningClusterFilter()
        case .apply(let ids):
            // Supersede any in-flight engage's deferred filter write:
            // bumping the transition sequence invalidates its scheduled
            // application (every deferred task guards on the sequence), so
            // the landing warp can no longer overwrite this wider scope.
            // The flight itself continues — its destination cluster is in
            // scope either way. The stale `clusterFilterWarpSequence` is
            // harmless: every consumer compares it against the CURRENT
            // transition sequence, so a stale value already reads as
            // inactive.
            pendingMeaningClusterEngageId = nil
            clusterFilterTransitionSequence += 1
            dismissMeaningClusterHover()
            applyMeaningClusterFilterIds(ids, suppressingFilterCameraReset: false)
        }
    }

    /// Hover on a cluster list row. Mirrors hovering the cluster's nucleus:
    /// surfaces the rich cluster popup anchored at the cluster's largest
    /// on-screen lobe, so the row points at which gas body it names. Rows
    /// whose cluster isn't in the current packet — or whose lobes are
    /// outside the viewport (behind or beside the camera) — show only
    /// their `.help` tooltip, never a card tethered to a phantom point.
    @MainActor
    private func handleMeaningClusterRowHover(_ clusterId: Int64, entering: Bool) {
        if entering {
            let lobes = renderPacket.meaningClusterHubs.filter { $0.clusterId == clusterId }
            guard let hub = lobes.max(by: { $0.memberCount < $1.memberCount }),
                  let projected = ScreenProjection.project(
                      world: hub.position,
                      camera: cameraController.state,
                      viewSize: viewSize,
                      fovYRadians: .pi / 3
                  ),
                  CGRect(origin: .zero, size: viewSize)
                      .insetBy(dx: -12, dy: -12)
                      .contains(projected)
            else { return }
            showMeaningClusterHover(hub, at: projected, anchorWorld: hub.position)
        } else if hoveredMeaningClusterId == clusterId {
            setHoveredMeaningCluster(nil)
            hoverNodePoint = .zero
        }
    }

    /// Hover on the column's cluster-filter chip. Mirrors hovering the cluster
    /// orb itself: surfaces the rich cluster popup (full title + terms + live
    /// count) anchored to the cluster's on-screen centroid. The chip's own
    /// `.help` tooltip is the always-on fallback when the hub isn't on screen.
    @MainActor
    private func handleMeaningClusterChipHover(_ entering: Bool) {
        guard let ids = state.filter.clusterIds, ids.count == 1,
              let clusterId = ids.first else { return }
        if entering {
            if let hub = renderPacket.meaningClusterHubs.first(where: { $0.clusterId == clusterId }) {
                showMeaningClusterHover(hub, at: .zero)
            }
        } else if hoveredMeaningClusterId == clusterId {
            setHoveredMeaningCluster(nil)
            hoverNodePoint = .zero
        }
    }

    /// Right-click menu for a Meaning-lens cluster hub: focus the scene on the
    /// cluster, or drop it when it is already in scope.
    @MainActor
    private func presentMeaningClusterContextMenu(
        clusterId: Int64,
        at point: NSPoint,
        in view: NSView
    ) {
        state.hoveredVectorId = nil
        setHoveredMeaningCluster(nil)
        hoverNodePoint = .zero
        let isActive = (state.filter.clusterIds ?? []).contains(clusterId)
        MeaningClusterContextMenu.present(
            at: point,
            in: view,
            title: meaningClusterTitle(for: clusterId),
            isActive: isActive,
            onFilter: { [self] in focusMeaningClusterFilter(clusterId) },
            onRemove: { [self] in removeMeaningClusterFilter(clusterId) }
        )
    }

    @MainActor
    private var hoveredPersonHubContext: PersonHubHoverContext? {
        guard let email = hoveredPersonEmail,
              let hub = renderPacket.personHubs.first(where: { $0.email == email }) else {
            return nil
        }
        let messageIds = currentPeopleScopeMessageIds(for: hub)
        guard state.activeFrame.spatialLens == .people else {
            return makePersonHubHoverContext(hub: hub, email: email, messageIds: messageIds)
        }
        // Hover updates arrive on every mouse move over the planet. The card
        // is a function of the hub, its scope, the gated message index, and
        // the accounts, so it is recomputed only when one of them changes —
        // not once per pointer event.
        let key = PersonHubHoverContextKey(
            email: hub.email,
            displayName: hub.displayName,
            isInstitutional: hub.isInstitutional,
            messageIds: messageIds,
            frame: state.activeFrame,
            snapshotRevision: snapshotCache.contentRevision,
            drawnPacketGeneratedAt: basePacket.generatedAt,
            gate: NewMailArrivalLedger.shared.visibilityGate(),
            accounts: accounts.map { account in
                PersonHubHoverAccountKey(id: account.id, context: hoverAccountContext(for: account))
            }
        )
        return personHubHoverContextMemo.value(for: key) {
            makePersonHubHoverContext(hub: hub, email: email, messageIds: messageIds)
        }
    }

    @MainActor
    private func makePersonHubHoverContext(
        hub: PersonHubInstance,
        email: String,
        messageIds: Set<String>
    ) -> PersonHubHoverContext {
        let messageIndex = currentMessageIndex
        let rows = messageIds.compactMap { messageIndex[$0] }
        let metrics = PersonHubHoverMetrics(rows: rows, email: email)
        let accountsById = Dictionary(
            uniqueKeysWithValues: accounts.map { account in
                (account.id, hoverAccountContext(for: account))
            }
        )
        // `basePacket` is what the scene draws, after its node caps and
        // without transient dying-node ghosts. Its total counts every
        // placement before the caps, so an equal star count means nothing
        // was trimmed anywhere. Onboarding reveals nodes progressively, which
        // is not trimming.
        let drawnPacket = basePacket
        let sceneWasTrimmed = drawnPacket.stars.count < drawnPacket.totalMessageCount
        let shownNodeCount: Int? = if sceneWasTrimmed && !onboardingMode {
            CorrespondentShownNodes.shownCount(
                placedMessageIds: hub.messageIds,
                drawnMessageIds: CorrespondentShownNodes.drawnMessageIds(
                    onRingOf: hub.email,
                    stars: drawnPacket.stars
                ),
                messageCount: metrics.messageCount
            )
        } else {
            nil
        }
        return PersonHubHoverContext(
            displayName: hub.displayName,
            email: hub.email,
            metrics: metrics,
            metricAccounts: PersonHubMetricAccountContexts(
                rows: rows,
                email: email,
                accountsById: accountsById
            ),
            accountEntries: personHubAccountEntries(for: rows),
            isInstitutional: hub.isInstitutional,
            shownNodeCount: shownNodeCount
        )
    }

    @MainActor
    private var hoveredMeaningClusterContext: MeaningClusterHoverContext? {
        guard shouldRenderMeaningClusters(for: state.activeFrame),
              let clusterId = hoveredMeaningClusterId,
              let cluster = clusters.first(where: { $0.id == clusterId }) else {
            return nil
        }
        let labels = meaningClusterPresentationLabels(including: clusterId)
        let label = labels[clusterId]
        let rawTerms: [String] = {
            let terms = label?.topTerms ?? []
            guard terms.isEmpty else { return terms }
            return MeaningClusterLabel.persistedLabelTerms(from: cluster.label)
        }()
        guard !rawTerms.isEmpty else { return nil }
        // Skip the persisted ClusterSummarizer heuristic as a title. The
        // Meaning hover surfaces an Apple-generated semantic title when one
        // exists; TF-IDF terms stay on the evidence line and never repeat as
        // the title. Persisted label pieces are only an evidence fallback for
        // stale presentation snapshots.
        guard let title = MeaningClusterTitleDisambiguator.title(
            for: clusterId,
            labelsByClusterId: labels
        )
            ?? MeaningClusterLabel.fallbackTitle(from: rawTerms)
        else { return nil }
        // Hover tint matches the rendered gas exactly: the cluster's own
        // ramp hue from the packet, or the anchor base for ambient clusters.
        let tint = meaningClusterTint(for: clusterId)
        let hub = renderPacket.meaningClusterHubs.first(where: { $0.clusterId == clusterId })
        // Share of the installed packet's visible messages — the same star
        // set the hub's visible support was counted from. A cluster-filtered
        // scene contains only its scoped clusters, where the share says
        // nothing, so it is omitted there.
        let scopeMessageCount = basePacket.stars.count
        let clusterScopeEngaged = state.filter.clusterIds?.isEmpty == false
        let scopeShare: Double? = clusterScopeEngaged ? nil : hub.flatMap { hub in
            scopeMessageCount > 0
                ? Double(hub.memberCount) / Double(scopeMessageCount)
                : nil
        }
        // Only a generated title carries model confidence; evidence-term
        // fallback titles are deterministic and never read as tentative.
        let isTentativeTitle = label?.displayTitle != nil
            && label?.titleConfidence == .low
        return MeaningClusterHoverContext(
            clusterId: clusterId,
            title: title,
            rawTerms: rawTerms,
            messageCount: hub?.memberCount ?? cluster.memberCount,
            scopeShare: scopeShare,
            receivedDateRange: hub?.receivedDateRange,
            isTentativeTitle: isTentativeTitle,
            tint: tint
        )
    }

    @MainActor
    private func currentPeopleScopeMessageIds(for hub: PersonHubInstance) -> Set<String> {
        PeopleRingMessageScope.focusCaptureMessageIds(
            visibleHubIds: hub.messageIds,
            fullScopeIds: currentPeopleScopeMessageIds(involving: hub.email)
        )
    }

    /// Ring scope for the People-lens lock overlay. In the active People
    /// lens, the current filtered correspondent scope is authoritative so
    /// Moments / Status / Category changes immediately remove stale ring
    /// nodes and add newly matching sent / received messages. Non-People
    /// callers keep the old captured / hub fallback behavior.
    /// Empty when no People-focus lock is active — the overlay then falls
    /// back to the in-context neighbour shape used by the Meanings path.
    @MainActor
    private func peopleRingMessageIds(for personFocus: LockedPersonFocus?) -> Set<String> {
        guard let personFocus else { return [] }
        if state.activeFrame.spatialLens == .people {
            return currentPeopleScopeMessageIds(involving: personFocus.email)
        }
        return PeopleRingMessageScope.focusedSceneMessageIds(
            for: personFocus.email,
            capturedIds: personFocus.messageIds,
            in: renderPacket.personHubs,
            fallbackIds: {
                currentPeopleScopeMessageIds(involving: personFocus.email)
            }
        )
    }

    /// The set of ring-satellite message ids that may be click-/right-click-
    /// selected while a People correspondent lock is active. This is the *same*
    /// set `peopleRingMessageIds(for:)` resolves and hands to the overlay as
    /// `peopleRingMessageIds`, which seeds its ring annotation items — so a node
    /// passing this gate is guaranteed to resolve to a `selectedRingItem` the
    /// overlay can highlight, pin a dial card for, and rank-sync (chip +
    /// Tab origin). Empty outside a People-focus lock. Routing the host's click
    /// gate through this — instead of the broad `currentMessageIndex` scene
    /// index — keeps host selection and overlay rendering definitionally in
    /// agreement: there is no node that selects on the host but the overlay
    /// can't draw, and none the overlay rings but the host refuses to select.
    @MainActor
    private var selectableRingMessageIds: Set<String> {
        peopleRingMessageIds(for: liveLockPersonFocus)
    }

    /// The correspondent's messages in the live People scope. Reads the
    /// scope index while it was built from the live frame, filter, Moments
    /// preset, user addresses, cached snapshot, and arrival gate — hover,
    /// ring, and click-gate lookups then cost a dictionary read. After any
    /// of those changes, and until the rebuild that follows lands, this
    /// rescans the message index instead, so a deletion, arrival, or
    /// classification edit is reflected immediately as before.
    @MainActor
    private func currentPeopleScopeMessageIds(involving email: String) -> Set<String> {
        if let scope = peopleCorrespondentScope,
           scope.describes(livePeopleCorrespondentScopeInputs()) {
            return scope.index.messageIds(involving: email)
        }
        let resolvedFilter = ConstellationFilterResolver.effectiveSceneFilter(
            baseFilter: state.filter,
            selectedTimeRange: state.selectedTimeRange
        )
        let visualFilter = Self.visualSceneFilter(frame: state.activeFrame, filter: resolvedFilter)
        return PeopleRingMessageScope.scopedMessageIds(
            involving: email,
            filter: visualFilter,
            messageIndex: currentMessageIndex,
            userAddresses: userAddressSet
        )
    }

    /// The live inputs a People correspondent scope index must have been
    /// built from to answer for the scene right now.
    @MainActor
    private func livePeopleCorrespondentScopeInputs() -> PeopleCorrespondentScopeInputs {
        PeopleCorrespondentScopeInputs(
            frame: state.activeFrame,
            filter: state.filter,
            selectedTimeRange: state.selectedTimeRange,
            userAddresses: userAddressSet,
            snapshotRevision: snapshotCache.contentRevision,
            gate: NewMailArrivalLedger.shared.visibilityGate()
        )
    }

    /// Brings `peopleCorrespondentScope` up to date for the scene a refresh
    /// pass is planning. The installed index is kept when nothing it
    /// depends on changed; otherwise it is rebuilt on the concurrent
    /// executor from the same gated index `currentMessageIndex` serves.
    /// A newer request cancels an older build, so the newest lands last.
    /// Packet install never waits for it: until it lands, scope reads fall
    /// back to scanning. Passes for other frames drop the index.
    @MainActor
    private func schedulePeopleCorrespondentScope(
        frame: FrameKey,
        filter: VectorFilter,
        selectedTimeRange: TimeRangePreset,
        visualFilter: VectorFilter,
        userAddresses: Set<String>
    ) {
        guard frame.spatialLens == .people else {
            peopleCorrespondentScopeTask?.cancel()
            peopleCorrespondentScopeTask = nil
            peopleCorrespondentScopeBuild = nil
            if peopleCorrespondentScope != nil {
                peopleCorrespondentScope = nil
            }
            return
        }
        let gate = NewMailArrivalLedger.shared.visibilityGate()
        let inputs = PeopleCorrespondentScopeInputs(
            frame: frame,
            filter: filter,
            selectedTimeRange: selectedTimeRange,
            userAddresses: userAddresses,
            snapshotRevision: snapshotCache.contentRevision,
            gate: gate
        )
        // An index for a pass planned against anything other than the live
        // scene (an explicit frame or base filter) could never be served.
        guard inputs == livePeopleCorrespondentScopeInputs() else { return }
        if let scope = peopleCorrespondentScope,
           scope.canServeRefresh(inputs, visualFilter: visualFilter) {
            return
        }
        let build = PeopleCorrespondentScopeBuild(inputs: inputs, visualFilter: visualFilter)
        if peopleCorrespondentScopeBuild == build, peopleCorrespondentScopeTask != nil {
            return
        }
        // Read in the same turn as `inputs`, so the index is built from
        // exactly the snapshot revision and arrival gate it is keyed by —
        // the rows `currentMessageIndex` serves. The gate applies off-main.
        let snapshotIndex = snapshotCache.snapshot(
            for: frame,
            maxAge: .greatestFiniteMagnitude
        )?.messageIndex ?? [:]
        peopleCorrespondentScopeTask?.cancel()
        peopleCorrespondentScopeBuild = build
        peopleCorrespondentScopeTask = Task { @MainActor in
            let index = await Self.concurrentPeopleCorrespondentScopeIndex(
                filter: visualFilter,
                snapshotIndex: snapshotIndex,
                gate: gate,
                userAddresses: userAddresses
            )
            guard !Task.isCancelled, peopleCorrespondentScopeBuild == build else { return }
            peopleCorrespondentScopeTask = nil
            peopleCorrespondentScopeBuild = nil
            if let index {
                peopleCorrespondentScope = PeopleCorrespondentScopeSnapshot(
                    inputs: inputs,
                    visualFilter: visualFilter,
                    index: index
                )
            }
        }
    }

    /// Off-main form of `PeopleRingMessageScope.correspondentScopeIndex`
    /// for scene refreshes, over a cached snapshot's index with the arrival
    /// gate applied first; `nil` when cancelled.
    @concurrent
    nonisolated static func concurrentPeopleCorrespondentScopeIndex(
        filter: VectorFilter,
        snapshotIndex: [String: MessageFilterRow],
        gate: NewMailArrivalVisibilityGate,
        userAddresses: Set<String>
    ) async -> PeopleCorrespondentScopeIndex? {
        let messageIndex = gate.visibleMessageIndex(snapshotIndex)
        guard !Task.isCancelled else { return nil }
        return PeopleRingMessageScope.correspondentScopeIndex(
            filter: filter,
            messageIndex: messageIndex,
            userAddresses: userAddresses,
            checksCancellation: true
        )
    }

    /// Off-main form of `PeopleRingMessageScope.scopedMessageIds` for the
    /// locked correspondent's planner input.
    @concurrent
    nonisolated static func concurrentPeopleScopedMessageIds(
        involving email: String,
        filter: VectorFilter,
        messageIndex: [String: MessageFilterRow],
        userAddresses: Set<String>
    ) async -> Set<String> {
        PeopleRingMessageScope.scopedMessageIds(
            involving: email,
            filter: filter,
            messageIndex: messageIndex,
            userAddresses: userAddresses
        )
    }

    @MainActor
    private func installFocusSourcePreview(
        proxy: HitProxy,
        clickPoint: CGPoint,
        transitionClickPoint: CGPoint,
        sourceColor: SIMD4<Float>
    ) {
        guard let row = currentMessageIndex[proxy.messageId] else { return }
        let popupCenter = state.hoveredVectorId == proxy.vectorId
            ? hoverPosition
            : Self.placeHoverPopupAdjacent(
                nodePoint: clickPoint,
                viewSize: viewSize,
                popupSize: emailHoverEnvelope
            ).center
        let transitionPopupCenter = transitionPoint(fromDetailPoint: popupCenter)
        focusSourcePreview = FocusSourcePreview(
            id: pendingFocusClickSequence + 1,
            messageId: proxy.messageId,
            row: row,
            summaryOverride: summaryByMessageId[proxy.messageId],
            classificationOverride: classificationByMessageId[proxy.messageId],
            clickPoint: clickPoint,
            popupCenter: popupCenter,
            transitionClickPoint: transitionClickPoint,
            transitionPopupCenter: transitionPopupCenter,
            sourceColor: sourceColor
        )
    }

    @MainActor
    @discardableResult
    private func queueSelectedNodeFocus(
        vectorId: Int64,
        fallbackWorld: SIMD3<Float>? = nil,
        initialScreenPoint: CGPoint? = nil,
        initialTransitionPoint: CGPoint? = nil,
        sourceColor: SIMD4<Float>? = nil,
        startZoomImmediately: Bool = false,
        personFocus: LockedPersonFocus? = nil,
        allowsPeopleEmailFocus: Bool = false,
        initialPeopleRingSelectionMessageId: String? = nil,
        commitIsStillValid: (@MainActor () -> Bool)? = nil,
        onCommit: (@MainActor (SelectedNodeFocusCommitResult) -> Void)? = nil
    ) -> Bool {
        pendingFocusClickSequence += 1
        let pendingID = pendingFocusClickSequence
        let markerWorld = fallbackWorld ?? lockedSelectionWorldPosition(vectorId: vectorId)
        let pendingColor = sourceColor
            ?? renderedNodeColor(vectorId: vectorId, messageId: nil)
        let transitionFallbackPoint = initialTransitionPoint
            ?? transitionPointIfPresent(fromDetailPoint: initialScreenPoint)
        pendingFocusClick = PendingFocusClick(
            id: pendingID,
            vectorId: vectorId,
            world: markerWorld,
            fallbackPoint: initialScreenPoint,
            transitionFallbackPoint: transitionFallbackPoint,
            sourceColor: pendingColor,
            personFocus: personFocus,
            startedAt: Date.now
        )
        state.hoveredVectorId = nil

        Task { @MainActor in
            do {
                try await Task.sleep(for: Self.focusClickAcknowledgementDelay)
            } catch {
                onCommit?(.superseded)
                return
            }
            guard pendingFocusClick?.id == pendingID else {
                onCommit?(.superseded)
                return
            }
            guard commitIsStillValid?() ?? true else {
                clearPendingFocusClick(vectorId: vectorId)
                onCommit?(.superseded)
                return
            }
            let didCommit = enterSelectedNodeFocus(
                vectorId: vectorId,
                fallbackWorld: fallbackWorld,
                initialScreenPoint: initialScreenPoint,
                initialTransitionPoint: transitionFallbackPoint,
                sourceColor: pendingColor,
                startZoomImmediately: startZoomImmediately,
                personFocus: personFocus,
                allowsPeopleEmailFocus: allowsPeopleEmailFocus,
                initialPeopleRingSelectionMessageId: initialPeopleRingSelectionMessageId
            )
            onCommit?(didCommit ? .committed : .unavailable)
        }
        return true
    }

    @MainActor
    private func enterSelectedNodeFocus(
        vectorId: Int64,
        fallbackWorld: SIMD3<Float>? = nil,
        initialScreenPoint: CGPoint? = nil,
        initialTransitionPoint: CGPoint? = nil,
        sourceColor: SIMD4<Float>? = nil,
        startZoomImmediately: Bool = false,
        personFocus: LockedPersonFocus? = nil,
        allowsPeopleEmailFocus: Bool = false,
        initialPeopleRingSelectionMessageId: String? = nil
    ) -> Bool {
        guard let record = visibleRecordCache[vectorId] ?? citationSourceRecord(vectorId: vectorId),
              let row = currentMessageIndex[record.messageId],
              let seedWorld = fallbackWorld
                ?? frameAwarePosition(vectorId: vectorId, fallbackRecord: record) else {
            clearPendingFocusClick(vectorId: vectorId)
            return false
        }
        let resolvedPersonFocus = personFocus ?? pendingFocusClick?.personFocus
        let isPeopleCorrespondentLock = state.activeFrame.spatialLens == .people
            && resolvedPersonFocus != nil
        guard state.activeFrame.spatialLens != .people
                || resolvedPersonFocus != nil
                || allowsPeopleEmailFocus else {
            clearPendingFocusClick(vectorId: vectorId)
            return false
        }
        let restoreCamera = selectedNodeFocusRestoreCamera ?? PeopleLiveFocusTransitionPolicy.exitRestoreCamera(
            defaultCamera: isPeopleCorrespondentLock ? peopleLiveFocusExitRecenterCamera() : nil,
            currentCamera: cameraController.state
        )
        // Lock-to-lock chaining keeps the original pre-lock snapshot: with a
        // lock already active, the live packet is lock-flagged (in People, a
        // portrait), and capturing it would make the *next* exit briefly
        // republish that mid-lock scene as the "restored galaxy". Mirrors the
        // `selectedNodeFocusRestoreCamera ??` retention above.
        let lockSourceSnapshot = (state.lockedVectorId != nil || liveLockPersonFocus != nil)
            ? focusedTransitionSourceSnapshot
            : captureFocusedTransitionSourceSnapshot()
        selectedNodeFocusRestoreCamera = restoreCamera
        lockRevealSequence += 1
        lockedNodeSelectionFallbackPoint = initialScreenPoint
        let entryTransitionPoint = initialTransitionPoint
            ?? pendingFocusClick?.transitionFallbackPoint
            ?? transitionPointIfPresent(fromDetailPoint: initialScreenPoint)
        lockedNodeSelectionTransitionPoint = entryTransitionPoint
        selectedNodeFocusWorld = seedWorld
        revealedLockedVectorId = nil
        pendingLiveFocusReveal = nil
        pendingPeopleLiveFocusReveal = nil
        liveFocusExitInFlight = false
        lockEntryEnrichmentToken = nil
        lockSummaryInFlightToken = nil
        warpAnimator.onComplete = nil
        warpAnimator.onProgress = nil
        state.lockedVectorId = vectorId
        meaningAutoMarkReadIfNeeded(record: record, vectorId: vectorId, trigger: .focusedMode)
        // Mirror the locked node's message id + classification into
        // AppStorage so the Edit-menu items can react via @AppStorage.
        // Stored as Strings (UUID's uuidString and a CSV) since
        // @AppStorage's only collection support is via String / Data.
        lockedNodeIDStorage = record.messageId
        lockedNodeClassificationStorage = effectiveClassification(
            messageId: record.messageId,
            fallbackRow: row
        ).flatMap { try? MailClassificationJSON.encode($0) } ?? ""
        lockedNodeCustomKeysStorage = (try? CustomCategoryKeysJSON.encode(
            effectiveCustomCategoryKeys(messageId: record.messageId, fallbackRow: row)
        )) ?? ""
        state.hoveredVectorId = nil
        // People-lens correspondent clicks mirror the person focus into
        // `liveLockPersonFocus` so the live overlay's chrome gates and the
        // render request's `PeopleFrameFocus` narrowing both see it, and the
        // live constellation render keeps drawing the People-graph
        // Saturn-with-rings layout. The visible transition is
        // intentionally simple: the camera flies straight to the correspondent's
        // portrait stand-off while the portrait packet (full galaxy of
        // context hubs, focused rings) installs early at full brightness;
        // the background recede then runs as a shader-uniform ramp, and
        // only the focused render-packet commit reveals the overlay
        // chrome. People does not use the source-warp effect; changing
        // topology under a moving camera was the part that made this
        // transition hard to read.
        suppressedPendingLockIndicatorVectorId = isPeopleCorrespondentLock ? vectorId : nil
        if isPeopleCorrespondentLock {
            clearLiveMetalFocusWarp()
            focusedTransitionSourceSnapshot = lockSourceSnapshot
            clearPendingFocusClick(vectorId: vectorId)
            // Mirror the person focus SYNCHRONOUSLY with `lockedVectorId`.
            // Any refresh that observes the lock without the correspondent
            // focus classifies it as an email-node lock and publishes a
            // packet with the deep 0.18 people field dim + email-anchored
            // context flags — on a correspondent click that packet crushed
            // the whole galaxy for the ~130ms until the real portrait
            // packet landed (the "nodes disappear then reappear" entry
            // flash). Deferring this assignment to the warp's 4%-progress
            // contractScene left exactly that window open to the
            // mark-visited refresh queued by `selectPersonHub`.
            liveLockPersonFocus = resolvedPersonFocus
            // Single-phase entry transition.
            //
            // Compute the portrait approach (a stand-off on the
            // camera→hub axis that frames the correspondent's
            // Saturn + ring bands within the viewport) and warp
            // straight there with a `.lockEntry` profile. The People
            // portrait intentionally uses a slightly closer stand-off
            // than the neutral fit; exit pulls back to the default
            // People recenter camera captured before the scene narrows.
            //
            // Scene narrowing and overlay reveal are separate phases. The
            // portrait packet installs early, but its background hubs start at
            // full brightness. Once that focused packet is actually installed,
            // a short shader-uniform ramp dims the surrounding correspondents
            // without rebuilding the scene every frame.
            let revealSequence = lockRevealSequence
            let hubWorld = resolvedPersonFocus!.worldPosition
            // Safe fallback: if email is empty (helper returned nil),
            // stand off along the front-facing axis at a neutral
            // solar-scale distance instead of warping the camera into
            // the hub centre. (0.49 was the pre-solar neutral stand-off;
            // scaled here like every other portrait radius.)
            let approach = peopleSaturnPortraitApproach(
                anchorHubWorld: hubWorld,
                forEmail: resolvedPersonFocus!.email,
                fallbackRingNormal: resolvedPersonFocus!.ringNormal
            ) ?? (hubWorld + PeoplePortraitCameraPolicy.portraitApproachAxis(
                ringNormal: resolvedPersonFocus!.ringNormal,
                cameraPosition: cameraController.state.position,
                center: hubWorld
            ) * PeopleLiveFocusTransitionPolicy.entryPortraitStandoff(
                systemStandoff: 0.49 * PeopleGraphBuilder.solarScale
            ))
            cancelPeopleContextDimRamp(resetPhase: 0)
            warpAnimator.engage(to: approach, lookAt: hubWorld, profile: .lockEntry)
            let dimRampDuration = PeopleLiveFocusTransitionPolicy.backgroundDimRampDuration(
                totalWarpDuration: warpAnimator.currentEngagementDuration
            )
            var didContractScene = false
            let contractScene: () -> Void = {
                guard lockRevealSequence == revealSequence else { return }
                liveLockPersonFocus = resolvedPersonFocus
                pendingPeopleLiveFocusReveal = PeopleLiveFocusRevealGate(
                    sequence: revealSequence,
                    vectorId: vectorId,
                    email: resolvedPersonFocus!.email,
                    dimRampDuration: dimRampDuration
                )
                // Ordinary correspondent clicks start with no ring selection.
                // A starburst arrival carries its exact message id through
                // this same focus transition so the destination opens with
                // that ring message selected and displayed.
                lockedRingSelectionMessageId = initialPeopleRingSelectionMessageId
                Task { @MainActor in
                    guard lockRevealSequence == revealSequence else { return }
                    await refreshSceneData()
                }
            }
            warpAnimator.onProgress = { progress in
                if progress >= PeopleLiveFocusTransitionPolicy.sceneContractionProgress,
                   !didContractScene {
                    didContractScene = true
                    contractScene()
                }
                return true
            }
            warpAnimator.onComplete = {
                if !didContractScene {
                    didContractScene = true
                    contractScene()
                }
            }
            _ = startZoomImmediately
            return true
        }
        // Every non-correspondent lock — Meaning, Conversations, Timeline,
        // Attention, Projects, and People email-node locks — takes the live
        // in-scene path: the real camera flies to the node, the surrounding
        // field dims in place, and the overlay mounts over the live scene.
        clearPendingFocusClick(vectorId: vectorId)
        enterLiveFocus(
            vectorId: vectorId,
            messageId: record.messageId,
            center: seedWorld,
            revealSequence: lockRevealSequence,
            sourceSnapshot: lockSourceSnapshot
        )
        _ = startZoomImmediately
        return true
    }

    @MainActor
    private func enterLiveFocus(
        vectorId: Int64,
        messageId: String,
        center: SIMD3<Float>,
        revealSequence: Int,
        sourceSnapshot: FocusTransitionSourceSnapshot? = nil
    ) {
        let focusLens = state.activeFrame.spatialLens
        liveLockPersonFocus = nil
        lockNeighbourRank.reset(rankedCount: 0)
        // People email-node locks keep the pre-lock packet snapshot so the
        // exit release can synchronously republish the source galaxy — the
        // same handoff the correspondent portrait uses — instead of leaving
        // a context-dimmed portrait packet on screen until the async
        // unlocked refresh lands. Other lenses reissue their own packet with
        // the dim released (`publishDimReleasedPacketIfNeeded`), so they
        // carry no snapshot.
        focusedTransitionSourceSnapshot = focusLens == .people ? sourceSnapshot : nil
        if focusLens == .people {
            // Entry starts with the context ramp fully open; the ramp to the
            // receded background runs after the focused packet installs.
            cancelPeopleContextDimRamp(resetPhase: 0)
        }

        let targetCamera = liveFocusTargetCamera(
            vectorId: vectorId,
            center: center
        )
        var didPublishFocusedScene = false

        let publishFocusedScene: () -> Void = {
            Task { @MainActor in
                guard state.lockedVectorId == vectorId,
                      lockRevealSequence == revealSequence else { return }
                pendingLiveFocusReveal = LiveFocusRevealGate(
                    sequence: revealSequence,
                    vectorId: vectorId,
                    messageId: messageId
                )
                armLiveMetalFocusWarpForFocusedPacket(
                    frame: state.activeFrame,
                    vectorId: vectorId
                )
                await refreshSceneData()
            }
        }

        guard let targetCamera else {
            clearLiveMetalFocusWarp()
            didPublishFocusedScene = true
            publishFocusedScene()
            return
        }

        warpAnimator.engage(to: targetCamera, profile: .meaningFocus)
        beginLiveMetalFocusWarp(
            frame: state.activeFrame,
            vectorId: vectorId,
            messageId: messageId,
            duration: LiveMetalFocusTransitionPolicy.sourceWarpDuration(
                totalDuration: warpAnimator.currentEngagementDuration,
                endProgress: LiveFocusFramingPolicy.nodeFocusSceneContractionProgress
            ),
            fieldDimTarget: ConstellationLockDimFactor.resolve(
                lockedVectorId: vectorId,
                dimEnabled: state.lockOverlayDimEnabled,
                spatialLens: focusLens
            )
        )
        // Install the lock-flagged packet immediately, while the camera is
        // still flying. The locked budget keeps scene parity, so this
        // refresh changes only per-node signals: the clicked node gains
        // `selected` + full `lockFocus`, its neighbourhood gains graded
        // `lockFocus`, and the animated field dim (driven by the source
        // warp above, which overrides the packet's static dim while
        // active) therefore spares the neighbourhood from the very first
        // dim frame instead of dimming the whole field uniformly and
        // snapping the neighbourhood back at arrival. Overlay reveal still
        // gates on the post-arrival publish below.
        Task { @MainActor in
            guard state.lockedVectorId == vectorId,
                  lockRevealSequence == revealSequence else { return }
            await refreshSceneData()
        }
        warpAnimator.onComplete = {
            if !didPublishFocusedScene {
                didPublishFocusedScene = true
                publishFocusedScene()
            }
        }
    }

    @MainActor
    private func leaveSelectedNodeFocus() {
        if liveFocusExitInFlight || peopleLiveFocusExitInFlight {
            return
        }
        if state.activeFrame.spatialLens == .people,
           liveLockPersonFocus != nil,
           !peopleLiveFocusControlsVisible {
            return
        }
        let releaseTime = Date.now
        if beginPeopleLiveFocusExitTransition(releaseTime: releaseTime) {
            return
        }
        if beginLiveFocusExitTransition(releaseTime: releaseTime) {
            return
        }
        finishLiveMetalLockRelease(
            releaseTime: releaseTime,
            restoreCamera: true,
            shouldRefreshExplorer: true
        )
    }

    @MainActor
    private func beginPeopleLiveFocusExitTransition(releaseTime: Date) -> Bool {
        guard state.activeFrame.spatialLens == .people,
              liveLockPersonFocus != nil,
              let lockedVectorId = state.lockedVectorId else {
            return false
        }

        let releaseSequence = lockRevealSequence
        peopleLiveFocusExitInFlight = true
        revealedLockedVectorId = nil
        pendingPeopleLiveFocusReveal = nil
        lockedRingSelectionMessageId = nil
        lockRingLegendPresented = false

        peopleContextDimRampSequence &+= 1
        let dimRampSequence = peopleContextDimRampSequence
        peopleContextDimRampActive = true
        // Reverse from wherever the entry recede actually got to — an exit
        // that lands mid-entry-ramp must not snap to fully receded first.
        let dimStartPhase = metalRenderer.currentPeopleContextDimPhase()
        // Context ring BANDS never mirror the dim reversal (bands exist
        // only in portrait packets, so fading them back in would bloom
        // rings on every background hub only to snap them away at the
        // settled-packet swap). From a settled lock this start visibility
        // is 0 — bands stay hidden the whole exit; a release mid-entry
        // ramp fades partially-visible bands smoothly down instead of
        // snapping them off in one frame.
        let ringStartVisibility = PeopleLiveFocusTransitionPolicy.backgroundContextRingVisibility(
            dimPhase: dimStartPhase
        )

        guard engageSelectedNodeFocusRestoreCamera() else {
            finishLiveMetalLockRelease(
                releaseTime: releaseTime,
                restoreCamera: false,
                shouldRefreshExplorer: true
            )
            return true
        }

        warpAnimator.onProgress = { progress in
            guard peopleLiveFocusExitInFlight,
                  peopleContextDimRampSequence == dimRampSequence,
                  state.activeFrame.spatialLens == .people,
                  state.lockedVectorId == lockedVectorId,
                  lockRevealSequence == releaseSequence else {
                return false
            }
            metalRenderer.setPeopleContextDimPhase(
                PeopleLiveFocusTransitionPolicy.backgroundContextDimExitPhase(
                    progress: progress,
                    startPhase: dimStartPhase
                ),
                ringVisibility: PeopleLiveFocusTransitionPolicy.backgroundContextDimExitPhase(
                    progress: progress,
                    startPhase: ringStartVisibility
                )
            )
            return true
        }
        warpAnimator.onComplete = {
            guard peopleLiveFocusExitInFlight,
                  peopleContextDimRampSequence == dimRampSequence,
                  state.activeFrame.spatialLens == .people,
                  state.lockedVectorId == lockedVectorId,
                  lockRevealSequence == releaseSequence else {
                return
            }
            metalRenderer.setPeopleContextDimPhase(0, ringVisibility: 0)
            finishLiveMetalLockRelease(
                releaseTime: Date.now,
                restoreCamera: false,
                shouldRefreshExplorer: true
            )
        }
        return true
    }

    @MainActor
    private func beginLiveFocusExitTransition(releaseTime: Date) -> Bool {
        guard LiveFocusExitPolicy.shouldBeginExit(
                activeFrame: state.activeFrame,
                lockedVectorId: state.lockedVectorId,
                hasLivePersonFocus: liveLockPersonFocus != nil,
                exitInFlight: liveFocusExitInFlight
              ),
              let lockedVectorId = state.lockedVectorId else {
            return false
        }

        let exitLens = state.activeFrame.spatialLens
        let releaseSequence = lockRevealSequence
        liveFocusExitInFlight = true
        revealedLockedVectorId = nil
        pendingLiveFocusReveal = nil

        // People email-node locks reverse the context ramp during the
        // pullback so background hub bodies and ring satellites brighten
        // back as the camera retreats. Context ring BANDS deliberately do
        // NOT mirror the reversal: bands exist only in portrait packets,
        // so a mid-exit band bloom would only snap away at the
        // settled-packet swap. Bands ramp from wherever the entry recede
        // left them (0 from a settled lock) straight down to 0.
        let reversesPeopleContextDim = exitLens == .people
        var peopleDimSequence = peopleContextDimRampSequence
        var peopleDimStartPhase: Float = 1
        var peopleRingStartVisibility: Float = 0
        if reversesPeopleContextDim {
            peopleContextDimRampSequence &+= 1
            peopleDimSequence = peopleContextDimRampSequence
            peopleContextDimRampActive = true
            // Reverse from the phase the entry recede actually reached — a
            // release mid-entry-ramp must not snap to fully receded first.
            peopleDimStartPhase = metalRenderer.currentPeopleContextDimPhase()
            peopleRingStartVisibility = PeopleLiveFocusTransitionPolicy.backgroundContextRingVisibility(
                dimPhase: peopleDimStartPhase
            )
        }

        guard engageSelectedNodeFocusRestoreCamera() else {
            finishLiveMetalLockRelease(
                releaseTime: releaseTime,
                restoreCamera: false,
                shouldRefreshExplorer: true
            )
            return true
        }

        beginLiveMetalFocusWarp(
            frame: state.activeFrame,
            vectorId: lockedVectorId,
            messageId: (visibleRecordCache[lockedVectorId] ?? citationSourceRecord(vectorId: lockedVectorId))?.messageId ?? "",
            duration: warpAnimator.currentEngagementDuration,
            directionSign: -1,
            fieldDimTarget: ConstellationLockDimFactor.resolve(
                lockedVectorId: lockedVectorId,
                dimEnabled: state.lockOverlayDimEnabled,
                spatialLens: exitLens
            )
        )

        warpAnimator.onProgress = { progress in
            guard liveFocusExitInFlight,
                  state.activeFrame.spatialLens == exitLens,
                  state.lockedVectorId == lockedVectorId,
                  lockRevealSequence == releaseSequence else {
                return false
            }
            if reversesPeopleContextDim,
               peopleContextDimRampSequence == peopleDimSequence {
                metalRenderer.setPeopleContextDimPhase(
                    PeopleLiveFocusTransitionPolicy.backgroundContextDimExitPhase(
                        progress: progress,
                        startPhase: peopleDimStartPhase
                    ),
                    ringVisibility: PeopleLiveFocusTransitionPolicy.backgroundContextDimExitPhase(
                        progress: progress,
                        startPhase: peopleRingStartVisibility
                    )
                )
            }
            return progress < 1
        }
        warpAnimator.onComplete = {
            guard liveFocusExitInFlight,
                  state.activeFrame.spatialLens == exitLens,
                  state.lockedVectorId == lockedVectorId,
                  lockRevealSequence == releaseSequence else {
                return
            }
            if reversesPeopleContextDim,
               peopleContextDimRampSequence == peopleDimSequence {
                metalRenderer.setPeopleContextDimPhase(0, ringVisibility: 0)
            }
            finishLiveMetalLockRelease(
                releaseTime: Date.now,
                restoreCamera: false,
                shouldRefreshExplorer: true
            )
        }
        return true
    }

    @MainActor
    private func finishLiveMetalLockRelease(
        releaseTime: Date,
        restoreCamera: Bool,
        shouldRefreshExplorer: Bool,
        isDeletionReturn: Bool = false
    ) {
        // Correspondent portraits AND People email-node locks both hand the
        // pre-lock source galaxy back synchronously; other lenses reissue
        // their own packet with the dim released.
        var publishedPeopleHandoff = false
        if state.activeFrame.spatialLens == .people {
            publishedPeopleHandoff = publishPeoplePostFocusExitPacketIfNeeded(
                activeFrame: state.activeFrame,
                now: releaseTime,
                isDeletionReturn: isDeletionReturn
            )
        }
        publishDimReleasedPacketIfNeeded(now: releaseTime)
        if publishedPeopleHandoff {
            // Scheduled AFTER the dim-release reissue: that reissue restamps
            // `basePacket.generatedAt`, and a rebuild scheduled against the
            // pre-reissue stamp would fail its own guard and leave the cache
            // on portrait rows until the async refresh lands.
            scheduleVisibleRecordCacheRebuild(for: basePacket)
        }
        lockRevealSequence += 1
        revealedLockedVectorId = nil
        pendingLiveFocusReveal = nil
        pendingPeopleLiveFocusReveal = nil
        lockEntryEnrichmentToken = nil
        lockSummaryInFlightToken = nil
        relatedSummaryPrewarmTask?.cancel()
        relatedSummaryPrewarmTask = nil
        suppressedPendingLockIndicatorVectorId = nil
        lockedNodeSelectionFallbackPoint = nil
        lockedNodeSelectionTransitionPoint = nil
        pendingFocusClick = nil
        focusSourcePreview = nil
        selectedNodeFocusWorld = nil
        focusedTransitionSourceSnapshot = nil
        liveFocusExitInFlight = false
        peopleLiveFocusExitInFlight = false
        pendingLockedDeletionReturn = nil
        // Reset the dim to 0 (background bodies + satellites fully
        // visible): the packet on screen after release is either the
        // handed-off source galaxy (no context flags — phase inert) or,
        // when the handoff was skipped (e.g. a rolling time-preset filter
        // drifted mid-lock and failed the handoff equality), the stale
        // portrait packet — whose hub bodies and context ring SATELLITES
        // must stay visible until the async refresh lands, because the
        // unlocked galaxy renders them too. Ring BANDS stay pinned hidden:
        // they exist only in portrait packets, so reopening that channel
        // against a stale portrait flashed rings on every background hub
        // for the second before the refresh landed.
        cancelPeopleContextDimRamp(resetPhase: 0, ringVisibility: 0)
        clearLiveMetalFocusWarp()
        warpAnimator.onComplete = nil
        warpAnimator.onProgress = nil
        clearTransientHoverState()
        state.lockedVectorId = nil
        liveLockPersonFocus = nil
        lockedRingSelectionMessageId = nil
        lockRingLegendPresented = false
        // Edit-menu items gate on these AppStorage keys; clearing them
        // disables the locked-node menu items the moment the user
        // releases the lock.
        lockedNodeIDStorage = ""
        lockedNodeClassificationStorage = ""
        lockedNodeCustomKeysStorage = ""
        // Drop affinity-rank step state so the next lock starts clean and
        // the controller's `rankedCount` is zero until the new context loads.
        lockNeighbourRank.reset(rankedCount: 0)
        if restoreCamera {
            restoreSelectedNodeFocusCamera()
        }
        if shouldRefreshExplorer {
            Task { await refreshSceneData(updateColorLookup: true) }
        }
    }

    /// Returns `true` when the source-galaxy handoff packet was published,
    /// so the caller can rebuild the visible-record cache once the release's
    /// packet churn (including the dim-release reissue) has settled.
    @MainActor
    @discardableResult
    private func publishPeoplePostFocusExitPacketIfNeeded(
        activeFrame: FrameKey,
        now: Date,
        isDeletionReturn: Bool = false
    ) -> Bool {
        guard let sourceSnapshot = focusedTransitionSourceSnapshot,
              PeopleFocusExitHandoffPolicy.shouldPublishSourcePacket(
                activeFrame: activeFrame,
                sourceFrame: sourceSnapshot.renderedFrame,
                sourceFilter: sourceSnapshot.renderedFilter,
                currentFilter: state.filter,
                isDeletionReturn: isDeletionReturn
              ) else {
            return false
        }

        let sourcePacket = sourceSnapshot.packet
        let handoffPacket = sourcePacket.reissued(
            generatedAt: max(
                sourcePacket.generatedAt + Self.peopleFocusExitHandoffGeneratedAtOffset,
                now.timeIntervalSince1970
            )
        )
        pruneCompletedDyingPersonSnapshots(for: handoffPacket, now: now)
        basePacket = handoffPacket
        renderPacketFrame = activeFrame.spatialLens
        renderPacketFilter = sourceSnapshot.renderedFilter
        renderPacket = Self.combinePacket(
            base: handoffPacket,
            dying: dyingSnapshots,
            dyingPeople: dyingPersonSnapshots,
            birthing: birthingSnapshots,
            now: now
        )
        return true
    }

    /// Live-lock exit handoff, any lens. The exit's reverse source warp
    /// animates the effective field dim back to 1.0 during the camera
    /// pullback, but the installed packet still carries the locked
    /// `fieldDimFactor`. When the warp effect is cleared at release, the
    /// renderer would fall back to that stale packet dim for the frames
    /// between release and the async unlocked refresh — a visible darkness
    /// snap at the exact moment the exit should feel settled. Reissue the
    /// current packet with the dim released so those frames hold full
    /// brightness; the refresh then replaces it with the true unlocked
    /// packet (identical field, lock flags cleared) with no visible delta.
    @MainActor
    private func publishDimReleasedPacketIfNeeded(now: Date) {
        // `meaningClusterVisibility < 1` matters independently of the dim:
        // with lock-overlay dim disabled in settings the locked packet's
        // `fieldDimFactor` is already 1.0, but its cluster visibility is
        // still 0 and must release here or the orbs stay invisible until
        // the async unlocked refresh, then pop.
        guard renderPacketFrame.spatialLens == state.activeFrame.spatialLens,
              basePacket.fieldDimFactor < 1 || basePacket.meaningClusterVisibility < 1 else {
            return
        }
        // Cluster visibility releases with the dim: the exit's reverse
        // source warp has just ramped the orbs back to fully visible, so
        // the handoff packet's static value must land on 1.0 — leaving the
        // locked packet's 0 in place would snap them invisible for the
        // frames between release and the async unlocked refresh.
        let handoffPacket = basePacket.reissued(
            generatedAt: max(
                basePacket.generatedAt + Self.peopleFocusExitHandoffGeneratedAtOffset,
                now.timeIntervalSince1970
            ),
            fieldDimFactor: 1.0,
            meaningClusterVisibility: 1.0
        )
        basePacket = handoffPacket
        renderPacket = Self.combinePacket(
            base: handoffPacket,
            dying: dyingSnapshots,
            dyingPeople: dyingPersonSnapshots,
            birthing: birthingSnapshots,
            now: now
        )
    }

    @MainActor
    private func clearTransientHoverState() {
        clearEmailHoverPaneState()
        projectedHoverTarget = nil
    }

    /// Rebuilds `visibleRecordCache` for a synchronously published handoff
    /// packet without stalling its publish: the exit handoff must swap the
    /// packet in the same main-actor turn (that is the whole point of the
    /// handoff), but the record cache backing hover/lock lookups can lag a
    /// few milliseconds — every consumer falls back to
    /// `citationSourceRecord`'s single-row hydrate on a miss. Guarded by
    /// `generatedAt` so a refresh that lands in between (and rebuilt the
    /// cache itself) is never clobbered with stale rows.
    @MainActor
    private func scheduleVisibleRecordCacheRebuild(for packet: ConstellationRenderPacket) {
        let visibleIds = Array(Set(packet.hitProxies.map(\.vectorId).filter { $0 > 0 }))
        let generatedAt = packet.generatedAt
        let vectorStore = services.vectorStore
        Task { @MainActor in
            let records = await Task.detached(priority: .userInitiated) {
                (try? vectorStore.hydrateDisplayMetadata(vectorIds: visibleIds)) ?? []
            }.value
            guard basePacket.generatedAt == generatedAt else { return }
            visibleRecordCache = Dictionary(
                uniqueKeysWithValues: records.map { ($0.vectorId, $0) }
            )
        }
    }

    @MainActor
    private func restoreSelectedNodeFocusCamera() {
        _ = engageSelectedNodeFocusRestoreCamera()
    }

    @MainActor
    @discardableResult
    private func engageSelectedNodeFocusRestoreCamera() -> Bool {
        guard let restore = selectedNodeFocusRestoreCamera else { return false }
        selectedNodeFocusRestoreCamera = nil
        let profile: WarpAnimator.Profile = state.activeFrame.spatialLens == .meaning
            ? .meaningFocus
            : .lockEntry
        warpAnimator.engage(to: restore, profile: profile)
        return true
    }

    @MainActor
    private func clearPendingFocusClick(vectorId: Int64? = nil) {
        guard let vectorId else {
            pendingFocusClick = nil
            focusSourcePreview = nil
            return
        }
        if pendingFocusClick?.vectorId == vectorId {
            pendingFocusClick = nil
            focusSourcePreview = nil
        }
    }

    @MainActor
    private func liveFocusTargetCamera(
        vectorId: Int64,
        center: SIMD3<Float>
    ) -> CameraState? {
        guard state.lockedVectorId == vectorId else { return nil }
        // People solar system: density-derived framing would key the
        // camera depth to distance from the sun — use the fixed
        // front-facing solar framing instead.
        if state.activeFrame.spatialLens == .people,
           let sun = renderPacket.personSun {
            return LiveFocusFramingPolicy.peopleSolarTargetCamera(
                center: center,
                current: cameraController.state,
                eclipticNormal: sun.eclipticNormal
            )
        }
        let starCandidates = renderPacket.stars
            .filter { $0.representativeVectorId != vectorId }
            .map(\.position)
        let satelliteCandidates = renderPacket.satellites
            .filter { $0.vectorId != vectorId }
            .map(\.position)
        let contextPositions = LiveFocusFramingPolicy.contextPositions(
            center: center,
            candidates: starCandidates + satelliteCandidates
        )
        let focusRadius = LiveFocusFramingPolicy.focusRadius(
            center: center,
            contextPositions: contextPositions
        )
        return LiveFocusFramingPolicy.targetCamera(
            center: center,
            current: cameraController.state,
            focusRadius: focusRadius
        )
    }

    @MainActor
    @discardableResult
    private func zoomToSelectedNodeFocus(centerVectorId: Int64, fallbackWorld: SIMD3<Float>? = nil) -> Bool {
        guard state.lockedVectorId == centerVectorId else { return false }
        guard let center = selectedNodeFocusWorld
            ?? fallbackWorld
            ?? lockedSelectionWorldPosition(vectorId: centerVectorId)
            ?? frameAwarePosition(vectorId: centerVectorId) else {
            return false
        }
        selectedNodeFocusWorld = center
        let focusPositions = renderPacket.stars
            .filter { $0.signal.lockFocus > 0 }
            .map(\.position)
            + renderPacket.satellites
            .filter { $0.signal.lockFocus > 0 }
            .map(\.position)
        let positions = focusPositions.isEmpty ? [center] : focusPositions
        guard let targetCamera = ConstellationCameraFraming.cameraState(
            fitting: positions,
            requiredPositions: [center],
            viewSize: viewSize,
            fill: Self.lockFocusCameraFill,
            minDistance: Self.lockFocusCameraMinDistance,
            padding: Self.lockFocusCameraPadding,
            outlierTrimFraction: Self.lockFocusCameraOutlierTrimFraction
        ) else { return false }
        warpAnimator.engage(to: targetCamera, profile: .lockEntry)
        return true
    }

    @MainActor
    private func revealLockedOverlay(vectorId: Int64, sequence: Int) {
        guard state.lockedVectorId == vectorId, lockRevealSequence == sequence else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            revealedLockedVectorId = vectorId
        }
    }

    @MainActor
    private func markLockEntryEnrichmentReadyAfterSettle(vectorId: Int64, sequence: Int) async {
        // Enrichment (context load, summarization, orientation generation)
        // stays out of the camera flight entirely — the fly-in must not
        // compete with SwiftData fetches or generative-worker dispatch for
        // main-actor time. People correspondent locks reveal mid-flight,
        // so this wait is what defers their enrichment to arrival; Meaning
        // and email-node locks publish near warp completion, so for them
        // it covers only the tail of the flight.
        while warpAnimator.isWarping {
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return
            }
            guard state.lockedVectorId == vectorId,
                  lockRevealSequence == sequence else {
                return
            }
        }
        do {
            try await Task.sleep(for: Self.lockEnrichmentSettleDuration)
        } catch {
            return
        }
        markLockEntryEnrichmentReady(vectorId: vectorId, sequence: sequence)
    }

    @MainActor
    private func markLockEntryEnrichmentReady(vectorId: Int64, sequence: Int) {
        guard state.lockedVectorId == vectorId,
              lockRevealSequence == sequence,
              revealedLockedVectorId == vectorId else {
            return
        }
        lockEntryEnrichmentToken = LockEntryEnrichmentToken(vectorId: vectorId, sequence: sequence)
    }

    @MainActor
    private func warpTo(_ target: SIMD3<Float>) {
        let camPos = cameraController.state.position
        let delta = target - camPos
        let distance = simd_length(delta)
        let approach = distance > 0.001
            ? target - simd_normalize(delta) * 0.12
            : target + SIMD3<Float>(0, 0, 0.12)
        warpAnimator.engage(to: approach, lookAt: target)
    }

    /// Variant of `warpTo` that adjusts the camera distance so a context
    /// anchor (typically the locked email's star) is also kept inside the
    /// viewport. Tab-stepping through the locked-node overlay uses this so
    /// stepping to a far-away neighbour zooms out enough that the locked
    /// star, the focused neighbour, and the annotation pane all fit on
    /// screen — instead of always landing 0.12 units from the target
    /// regardless of how far it is from the lock context. Falls back to
    /// fixed-distance behavior when no context point is supplied or when
    /// the context lies along the camera axis (no perpendicular framing
    /// constraint to satisfy).
    @MainActor
    private func warpToWithContext(target: SIMD3<Float>, contextPoint: SIMD3<Float>?) {
        let camPos = cameraController.state.position
        let approach = adaptiveLockedOverlayApproach(
            target: target,
            contextPoint: contextPoint,
            oldCamera: camPos
        )
        warpAnimator.engage(to: approach, lookAt: target)
    }

    /// Compute a camera approach point on the line `oldCamera → target`
    /// such that `target` is centered and `contextPoint` (when supplied)
    /// remains inside a cone of half-angle small enough to leave room
    /// alongside it for the annotation pane / lock card. The cone math
    /// solves: given camera at distance `d` from `target`, what's the
    /// minimum `d` so the angle between the camera axis and `contextPoint`
    /// is at most `effectiveAlpha`?
    private func adaptiveLockedOverlayApproach(
        target: SIMD3<Float>,
        contextPoint: SIMD3<Float>?,
        oldCamera: SIMD3<Float>
    ) -> SIMD3<Float> {
        let delta = target - oldCamera
        let distance = simd_length(delta)
        let direction: SIMD3<Float>
        if distance > 0.001 {
            direction = simd_normalize(delta)
        } else {
            // Camera already at target; keep the same forward axis the
            // current camera state implies.
            direction = SIMD3<Float>(0, 0, -1)
        }

        // Same close-in distance the existing `warpTo` uses. We never
        // pull the camera *closer* than this — only pull it back to fit
        // additional context.
        let defaultDistance: Float = 0.12
        // Upper bound on how far back we'll pull the camera. The glide
        // warp scales its duration by world distance, so an unbounded
        // pull-back would make tab-stepping feel sluggish. Six units is
        // enough headroom that a typical neighbour spread stays in view
        // without the warp animation running past the existing 3s cap.
        let maxDistance: Float = 6

        guard let context = contextPoint else {
            return target - direction * defaultDistance
        }

        let toContext = context - target
        let along = simd_dot(direction, toContext)
        let perpSquared = max(0, simd_length_squared(toContext) - along * along)
        let perp = sqrt(perpSquared)

        // Co-linear case (camera, target, context all on one line): no
        // perpendicular distance to fit, so the default close-in is fine.
        if perp < 0.005 {
            return target - direction * defaultDistance
        }

        // Vertical FOV is `.pi / 3` (60°) → half-angle 30°. Reserve
        // roughly half of that for the annotation pane / lock card
        // chrome, leaving an effective viewport half-angle of ~15°.
        // `cot(15°) ≈ 3.7321`. The required camera distance from the
        // target so a perpendicular displacement `perp` lies within the
        // effective cone is `perp * cot(alpha) - along`.
        let cotEffectiveHalfFOV: Float = 3.7321
        let coneFitDistance = perp * cotEffectiveHalfFOV - along
        let d = min(max(defaultDistance, coneFitDistance), maxDistance)
        return target - direction * d
    }

    nonisolated static func lockedNodeRecenterFocusRadius(
        center: SIMD3<Float>,
        contextPositions: [SIMD3<Float>]
    ) -> Float {
        let distances = contextPositions
            .map { simd_distance($0, center) }
            .filter { $0 > 0.0001 }
            .sorted()
        guard distances.isEmpty == false else {
            return 0
        }
        let sampleIndex = min(
            distances.count - 1,
            max(0, Int((Double(distances.count - 1) * 0.60).rounded()))
        )
        return distances[sampleIndex]
    }

    @MainActor
    private func frameAwarePosition(vectorId: Int64, fallbackRecord: VectorRecord? = nil) -> SIMD3<Float>? {
        if state.activeFrame != .defaultFrame,
           let positions = try? services.vectorFrameLayoutStore.positionsForFrame(
            state.activeFrame,
            vectorIds: [vectorId]
           ),
           let position = positions[vectorId] {
            return position
        }

        let record = fallbackRecord
            ?? (try? services.vectorStore.hydrateDisplayMetadata(vectorIds: [vectorId]))?.first
        guard let x = record?.layoutX, let y = record?.layoutY, let z = record?.layoutZ else { return nil }
        return SIMD3<Float>(x, y, z)
    }

    @MainActor
    private func activeFilterSpec() async -> FilterSpec {
        if let focused = await focusedRetrievalFilterSpec() {
            return focused
        }
        var filter = ConstellationFilterResolver.effectiveSceneFilter(
            baseFilter: state.filter,
            selectedTimeRange: state.selectedTimeRange
        )
        // Timeline lens narrows the Ask scope to the visible viewport
        // (intersected with any active bracket). Sidebar Ask must agree
        // with what's drawn on the multitrack canvas.
        if state.activeFrame.spatialLens == .timeline, let workspace = timelineWorkspace {
            filter = TimelineFilterIntersection.intersect(
                filter: filter,
                viewportRange: workspace.viewportRange,
                bracketedRange: workspace.bracketedRange
            )
            let allowedMessageIds = timelineAllowedMessageIdsForAsk(
                workspace: workspace,
                filter: filter
            )
            return filterSpec(from: filter, allowedMessageIds: allowedMessageIds)
        }
        if state.activeFrame.spatialLens == .projects, let workspace = projectsWorkspace {
            let allowedMessageIds = projectsAllowedMessageIdsForRetrieval(
                workspace: workspace,
                filter: state.filter
            )
            return filterSpec(from: filter, allowedMessageIds: allowedMessageIds)
        }
        if state.activeFrame.spatialLens == .frontPage {
            // Front Page is a non-Metal reading surface with no constellation
            // snapshot. Ground Ask in the active filter scope (accounts, date
            // range, collections via the FilterSpec) with no row whitelist —
            // the active filter scope, not the rendered subset.
            return filterSpec(from: filter, allowedMessageIds: nil)
        }
        let snapshot = await constellationSnapshot(for: state.activeFrame)
        let filterMatchedMessageIds = await allowedMessageIdsForRetrieval(
            filter: filter,
            snapshot: snapshot
        )
        let allowedMessageIds: [String]?
        if filter.collections.isEmpty {
            allowedMessageIds = []
        } else {
            let visibleMessageIds = visibleRecordCache.values.map(\.messageId)
            allowedMessageIds = Self.visibleScopeGate(
                visibleMessageIds: visibleMessageIds,
                filterMatchedMessageIds: filterMatchedMessageIds
            )
        }
        return filterSpec(from: filter, allowedMessageIds: allowedMessageIds)
    }

    @MainActor
    private func askThreadExpansion(for sources: [RetrievalResult]) async -> AskThreadExpansion {
        let capturedScopeKind = focusedRetrievalScopeKind
        let capturedThreadCenterMessageID = capturedScopeKind == .thread
            ? focusedThreadCenterMessageID
            : nil
        let capturedProjectRow = capturedScopeKind == .project
            ? projectsWorkspace?.focusedRow
            : nil
        let expansion = await ConstellationAskThreadContextProvider(
            modelContext: modelContext,
            vectorStore: services.vectorStore
        ).expansion(for: sources)
        guard let scopeKind = capturedScopeKind else {
            return expansion
        }

        let allowedMessageIDs: Set<String>
        switch scopeKind {
        case .thread:
            guard let centerMessageID = capturedThreadCenterMessageID else {
                return .empty
            }
            allowedMessageIDs = await focusedThreadMessageIDs(centerMessageID: centerMessageID)
        case .correspondent, .project:
            // Retrieval has already applied the complete focused correspondent
            // or project whitelist. Preserve only those anchor messages here;
            // generic thread expansion must not append sibling mail outside it.
            allowedMessageIDs = Set(sources.map(\.record.messageId))
        }
        let constrained = FocusedRetrievalScopePolicy.constrain(
            expansion: expansion,
            to: allowedMessageIDs
        )
        guard scopeKind == .project,
              let row = capturedProjectRow,
              let fileContext = await ProjectManualFileAskContextBuilder.context(
                projectKey: row.projectKey,
                projectName: row.displayLabel
              ),
              Task.isCancelled == false else {
            return constrained
        }
        return AskThreadExpansion(
            additionalSources: constrained.additionalSources,
            contexts: constrained.contexts + [fileContext],
            visualEvidence: constrained.visualEvidence
        )
    }

    @MainActor
    private func timelineAllowedMessageIdsForAsk(
        workspace: TimelineWorkspaceState,
        filter: VectorFilter
    ) -> [String] {
        guard filter.collections.isEmpty == false else { return [] }
        guard let snapshot = workspace.currentSnapshot else { return [] }
        guard Self.timelineSnapshotMatchesCurrentRequest(
            snapshot: snapshot,
            expectedSignature: timelineData.latestSignature,
            viewportRange: workspace.viewportRange
        ) else { return [] }
        return snapshot.sortedEligibleEntries
            .map { $0.id.uuidString }
            .sorted()
    }

    @MainActor
    private func projectsAllowedMessageIdsForRetrieval(
        workspace: ProjectsWorkspaceState,
        filter: VectorFilter
    ) -> [String] {
        guard filter.collections.isEmpty == false else { return [] }
        guard let snapshot = workspace.currentSnapshot else { return [] }
        guard ProjectsDataController.signatureMatchesCurrentFilter(
            snapshot: snapshot,
            filter: filter
        ) else {
            return []
        }
        return workspace.retrievalAllowedMessageIDs
    }

    @MainActor
    private func filterSpec(
        from filter: VectorFilter,
        allowedMessageIds: [String]?
    ) -> FilterSpec {
        FilterSpec(
            accountIds: filter.accountIds?
                .sorted { $0.uuidString < $1.uuidString } ?? [],
            dateRange: filter.timeRange,
            hasAttachment: filter.hasAttachmentsOnly ? true : nil,
            keywords: nil,
            collections: filter.collections
                .sorted { $0.rawValue < $1.rawValue },
            allowedMessageIds: allowedMessageIds
        )
    }

    private static func visibleScopeGate(
        visibleMessageIds: [String],
        filterMatchedMessageIds: [String]?
    ) -> [String]? {
        let visible = Set(visibleMessageIds.filter { !$0.isEmpty })
        guard !visible.isEmpty else { return filterMatchedMessageIds }

        guard let filterMatchedMessageIds else {
            return visible.sorted()
        }

        let matched = Set(filterMatchedMessageIds)
        return visible.intersection(matched).sorted()
    }

    @MainActor
    private func constellationSnapshot(
        for frame: FrameKey,
        maxAge: TimeInterval = 15,
        forceRefresh: Bool = false,
        sourceVersion: TimeInterval? = nil
    ) async -> ConstellationSnapshot {
        let snapshot: ConstellationSnapshot
        do {
            snapshot = try await snapshotCache.load(
                for: frame, maxAge: maxAge, forceRefresh: forceRefresh,
                sourceVersion: sourceVersion
            ) {
                // Capture fresh main-actor inputs only when a shared load
                // actually starts (or restarts after a mutation).
                let accountColorIndex = accountColorIndexByAccountId()
                let userActions = MessageAttentionUserActionState(
                    projectActions: ProjectLensActionRepository(modelContext: modelContext)
                        .actionState(accountScopeKey: "all")
                )
                let startedAt = LensLoadPerformanceLog.start()
                let loaded = try await ConstellationSnapshotLoader.load(
                    frame: frame,
                    messageStoreURL: services.messageStoreURL,
                    vectorStore: services.vectorStore,
                    vectorClusterStore: services.vectorClusterStore,
                    vectorNeighborsStore: services.vectorNeighborsStore,
                    accountColorIndex: accountColorIndex,
                    userActions: userActions,
                    customCategoryCatalogKeys: customCategoryStore.allKeys,
                    arrivalVisibilityGate: NewMailArrivalLedger.shared.visibilityGate()
                )
                LensLoadPerformanceLog.record(
                    lens: frame, stage: "shared-snapshot", startedAt: startedAt,
                    resultCount: loaded.messageIndex.count
                )
                return loaded
            }
        } catch {
            if !(error is CancellationError) {
                ConstellationLog.logger.error("snapshot load failed: \(String(reflecting: type(of: error)), privacy: .public)")
            }
            return snapshotCache.snapshot(for: frame, maxAge: .greatestFiniteMagnitude)
                ?? .empty(frame: frame)
        }
        // The detached load captured the arrival-visibility gate at its
        // start. An arrival announced while the load was in flight was
        // embargoed then, so this snapshot omits it — and storing it would
        // silently overwrite the announce-turn cache patch, hiding the
        // node again until an arbitrarily-later refresh. Re-patch every
        // announced-but-unvisited arrival the load missed.
        let missedAnnouncedArrivalIDs = NewMailArrivalLedger.shared.unvisitedArrivalIds
            .filter { snapshot.messageIndex[$0] == nil }
            .compactMap(UUID.init(uuidString:))
        if missedAnnouncedArrivalIDs.isEmpty == false {
            upsertAnnouncedArrivalsIntoSnapshotCache(messageIDs: missedAnnouncedArrivalIDs)
            if let patched = snapshotCache.snapshot(
                for: frame,
                maxAge: .greatestFiniteMagnitude
            ) {
                return patched
            }
        }
        return snapshot
    }

    @MainActor
    private func initialConstellationCameraState(
        frame: FrameKey,
        filter: VectorFilter,
        snapshot: ConstellationSnapshot,
        viewSize: CGSize
    ) async -> CameraState? {
        let vectorStore = services.vectorStore
        let frameLayoutStore = services.vectorFrameLayoutStore
        let messageIndex = snapshot.messageIndex
        return await Task.detached(priority: .userInitiated) {
            do {
                var rows = try vectorStore.renderRowsWithLayout(filter: filter, limit: 250_000)
                rows = rows.filter { row in
                    guard let messageRow = messageIndex[row.messageId] else { return false }
                    return ConstellationMessageFilter.matches(messageRow, filter: filter)
                }
                if frame != .defaultFrame {
                    let framePositions = try frameLayoutStore.positionsForFrame(
                        frame,
                        vectorIds: rows.map(\.vectorId)
                    )
                    rows = rows.map { row in
                        guard let position = framePositions[row.vectorId] else { return row }
                        return row.withLayout(position)
                    }
                }
                let positions = rows.map(\.layout)
                return ConstellationCameraFraming.cameraState(
                    fitting: positions,
                    frame: frame,
                    viewSize: viewSize
                )
            } catch {
                ConstellationLog.logger.error("initial camera framing failed: \(String(reflecting: type(of: error)), privacy: .public)")
                return nil
            }
        }.value
    }

    @MainActor
    private func allowedMessageIdsForRetrieval(
        filter: VectorFilter,
        snapshot: ConstellationSnapshot
    ) async -> [String]? {
        guard Self.needsMessageScopeGate(filter) else { return nil }
        let messageIndex = NewMailArrivalLedger.shared
            .filteredMessageIndex(snapshot.messageIndex)
        return await Task.detached(priority: .userInitiated) {
            messageIndex.compactMap { messageId, row in
                ConstellationMessageFilter.matches(row, filter: filter) ? messageId : nil
            }
            .sorted()
        }.value
    }

    nonisolated static func needsMessageScopeGate(_ filter: VectorFilter) -> Bool {
        if filter.accountIds?.isEmpty == true { return true }
        if filter.messageTypes != nil { return true }
        if filter.readStates != nil { return true }
        if filter.repliedStates != nil { return true }
        if filter.sentStates != nil { return true }
        if filter.flaggedOnly { return true }
        if filter.hasAttachmentsOnly { return true }
        // Headline / Topics filters live on Swift-side row metadata
        // (`isActionable` / `requiresConfirmation` / canonical classification),
        // not on the SQL hot path's `collections` / `timeRange` clauses,
        // so retrieval (semantic search, Ask) needs the message-scope gate
        // when any of these chips are active. Otherwise a Headline-only or
        // Topics-only filter narrows the rendered scene but lets retrieval
        // still pull from messages outside the visible set.
        if filter.replyNeededCriterion.isActive { return true }
        if filter.confirmationNeededCriterion.isActive { return true }
        if filter.resolvedCriterion?.isActive == true { return true }
        if filter.purposes != nil { return true }
        if filter.mailingListCategoryIncluded != nil { return true }
        // Any explicit custom-category selection narrows the scene the same
        // way a fixed-topic selection does. `nil` is the rest state (every
        // custom category included) and never gates.
        if filter.customCategoryKeys != nil { return true }
        if !filter.correspondentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if filter.clusterIds != nil { return true }
        if filter.listIds != nil { return true }
        if filter.taskState != .any { return true }
        if filter.deadlineState != .any { return true }
        return false
    }

    @MainActor
    private func citationSourceRecord(vectorId: Int64) -> VectorRecord? {
        if let visible = visibleRecordCache[vectorId] ?? searchResultRecordCache[vectorId] {
            return visible
        }
        // Cache-miss fallback runs synchronously on the main actor (hover,
        // lock entry, menu targets all need the answer this turn), so it
        // must stay on the display-metadata query — every consumer reads
        // messageId / layout / metadata fields only, and pulling the
        // embedding BLOB + text payload here would reintroduce the exact
        // main-thread stall the cached path avoids.
        return (try? services.vectorStore.hydrateDisplayMetadata(vectorIds: [vectorId]))?.first
    }

    /// Returns the active frame's snapshot `messageIndex`, or an empty
    /// dictionary when no snapshot has been built yet. Used by both
    /// readouts to look up the canonical `MessageFilterRow` for the
    /// hovered or locked node. Embargoed live arrivals are filtered out so
    /// no consumer — locked-overlay neighbor hydration, hover readouts,
    /// Ask retrieval scope — can surface a message before its arrival
    /// moment. (Workspace snapshots are already gather-filtered; the
    /// cached Metal snapshot is not, hence the explicit filter.)
    @MainActor
    private var currentMessageIndex: [String: MessageFilterRow] {
        if state.activeFrame.spatialLens == .projects,
           let snapshot = projectsWorkspace?.currentSnapshot {
            return snapshot.messageFilterRows
        }
        if state.activeFrame.spatialLens == .frontPage,
           let snapshot = frontPageWorkspace?.currentSnapshot {
            return snapshot.messageFilterRows
        }
        // Read on nearly every view update in the Metal lenses (lock overlay,
        // hover cards, action targets); re-filter only when the frame's
        // cached snapshot or the arrival gate has changed.
        let frame = state.activeFrame
        let ledger = NewMailArrivalLedger.shared
        return gatedMessageIndexMemo.messageIndex(
            frame: frame,
            contentRevision: snapshotCache.contentRevision,
            gate: ledger.visibilityGate(),
            source: {
                snapshotCache.snapshot(
                    for: frame,
                    maxAge: .greatestFiniteMagnitude
                )?.messageIndex ?? [:]
            },
            filter: { ledger.filteredMessageIndex($0) }
        )
    }

    @MainActor
    private var lockedOverlayMessageStatusSignals: MessageStatusSignalIndex {
        if state.activeFrame.spatialLens == .projects,
           let snapshot = projectsWorkspace?.currentSnapshot {
            return MessageStatusSignalIndex(projectRowsSnapshot: snapshot.rowsSnapshot)
        }
        return .empty
    }

    /// Snapshot marker for toolbar count refreshes. The Metal scene refreshes
    /// `basePacket`; the SwiftUI/Canvas lenses refresh their workspace
    /// snapshots instead, so the top bar needs to observe both families.
    @MainActor
    private var topBarCountSnapshotMarker: TimeInterval {
        switch state.activeFrame.spatialLens {
        case .projects:
            return projectsWorkspace?.currentSnapshot?.builtAt.timeIntervalSinceReferenceDate
                ?? basePacket.generatedAt
        case .frontPage:
            return frontPageWorkspace?.currentSnapshot?.builtAt.timeIntervalSinceReferenceDate
                ?? basePacket.generatedAt
        case .timeline:
            return timelineWorkspace?.currentSnapshot?.builtAt.timeIntervalSinceReferenceDate
                ?? basePacket.generatedAt
        default:
            return basePacket.generatedAt
        }
    }

    /// Count source for top-bar pulldowns. Metal lenses can use the render
    /// snapshot already in cache; non-Metal lenses still need a full message
    /// index so account/topic totals and raw Moments populations are not
    /// clipped to the currently rendered SwiftUI/Canvas workspace.
    @MainActor
    private func topBarCountRows() async -> [MessageFilterRow] {
        let frame = state.activeFrame
        let snapshot = await constellationSnapshot(
            for: frame, maxAge: .greatestFiniteMagnitude,
            sourceVersion: Self.usesMetalScene(frame) ? nil : topBarCountSnapshotMarker
        )
        return Array(snapshot.messageIndex.values)
    }

    /// Recompute the per-account overall totals cache. Independent of every
    /// live filter — runs whenever the snapshot timestamp shifts (scene
    /// rebuild after ingestion / frame change) or when category-edit flows
    /// mutate the in-memory `messageIndex`.
    @MainActor
    private func refreshAccountMessageTotals() async {
        let rows = await topBarCountRows()
        guard !Task.isCancelled else { return }
        let computed = await Task.detached(priority: .userInitiated) {
            var counts: [UUID: Int] = [:]
            for row in rows {
                guard let accountId = row.accountId else { continue }
                counts[accountId, default: 0] += 1
            }
            return counts
        }.value
        guard !Task.isCancelled else { return }
        accountMessageTotals = computed
    }

    /// Rebuild the Voices autocomplete catalog independently of the active
    /// renderer. Timeline, Projects, and Front Page do not run the Metal scene
    /// refresh that previously owned this cache, but their top bar still needs
    /// the same full-account correspondent names on first mount.
    @MainActor
    private func refreshCorrespondentSuggestions() async {
        let scopes = state.filter.correspondentScopes
        let accountIds = state.filter.accountIds
        let frame = state.activeFrame
        let snapshot = await constellationSnapshot(
            for: frame, maxAge: .greatestFiniteMagnitude,
            sourceVersion: Self.usesMetalScene(frame) ? nil : topBarCountSnapshotMarker
        )
        guard !Task.isCancelled else { return }
        // Match scene refresh semantics: an embargoed live arrival must not
        // leak its correspondent through autocomplete before its unified alert.
        let messageIndex = NewMailArrivalLedger.shared.filteredMessageIndex(snapshot.messageIndex)
        let computed = await Task.detached(priority: .utility) {
            Self.buildCorrespondentSuggestions(
                scopes: scopes,
                accountIds: accountIds,
                messageIndex: messageIndex
            )
        }.value
        guard !Task.isCancelled else { return }
        correspondentSuggestions = computed
    }

    /// Recompute the per-preset Moments counts cache. Counts honor the active
    /// Destination account scope while other TopBar filters remain independent.
    /// Refreshes when the selected accounts, configured `customTimeRange`, or
    /// active snapshot marker changes — see the
    /// `.task(id: TimeRangeCountsRefreshKey(…))` modifier below.
    @MainActor
    private func refreshTimeRangeCounts() async {
        let rows = await topBarCountRows()
        guard !Task.isCancelled else { return }
        var filter = VectorFilter()
        filter.accountIds = state.filter.accountIds
        // Resolve windows on the main actor — `TimeRangePreset.range(relativeTo:)`
        // is `@MainActor`-isolated under this project's default-isolation
        // setting, so the detached task must receive pre-baked windows
        // rather than calling it itself.
        let windows = ConstellationMessageFilter.resolveTimeRangeWindows(
            presets: TimeRangePreset.allCases,
            customRange: customTimeRange
        )
        let computed = await Task.detached(priority: .userInitiated) {
            ConstellationMessageFilter.timeRangeCounts(
                rows: rows,
                filter: filter,
                windowsByPreset: windows
            )
        }.value
        guard !Task.isCancelled else { return }
        timeRangeCounts = computed
    }

    /// Recompute the Voices row counts: for each correspondent and mailing
    /// list, the messages it would show under every other active filter and
    /// the scene's current time window. Like the autocomplete catalog, an
    /// embargoed live arrival is never counted before its unified alert.
    /// Skipped during onboarding, where the top bar is hidden.
    @MainActor
    private func refreshVoicesCounts() async {
        guard !onboardingMode else { return }
        let frame = state.activeFrame
        let snapshot = await constellationSnapshot(
            for: frame, maxAge: .greatestFiniteMagnitude,
            sourceVersion: Self.usesMetalScene(frame) ? nil : topBarCountSnapshotMarker
        )
        guard !Task.isCancelled else { return }
        // Every lens refresh re-derives rolling presets from now; the stored
        // filter keeps the window from when the preset was picked.
        let filter = ConstellationFilterResolver.effectiveSceneFilter(
            baseFilter: state.filter,
            selectedTimeRange: state.selectedTimeRange
        )
        let computed = await Self.concurrentVoicesCounts(
            snapshotIndex: snapshot.messageIndex,
            gate: NewMailArrivalLedger.shared.visibilityGate(),
            filter: filter
        )
        // A superseded run stops early inside the pass; a finished one that
        // was superseded meanwhile must not overwrite the newer result.
        guard !Task.isCancelled, let computed else { return }
        voicesCounts = computed
    }

    /// Off-main form of `ConstellationMessageFilter.voicesCounts` over a
    /// cached snapshot's index with the arrival gate applied first. It runs
    /// inside the caller's task, so cancelling that task stops the pass;
    /// `nil` when cancelled.
    @concurrent
    nonisolated static func concurrentVoicesCounts(
        snapshotIndex: [String: MessageFilterRow],
        gate: NewMailArrivalVisibilityGate,
        filter: VectorFilter
    ) async -> ConstellationMessageFilter.VoicesCounts? {
        let messageIndex = gate.visibleMessageIndex(snapshotIndex)
        guard !Task.isCancelled else { return nil }
        return ConstellationMessageFilter.voicesCounts(
            rows: Array(messageIndex.values),
            filter: filter,
            checksCancellation: true
        )
    }

    /// Recompute the per-topic counts cache. Runs whenever the live filter
    /// (without classification axes, since the counts are hypothetical with
    /// respect to each facet) or the active snapshot's render timestamp changes — see the
    /// `.task(id: TopicCountsRefreshKey(…))` modifier below.
    @MainActor
    private func refreshTopicClassificationCounts() async {
        let rows = await topBarCountRows()
        guard !Task.isCancelled else { return }
        let filter = state.filter
        let computed = await Task.detached(priority: .userInitiated) {
            ConstellationMessageFilter.classificationCounts(rows: rows, filter: filter)
        }.value
        // The detached task is unstructured, so a faster-finishing earlier
        // computation could otherwise overwrite a later one's result if
        // `.task(id:)` re-fires while we're suspended. Drop our result when
        // the surrounding task has been cancelled — the new task is already
        // computing the fresh value.
        guard !Task.isCancelled else { return }
        purposeCounts = computed.purposes
        mailingListCategoryCount = computed.mailingLists
        topicCustomCategoryCounts = computed.custom
    }

    @MainActor
    private func hasCompletedSummary(forMessageId messageId: String, row: MessageFilterRow) -> Bool {
        completedSummaryText(forMessageId: messageId, row: row) != nil
    }

    @MainActor
    private func completedSummaryText(forMessageId messageId: String, row: MessageFilterRow) -> String? {
        let cachedSummary = SummaryTextSanitizer.cleaned(summaryByMessageId[messageId])
        if let cachedSummary,
           classificationByMessageId[messageId] != nil {
            return cachedSummary
        }
        guard row.mailClassification != nil else { return nil }
        return SummaryTextSanitizer.cleaned(row.bodySummary)
    }

    @MainActor
    private func knownInterpretation(
        forMessageId messageId: String,
        row: MessageFilterRow
    ) -> SummaryKnownInterpretation? {
        guard let classification = row.mailClassification,
              let isActionable = row.isActionable,
              let requiresConfirmation = row.requiresConfirmation else {
            return nil
        }
        if let uuid = UUID(uuidString: messageId),
           let storedVerdict = storedTriageVerdict(for: uuid) {
            return SummaryKnownInterpretation(
                classification: classification,
                triageVerdict: Self.triageVerdictForCurrentMessageState(
                    storedVerdict,
                    isActionable: isActionable,
                    requiresConfirmation: requiresConfirmation
                ),
                customCategoryKeys: row.customCategoryKeys
            )
        }
        let verdict = TriageVerdict(
            isActionable: isActionable,
            requiresConfirmation: requiresConfirmation,
            confidence: 0.5,
            extractionVersion: "stored-hover-v1"
        )
        return SummaryKnownInterpretation(
            classification: classification,
            triageVerdict: verdict,
            customCategoryKeys: row.customCategoryKeys
        )
    }

    nonisolated static func triageVerdictForCurrentMessageState(
        _ storedVerdict: TriageVerdict,
        isActionable: Bool,
        requiresConfirmation: Bool
    ) -> TriageVerdict {
        let action = isActionable ? storedVerdict.action : nil
        let acknowledgement = requiresConfirmation ? storedVerdict.acknowledgement : nil
        guard storedVerdict.isActionable != isActionable
            || storedVerdict.requiresConfirmation != requiresConfirmation
            || storedVerdict.action != action
            || storedVerdict.acknowledgement != acknowledgement else {
            return storedVerdict
        }
        return TriageVerdict(
            isActionable: isActionable,
            requiresConfirmation: requiresConfirmation,
            confidence: storedVerdict.confidence,
            action: action,
            acknowledgement: acknowledgement,
            extractionVersion: storedVerdict.extractionVersion
        )
    }

    @MainActor
    private func storedTriageVerdict(for messageId: UUID) -> TriageVerdict? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.id == messageId }
        )
        descriptor.fetchLimit = 1
        guard let json = try? modelContext.fetch(descriptor).first?.analysis?.triageVerdictJSON,
              let data = json.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(TriageVerdict.self, from: data) else {
            return nil
        }
        return verdict
    }

    /// Drop every cached snapshot and force a rebuild on the active frame
    /// so per-message colors re-bind to the updated `Account.colorIndex`
    /// values. Triggered by `.ohiaAccountColorChanged`.
    @MainActor
    private func invalidateAccountColors() {
        snapshotCache.clearAll()
        markInactiveLensDataChanged()
        switch state.activeFrame.spatialLens {
        case .frontPage:
            frontPageData.invalidateAndRefresh()
        case .timeline:
            timelineData.invalidateAndRefreshIfBound()
        case .projects:
            projectsData.invalidateAndRefresh()
        default:
            Task {
                await refreshSceneData(updateColorLookup: true)
            }
        }
    }

    @MainActor
    private func invalidateVisibleEmailSummaries() {
        retainedMetalSurfaces.removeAll()
        let currentMessageIds = currentInspectedMessageIds()
        let lockedMessageId = currentLockedMessageId()
        summaryByMessageId.removeAll()
        classificationByMessageId.removeAll()
        summaryUnavailableMessageIds.removeAll()
        summaryUnavailableReasonByMessageId.removeAll()
        summaryRegenerationTokensByMessageId.removeAll()
        snapshotCache.clearStoredSummaries()
        projectsData.invalidateAndRefresh()
        frontPageData.invalidateAndRefresh()
        timelineData.invalidateAndRefreshIfBound()
        for messageId in currentMessageIds {
            if messageId == lockedMessageId {
                guard let token = lockEntryEnrichmentToken else { continue }
                Task { await resolveLockedSummaryAfterEntry(for: token) }
            } else {
                Task { await resolveOnDemandSummary(forMessageId: messageId, scope: .backgroundPrewarm) }
            }
        }
    }

    @MainActor
    private func currentInspectedMessageIds() -> Set<String> {
        let vectorIds = [state.hoveredVectorId, state.lockedVectorId].compactMap { $0 }
        return Set(vectorIds.compactMap { vectorId in
            (visibleRecordCache[vectorId] ?? citationSourceRecord(vectorId: vectorId))?.messageId
        })
    }

    @MainActor
    private func currentLockedMessageId() -> String? {
        guard let vectorId = state.lockedVectorId else { return nil }
        return (visibleRecordCache[vectorId] ?? citationSourceRecord(vectorId: vectorId))?.messageId
    }

    /// Single arbiter for the regenerate-summary command. Picks exactly one visible generated surface by
    /// priority — expanded Ask answer, then the active lens readout, then a
    /// locked node's inspector, then a hovered node — and regenerates only
    /// that surface. The two surfaces that own their own generative state
    /// (locked-overlay context orientation, Projects gutter summary) are driven
    /// by re-dispatched notifications posted here, so they no longer observe
    /// the user command independently and can never fire in parallel.
    @MainActor
    private func regenerateVisibleGeneratedText() async {
        if await regenerateExpandedAskAnswer() { return }

        // `.frontPage` / `.projects` mount no Metal scene, lock overlay, or
        // hover popup, so each claims its lens unconditionally — there is no
        // lower-priority surface to fall through to.
        switch state.activeFrame.spatialLens {
        case .frontPage:
            _ = await regenerateFrontPageEmailSummary()
            return
        case .projects:
            if await regenerateProjectsMessageSummary() { return }
            // No focused message readout — refresh the project gutter pane if
            // one is open (the time view no-ops when it isn't).
            NotificationCenter.default.post(name: .ohiaRegenerateProjectsGutter, object: nil)
            return
        default:
            break
        }

        // Spatial (Metal) and timeline lenses: the lock overlay's inspector and
        // the hover popup are the only generative surfaces.
        if await regenerateLockedEmailSummary() {
            // The locked inspector pairs a summary with a context orientation;
            // regenerate both halves of the one focused surface.
            NotificationCenter.default.post(name: .ohiaRegenerateLockedContext, object: nil)
            return
        }
        _ = await regenerateHoveredEmailSummary()
    }

    @MainActor
    private func regenerateVisibleTranslation() {
        switch state.activeFrame.spatialLens {
        case .frontPage:
            NotificationCenter.default.post(name: .ohiaRegenerateFrontPageTranslation, object: nil)
        case .timeline:
            NotificationCenter.default.post(name: .ohiaRegenerateTimelineTranslation, object: nil)
        case .projects:
            return
        default:
            if visibleLockedMessageId() != nil {
                NotificationCenter.default.post(name: .ohiaRegenerateLockedEmailTranslation, object: nil)
            } else {
                NotificationCenter.default.post(name: .ohiaRegenerateAnnotationTranslation, object: nil)
            }
        }
    }

    @MainActor
    private func regenerateExpandedAskAnswer() async -> Bool {
        guard sidebarVisible,
              SidebarTab(rawValue: sidebarTabRaw) == .ask,
              qaVM.canRegenerateExpandedAnswer else {
            return false
        }
        let filter = await activeFilterSpec()
        await qaVM.regenerateExpandedAnswer(filter: filter) { sources in
            await ConstellationAskThreadContextProvider(
                modelContext: modelContext,
                vectorStore: services.vectorStore
            ).expansion(for: sources)
        }
        return true
    }

    @MainActor
    private func regenerateFrontPageEmailSummary() async -> Bool {
        guard let workspace = frontPageWorkspace,
              let target = frontPageSummaryTarget(in: workspace) else {
            return false
        }
        _ = await resolveOnDemandSummary(
            forMessageId: target.messageId,
            rowOverride: target.row,
            scope: .lockedContext,
            forceRegeneration: true
        )
        return true
    }

    @MainActor
    private func frontPageSummaryTarget(
        in workspace: FrontPageWorkspaceState
    ) -> (messageId: String, row: MessageFilterRow?)? {
        guard let snapshot = workspace.currentSnapshot else { return nil }
        if let focused = workspace.focusedArticle {
            return (
                focused.messageIdString,
                snapshot.messageFilterRows[focused.messageIdString]
            )
        }
        let selected = workspace.selectedArticles
        if selected.count == 1, let article = selected.first {
            return (
                article.messageIdString,
                snapshot.messageFilterRows[article.messageIdString]
            )
        }
        if let hoveredID = workspace.hoveredArticleID,
           let article = snapshot.article(id: hoveredID) {
            return (
                article.messageIdString,
                snapshot.messageFilterRows[article.messageIdString]
            )
        }
        return nil
    }

    @MainActor
    private func regenerateProjectsMessageSummary() async -> Bool {
        guard let workspace = projectsWorkspace,
              let snapshot = workspace.currentSnapshot else {
            return false
        }
        let messageID: UUID?
        if let readout = workspace.messageReadout {
            messageID = readout.messageID
        } else if case .message(let hoveredID) = workspace.hoveredTarget {
            messageID = hoveredID
        } else {
            messageID = nil
        }
        guard let messageID else { return false }
        let messageId = messageID.uuidString
        _ = await resolveOnDemandSummary(
            forMessageId: messageId,
            rowOverride: snapshot.messageFilterRows[messageId],
            scope: .lockedContext,
            forceRegeneration: true
        )
        return true
    }

    @MainActor
    private func regenerateLockedEmailSummary() async -> Bool {
        guard let messageId = visibleLockedMessageId() else { return false }
        _ = await resolveOnDemandSummary(
            forMessageId: messageId,
            rowOverride: currentMessageIndex[messageId],
            scope: .lockedContext,
            forceRegeneration: true
        )
        return true
    }

    /// The locked message id *only when its inspector is actually on screen* —
    /// the focused scene is up, or `lockedNodeOverlayLayer` has finished its
    /// reveal (`revealedLockedVectorId == lockedVectorId`). Returns nil during
    /// the pre-reveal window or when no lock is held, so the command never regenerates
    /// a summary the user cannot see (e.g. a lock held over from a spatial lens
    /// the user has since left).
    private func visibleLockedMessageId() -> String? {
        guard let id = state.lockedVectorId, revealedLockedVectorId == id else { return nil }
        return currentLockedMessageId()
    }

    @MainActor
    private func regenerateHoveredEmailSummary() async -> Bool {
        guard let vectorId = state.hoveredVectorId,
              let rec = visibleRecordCache[vectorId] ?? citationSourceRecord(vectorId: vectorId) else {
            return false
        }
        _ = await resolveOnDemandSummary(
            forMessageId: rec.messageId,
            rowOverride: currentMessageIndex[rec.messageId],
            scope: .hover,
            forceRegeneration: true
        )
        return true
    }

    @MainActor
    private func shouldShowSummaryPlaceholder(forMessageId messageId: String, row: MessageFilterRow) -> Bool {
        guard UUID(uuidString: messageId) != nil,
              !hasCompletedSummary(forMessageId: messageId, row: row),
              !summaryUnavailableMessageIds.contains(messageId) else {
            return false
        }
        let hasBodyTextPath = row.bodyTextPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasBodyTextPath || row.hasAttachments
    }

    @MainActor
    private func resolveLockedSummaryAfterEntry(for token: LockEntryEnrichmentToken) async {
        guard state.lockedVectorId == token.vectorId,
              lockRevealSequence == token.sequence,
              let rec = visibleRecordCache[token.vectorId] ?? citationSourceRecord(vectorId: token.vectorId) else {
            return
        }
        do {
            try await Task.sleep(for: Self.lockSummaryStartDelay)
        } catch {
            return
        }
        guard !Task.isCancelled,
              state.lockedVectorId == token.vectorId,
              lockRevealSequence == token.sequence else {
            return
        }
        lockSummaryInFlightToken = token
        defer {
            if lockSummaryInFlightToken == token {
                lockSummaryInFlightToken = nil
            }
        }
        await resolveOnDemandSummary(forMessageId: rec.messageId, scope: .lockedContext)
    }

    @MainActor
    private func scheduleRelatedSummaryPrewarm(_ targets: [LockedNodeRelatedSummaryPrewarm]) {
        relatedSummaryPrewarmTask?.cancel()
        guard !targets.isEmpty else {
            relatedSummaryPrewarmTask = nil
            return
        }

        let lockedVectorID = state.lockedVectorId
        relatedSummaryPrewarmTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(1400))
            } catch {
                return
            }
            guard state.lockedVectorId == lockedVectorID else {
                return
            }

            for target in targets {
                guard !Task.isCancelled,
                      state.lockedVectorId == lockedVectorID else {
                    return
                }
                _ = await resolveOnDemandSummary(
                    forMessageId: target.messageId,
                    rowOverride: target.row,
                    scope: .backgroundPrewarm
                )
                do {
                    try await Task.sleep(for: .milliseconds(450))
                } catch {
                    return
                }
            }
        }
    }

    @MainActor
    @discardableResult
    private func resolveOnDemandSummary(
        forMessageId messageId: String,
        rowOverride: MessageFilterRow? = nil,
        scope: OnDemandSummaryScope = .hover,
        forceRegeneration: Bool = false
    ) async -> String? {
        guard let uuid = UUID(uuidString: messageId),
              let row = rowOverride ?? currentMessageIndex[messageId] else { return nil }
        let regenerationToken = forceRegeneration ? UUID() : nil
        if let regenerationToken {
            // Animate the token in/out so the summary placeholders'
            // `.transition(.opacity)` actually fades rather than snapping.
            withAnimation(.easeInOut(duration: 0.18)) {
                summaryRegenerationTokensByMessageId[messageId] = regenerationToken
            }
        }
        defer {
            if let regenerationToken,
               summaryRegenerationTokensByMessageId[messageId] == regenerationToken {
                withAnimation(.easeInOut(duration: 0.18)) {
                    summaryRegenerationTokensByMessageId[messageId] = nil
                }
            }
        }
        summaryUnavailableMessageIds.remove(messageId)
        summaryUnavailableReasonByMessageId[messageId] = nil
        let knownInterpretation = knownInterpretation(forMessageId: messageId, row: row)
        let bodyText = await readBodyText(path: row.bodyTextPath) ?? ""
        guard !Task.isCancelled else { return nil }
        let summaryContext = await summarizationContext(forMessageId: messageId, row: row)
        guard !Task.isCancelled else { return nil }
        guard bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || summaryContext?.hasSummarizableAnchorEvidence == true else {
            summaryUnavailableMessageIds.insert(messageId)
            summaryUnavailableReasonByMessageId[messageId] = "No body or attachment evidence to summarize."
            return nil
        }
        let trimmedSenderName = row.fromName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySender: String
        if let trimmedSenderName, trimmedSenderName.isEmpty == false {
            displaySender = trimmedSenderName
        } else {
            displaySender = row.fromAddress
        }
        let result = await services.onDemandSummarizer.summary(
            for: uuid,
            scope: scope,
            accountID: row.accountId,
            forceRegeneration: forceRegeneration,
            existingSummary: row.bodySummary,
            existingSummaryInputFingerprint: row.bodySummaryInputFingerprint,
            knownInterpretation: knownInterpretation,
            bodyText: bodyText,
            senderName: displaySender,
            subject: row.subject,
            context: summaryContext
        )
        guard !Task.isCancelled else { return nil }
        if let result, !result.summary.isEmpty {
            summaryByMessageId[messageId] = result.summary
            if let classification = result.classification {
                classificationByMessageId[messageId] = classification
            }
            // Union, not replace: user-tagged custom keys are sticky across
            // regeneration (the persistence layer applies the same rule).
            summaryCustomKeysByMessageId[messageId] = result.customCategoryKeys
                .union(effectiveCustomCategoryKeys(messageId: messageId, fallbackRow: row))
            summaryUnavailableMessageIds.remove(messageId)
            summaryUnavailableReasonByMessageId[messageId] = nil
            return result.summary
        } else {
            let failureMessage = await services.onDemandSummarizer.failureMessage(for: uuid)
            guard failureMessage != nil else { return nil }
            summaryUnavailableMessageIds.insert(messageId)
            summaryUnavailableReasonByMessageId[messageId] = failureMessage
            return nil
        }
    }

    @MainActor
    private func readBodyText(path: String?) async -> String? {
        guard let path, !path.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            try? String(contentsOfFile: path, encoding: .utf8)
        }.value
    }

    @MainActor
    private func summarizationContext(
        forMessageId messageId: String,
        row: MessageFilterRow
    ) async -> SummarizationContext? {
        let packet = renderPacket
        let messageIndex = currentMessageIndex
        let connectedFibers = packet.fibers
            .filter { $0.sourceMessageId == messageId || $0.targetMessageId == messageId }
            .sorted {
                if $0.strength != $1.strength { return $0.strength > $1.strength }
                return $0.confidence > $1.confidence
            }
            .prefix(4)
            .map { $0 }
        let satelliteIds = packet.satellites
            .filter { $0.parentMessageId == messageId }
            .prefix(5)
            .map(\.vectorId)

        let neighborVectorIds = connectedFibers.map { fiber in
            fiber.sourceMessageId == messageId ? fiber.targetVectorId : fiber.sourceVectorId
        }
        let vectorIds = Array(Set(neighborVectorIds + satelliteIds))
        let vectorStore = services.vectorStore
        let hydrated = await Task.detached(priority: .utility) {
            (try? vectorStore.hydrate(vectorIds: vectorIds)) ?? []
        }.value
        let recordById = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.vectorId, $0) })

        let connectedItems = connectedFibers.compactMap { fiber -> SummarizationContext.ConnectedItem? in
            let otherMessageId = fiber.sourceMessageId == messageId ? fiber.targetMessageId : fiber.sourceMessageId
            let otherVectorId = fiber.sourceMessageId == messageId ? fiber.targetVectorId : fiber.sourceVectorId
            guard let otherRow = messageIndex[otherMessageId] else { return nil }
            let excerpt = recordById[otherVectorId]?.textPayload ?? otherRow.bodySummary ?? ""
            return SummarizationContext.ConnectedItem(
                senderName: displaySender(for: otherRow),
                subject: otherRow.subject.isEmpty ? "(no subject)" : otherRow.subject,
                excerpt: excerpt,
                similarity: fiber.strength,
                direction: otherRow.isSentByUser ? .outgoing : .incoming,
                recipients: summarizationRecipients(for: otherRow)
            )
        }

        let satelliteEvidence = satelliteIds.compactMap { vectorId -> SummarizationContext.SatelliteEvidence? in
            guard let record = recordById[vectorId] else { return nil }
            let text = record.textPayload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { return nil }
            return SummarizationContext.SatelliteEvidence(
                kind: satelliteKind(for: record),
                text: text
            )
        }
        let visualAttachmentSummaries = await visualAttachmentSummaries(forMessageId: messageId)
        let textAttachmentEvidence = await textAttachmentEvidence(forMessageId: messageId)
        let messageEvidenceDigest = await messageEvidenceDigest(
            forMessageId: messageId,
            bodyText: await readBodyText(path: row.bodyTextPath) ?? ""
        )

        let context = SummarizationContext(
            vectorShape: .init(
                contextCount: row.vectorBreakdown.context,
                attachmentCount: row.vectorBreakdown.attachment,
                entityCount: row.vectorBreakdown.entity,
                neighborCount: row.neighborCount
            ),
            analysisSignals: summarizationSignals(for: row),
            connectedItems: connectedItems,
            satelliteEvidence: satelliteEvidence,
            messageEvidenceDigest: messageEvidenceDigest,
            visualAttachmentSummaries: visualAttachmentSummaries,
            textAttachmentEvidence: textAttachmentEvidence,
            userIdentity: summarizationUserIdentity(for: row),
            anchorDirection: row.isSentByUser ? .outgoing : .incoming,
            anchorRecipients: summarizationRecipients(for: row),
            customCategories: customCategoryStore.descriptors.filter(\.isActive)
        )
        return context.isEmpty ? nil : context
    }

    @MainActor
    private func visualAttachmentSummaries(forMessageId messageId: String) async -> [SummarizationContext.VisualAttachmentSummary] {
        guard let uuid = UUID(uuidString: messageId),
              let message = try? modelContext.fetch(
                FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == uuid })
              ).first else {
            return []
        }

        return message.attachments
            .compactMap { attachment -> SummarizationContext.VisualAttachmentSummary? in
                guard attachment.visualExtractionStatus == VisualAttachmentExtractionStatus.completed.rawValue,
                      let summary = attachment.visualSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                      summary.isEmpty == false else {
                    return nil
                }
                return SummarizationContext.VisualAttachmentSummary(
                    filename: attachment.filename,
                    summary: summary
                )
            }
            .prefix(4)
            .map { $0 }
    }

    @MainActor
    private func messageEvidenceDigest(forMessageId messageId: String, bodyText: String) async -> String? {
        guard let uuid = UUID(uuidString: messageId),
              let message = try? modelContext.fetch(
                FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == uuid })
              ).first else {
            return nil
        }

        let attachmentPaths = message.attachments.compactMap { attachment -> (id: String, path: String)? in
            guard let path = attachment.extractedTextPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            return (attachment.id.uuidString, path)
        }
        let fallbackTextByAttachmentId = await Task.detached(priority: .utility) {
            var values: [String: String] = [:]
            for item in attachmentPaths {
                guard let text = try? String(contentsOfFile: item.path, encoding: .utf8) else {
                    continue
                }
                values[item.id] = text
            }
            return values
        }.value

        return MessageEvidenceBundle
            .build(
                message: message,
                bodyText: bodyText,
                fallbackTextByAttachmentId: fallbackTextByAttachmentId
            )?
            .digest(maxCharacters: 2_400)
    }

    @MainActor
    private func textAttachmentEvidence(forMessageId messageId: String) async -> [SummarizationContext.TextAttachmentEvidence] {
        guard let uuid = UUID(uuidString: messageId),
              let message = try? modelContext.fetch(
                FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == uuid })
              ).first else {
            return []
        }

        let attachments = message.attachments
            .compactMap { attachment -> (filename: String, path: String)? in
                guard let path = attachment.extractedTextPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty else {
                    return nil
                }
                return (attachment.filename, path)
            }
            .prefix(4)
            .map { $0 }

        return await Task.detached(priority: .utility) {
            attachments.compactMap { item in
                guard let text = try? String(contentsOfFile: item.path, encoding: .utf8) else {
                    return nil
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return SummarizationContext.TextAttachmentEvidence(
                    filename: item.filename,
                    text: String(trimmed.prefix(2_400))
                )
            }
        }.value
    }

    private func displaySender(for row: MessageFilterRow) -> String {
        if let name = row.fromName?.trimmingCharacters(in: .whitespacesAndNewlines),
           name.isEmpty == false {
            return name
        }
        return row.fromAddress
    }

    private func summarizationRecipients(for row: MessageFilterRow) -> SummarizationContext.AnchorRecipients? {
        let to = row.toAddresses.enumerated().map { index, address in
            let displayName = row.toDisplayNames.indices.contains(index)
                ? row.toDisplayNames[index]
                : nil
            return SummarizationContext.Recipient(displayName: displayName, address: address)
        }
        let recipients = SummarizationContext.AnchorRecipients(to: to)
        return recipients.isUseful ? recipients : nil
    }

    @MainActor
    private func summarizationUserIdentity(for row: MessageFilterRow) -> SummarizationUserIdentity? {
        let account: Account?
        if let accountId = row.accountId {
            account = accounts.first(where: { $0.id == accountId })
        } else if accounts.count == 1 {
            account = accounts.first
        } else {
            account = nil
        }
        guard let account else { return nil }
        return summarizationUserIdentity(for: account)
    }

    @MainActor
    private func summarizationUserIdentity(for account: Account) -> SummarizationUserIdentity? {
        let primaryEmail = account.emailAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidateNames = [
            account.primaryIdentity?.displayName,
            account.displayName
        ] + account.identities.map(\.displayName)

        let displayName = candidateNames
            .compactMap { personNameCandidate($0, primaryEmail: primaryEmail) }
            .first ?? ""
        let identity = SummarizationUserIdentity(
            displayName: displayName,
            primaryEmailAddress: primaryEmail,
            aliasEmailAddresses: account.identities.map(\.address)
        )
        return identity.isUseful ? identity : nil
    }

    /// Aggregated owner identity for the Projects-lens summary pane. A project
    /// can span accounts, so this leans on the primary account's display name
    /// and address while folding every account / identity address into the
    /// alias set — letting the briefing recognize the owner regardless of which
    /// account a given message belongs to.
    private var projectsSummaryUserIdentity: SummarizationUserIdentity? {
        guard let primary = accounts.first(where: { $0.primaryIdentity != nil }) ?? accounts.first else {
            return nil
        }
        let base = summarizationUserIdentity(for: primary)
        let primaryEmail = primary.emailAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var aliases = Set<String>()
        for account in accounts {
            let address = account.emailAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !address.isEmpty { aliases.insert(address) }
            for identity in account.identities {
                let alias = identity.address
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if !alias.isEmpty { aliases.insert(alias) }
            }
        }
        aliases.remove(primaryEmail)
        let identity = SummarizationUserIdentity(
            displayName: base?.displayName ?? "",
            primaryEmailAddress: primaryEmail,
            aliasEmailAddresses: Array(aliases).sorted()
        )
        return identity.isUseful ? identity : nil
    }

    private func personNameCandidate(_ value: String?, primaryEmail: String) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != primaryEmail,
              !trimmed.contains("@") else {
            return nil
        }
        return trimmed
    }

    private func satelliteKind(for record: VectorRecord) -> String {
        switch record.collection {
        case .context:
            return "body moon"
        case .attachment:
            return "attachment moon"
        case .entity:
            if let key = record.entityKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               key.isEmpty == false {
                return "entity moon: \(key)"
            }
            return "entity moon"
        case .style:
            return "style"
        }
    }

    private static func worldPosition(for record: VectorRecord) -> SIMD3<Float>? {
        guard let x = record.layoutX, let y = record.layoutY, let z = record.layoutZ else {
            return nil
        }
        return SIMD3<Float>(x, y, z)
    }

    private func summarizationSignals(for row: MessageFilterRow) -> [String] {
        guard let dims = row.dimensions else { return [] }
        var signals: [String] = []
        signals.append(contentsOf: dims.semanticTags
            .sorted { $0.weightedScore > $1.weightedScore }
            .prefix(3)
            .map { "tag=\($0.displayName)" })

        for deadline in dims.deadlines.prefix(2) {
            let date = deadline.dateString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard date.isEmpty == false else { continue }
            signals.append("deadline=\(date) (\(deadline.type))")
        }

        for task in dims.tasks.prefix(2) {
            let object = task.actionObject?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let object, object.isEmpty == false {
                signals.append("task=\(task.taskType): \(object)")
            } else {
                signals.append("task=\(task.taskType)")
            }
        }

        return signals
    }

    @MainActor
    private func syncOnboardingRevealSchedule(with packet: ConstellationRenderPacket, now: Date) {
        guard onboardingMode else { return }
        onboardingRevealSchedule.sync(stars: packet.stars, now: now)
    }

    @MainActor
    private func revealedOnboardingPacket(
        from packet: ConstellationRenderPacket,
        now: Date
    ) -> ConstellationRenderPacket {
        guard onboardingMode else { return packet }
        let revealedVectorIds = onboardingRevealSchedule.revealedVectorIds(now: now)
        guard !revealedVectorIds.isEmpty else {
            return ConstellationRenderPacket(
                stars: [],
                satellites: [],
                nebulae: [],
                fibers: [],
                hitProxies: [],
                budget: packet.budget,
                totalMessageCount: packet.totalMessageCount,
                totalVectorCount: packet.totalVectorCount,
                fieldDimFactor: packet.fieldDimFactor,
                visualLanguage: packet.visualLanguage,
                arcLabels: packet.arcLabels,
                personHubs: packet.personHubs,
                personRelations: packet.personRelations,
                personHitProxies: packet.personHitProxies,
                meaningClusterHubs: packet.meaningClusterHubs,
                meaningClusterVisibility: packet.meaningClusterVisibility,
                personRings: packet.personRings,
                personAtoms: packet.personAtoms
            )
        }

        let stars = packet.stars.filter { revealedVectorIds.contains($0.representativeVectorId) }
        let revealedMessageIds = Set(stars.map(\.messageId))
        return ConstellationRenderPacket(
            stars: stars,
            satellites: packet.satellites.filter { revealedMessageIds.contains($0.parentMessageId) },
            nebulae: [],
            fibers: packet.fibers.filter {
                revealedMessageIds.contains($0.sourceMessageId)
                    && revealedMessageIds.contains($0.targetMessageId)
            },
            hitProxies: packet.hitProxies.filter { revealedMessageIds.contains($0.messageId) },
            budget: packet.budget,
            totalMessageCount: packet.totalMessageCount,
            totalVectorCount: packet.totalVectorCount,
            fieldDimFactor: packet.fieldDimFactor,
            visualLanguage: packet.visualLanguage,
            arcLabels: packet.arcLabels,
            personHubs: packet.personHubs,
            personRelations: packet.personRelations,
            personHitProxies: packet.personHitProxies,
            meaningClusterHubs: packet.meaningClusterHubs,
            meaningClusterVisibility: packet.meaningClusterVisibility,
            personRings: packet.personRings,
            personAtoms: packet.personAtoms
        )
    }

    @MainActor
    private func prepareOnboardingCamera() {
        guard onboardingMode else { return }
        didFrameOnboardingCameraToNodes = false
        hasReportedFirstVisibleNodeRendered = false
        onboardingRevealSchedule.reset()
        visibleNodeLifecycle.reset()
        cameraController.snap(to: Self.onboardingEmptyCameraState)
    }

    @MainActor
    private func frameOnboardingCameraIfNeeded(for packet: ConstellationRenderPacket) {
        guard onboardingMode else { return }
        let messageCount = packet.stars.count
        guard messageCount > 0 else { return }
        guard !didFrameOnboardingCameraToNodes else { return }
        guard let cameraState = Self.onboardingCameraState(for: packet.stars.map(\.position)) else { return }
        cameraController.snap(to: cameraState)
        didFrameOnboardingCameraToNodes = true
    }

    // MARK: - Death animation (Event Horizon)

    /// Snapshot of a star (and its satellites) captured the moment its
    /// underlying message is reported deleted on the IMAP server. The
    /// snapshot keeps the visual state alive long enough to play the
    /// black-hole collapse before the node is finally pulled out of the
    /// scene.
    struct DyingNodeSnapshot: Sendable {
        let star: MessageStarInstance
        let satellites: [MessageSatelliteInstance]
        let startedAt: Date
        let lens: FrameKey
    }

    /// Snapshot of a People-lens correspondent hub whose final visible
    /// message node was deleted. Message stars already have an Event Horizon
    /// ghost; this preserves the parent planet and its rings long enough for
    /// the correspondent body itself to collapse instead of popping away.
    struct DyingPersonSnapshot: Sendable {
        let hub: PersonHubInstance
        let rings: [PersonRingInstance]
        let startedAt: Date
    }

    /// Snapshot of a star that just arrived in the constellation, used to
    /// drive the Supernova Shockwave birth animation independent of when
    /// the planner happens to refresh.
    struct BirthingNodeSnapshot: Sendable {
        let messageId: String
        let startedAt: Date
    }

    struct PendingLockedDeletionReturn: Equatable {
        let sequence: Int
        let frame: FrameKey
        let lockedVectorId: Int64?
        let personEmail: String?
    }

    /// Total duration of the death animation. Matches the sandbox tile so
    /// what designers iterate on lines up with what ships. `nonisolated`
    /// because `combinePacket` is `nonisolated static` and reads it.
    nonisolated static let deathAnimationDuration: TimeInterval = 1.25
    /// Meaning deletion needs a little more time to read as an Event Horizon
    /// collapse in the denser semantic galaxy.
    nonisolated static let meaningDeathAnimationDuration: TimeInterval = 1.60
    /// Extra sprite-footprint lift for Meaning's Event Horizon. Packed onto
    /// dying Meaning ghosts only; normal movement pulse values are left alone.
    nonisolated static let meaningEventHorizonExpansionBoost: Float = 0.65
    /// People correspondent deaths use the same closing wormhole phase as the
    /// annotation overlay, rather than a bespoke scale-down.
    nonisolated static let peopleDeathAnimationDuration: TimeInterval = WormholePhase.defaultDuration
    /// Focused People deletion lingers briefly after the visual death completes
    /// so the return to the constellation does not cut off the perceived end.
    nonisolated static let peopleFocusedDeletionReturnSettleDelay: TimeInterval = 0.5
    /// People correspondent death wormholes need to read at constellation scale,
    /// not as the smaller annotation-pane transition.
    nonisolated static let peopleDeathWormholeVortexScale: CGFloat = 1.65
    /// Briefly lifts the dying correspondent body/rings while the vortex is
    /// strongest so the deletion reads as an effect, not only a shrink.
    nonisolated static let peopleDeathWormholeBodyLift: Float = 0.36
    /// Keep a dying hub suppressed after the visible wormhole completes until
    /// the refreshed base packet has truly dropped it. This prevents stale
    /// People or focused packets from briefly popping the orb back to full size.
    nonisolated static let peopleDeathSuppressionMaxDuration: TimeInterval = 8.0
    /// Total duration of the supernova shockwave. Same easeOutCubic ring
    /// expansion the sandbox tile demonstrates.
    nonisolated static let birthAnimationDuration: TimeInterval = 1.20
    /// Tick interval for CPU-authored animation packets. Keep this aligned
    /// with the app-wide 60 fps animation cadence so Metal-side birth/death
    /// motion doesn't visibly lag SwiftUI overlays.
    private static let animationTickInterval: Duration = OhiaAnimationCadence.frameDuration

    @MainActor
    @discardableResult
    private func captureDyingSnapshots(messageIds: Set<String>) -> Set<String> {
        guard !messageIds.isEmpty else { return [] }
        // Don't double-capture the same message in flight — the second event
        // would reset the start time and stutter the animation.
        let now = Date.now
        let newlyDyingPersonEmails = captureDyingPersonSnapshots(
            messageIds: messageIds,
            now: now
        )
        let alreadyDying = Set(dyingSnapshots.map(\.star.messageId))
        let captureIds = messageIds.subtracting(alreadyDying)
        if !captureIds.isEmpty {
            visibleNodeLifecycle.remove(messageIds: captureIds)
            for messageId in captureIds {
                guard let star = renderPacket.stars.first(where: { $0.messageId == messageId }) else {
                    continue
                }
                let satellites = renderPacket.satellites.filter { $0.parentMessageId == messageId }
                dyingSnapshots.append(DyingNodeSnapshot(
                    star: star,
                    satellites: satellites,
                    startedAt: now,
                    lens: state.activeFrame.spatialLens
                ))
            }
        }
        if !dyingSnapshots.isEmpty || !dyingPersonSnapshots.isEmpty {
            startAnimationTickerIfNeeded()
        }
        return newlyDyingPersonEmails
    }

    @MainActor
    private func captureDyingPersonSnapshots(
        messageIds: Set<String>,
        now: Date
    ) -> Set<String> {
        guard state.activeFrame.spatialLens == .people else {
            return []
        }
        let alreadyDyingMessageIds = Set(dyingSnapshots.map(\.star.messageId))
        let alreadyDyingPersonEmails = Set(dyingPersonSnapshots.map(\.hub.email))
        var dyingEmails = Self.finalDyingPersonEmails(
            in: renderPacket.personHubs,
            currentDeletedMessageIds: messageIds,
            alreadyDyingMessageIds: alreadyDyingMessageIds,
            alreadyDyingPersonEmails: alreadyDyingPersonEmails
        )
        dyingEmails.formUnion(finalDyingFocusedPersonEmails(
            currentDeletedMessageIds: messageIds,
            alreadyDyingMessageIds: alreadyDyingMessageIds,
            alreadyDyingPersonEmails: alreadyDyingPersonEmails
        ))
        guard !dyingEmails.isEmpty else { return [] }
        let normalizedDyingEmails = Set(dyingEmails.map(PeopleRingMessageScope.normalizedEmail))
        let dyingHubs = renderPacket.personHubs.filter { hub in
            normalizedDyingEmails.contains(PeopleRingMessageScope.normalizedEmail(hub.email))
        }

        let ringsByEmail = Dictionary(grouping: renderPacket.personRings, by: \.email)
        var capturedEmails = Set<String>()
        for hub in dyingHubs {
            dyingPersonSnapshots.append(DyingPersonSnapshot(
                hub: hub,
                rings: ringsByEmail[hub.email] ?? [],
                startedAt: now
            ))
            capturedEmails.insert(PeopleRingMessageScope.normalizedEmail(hub.email))
        }

        for personFocus in activePeopleFocuses() {
            let normalizedEmail = PeopleRingMessageScope.normalizedEmail(personFocus.email)
            guard normalizedDyingEmails.contains(normalizedEmail),
                  !capturedEmails.contains(normalizedEmail) else {
                continue
            }
            dyingPersonSnapshots.append(Self.fallbackDyingPersonSnapshot(
                for: personFocus,
                now: now
            ))
            capturedEmails.insert(normalizedEmail)
        }
        clearPeopleHoverIfDyingHubWasHovered(dyingEmails)
        return dyingEmails
    }

    nonisolated static func finalDyingPersonEmails(
        in hubs: [PersonHubInstance],
        currentDeletedMessageIds: Set<String>,
        alreadyDyingMessageIds: Set<String>,
        alreadyDyingPersonEmails: Set<String>
    ) -> Set<String> {
        guard !currentDeletedMessageIds.isEmpty else { return [] }
        let removedOrDyingMessageIds = currentDeletedMessageIds.union(alreadyDyingMessageIds)
        let normalizedAlreadyDyingPersonEmails = Set(
            alreadyDyingPersonEmails.map(PeopleRingMessageScope.normalizedEmail)
        )
        return Set(hubs.compactMap { hub in
            let email = PeopleRingMessageScope.normalizedEmail(hub.email)
            guard !normalizedAlreadyDyingPersonEmails.contains(email),
                  !hub.messageIds.isEmpty,
                  !hub.messageIds.isDisjoint(with: currentDeletedMessageIds),
                  hub.messageIds.isSubset(of: removedOrDyingMessageIds) else {
                return nil
            }
            return email
        })
    }

    nonisolated static func deletionAnimationRemainingDuration(
        messageIds: Set<String>,
        dying: [DyingNodeSnapshot],
        dyingPeople: Set<String>,
        personSnapshots: [DyingPersonSnapshot],
        now: Date
    ) -> TimeInterval {
        let messageRemaining = dying
            .filter { messageIds.contains($0.star.messageId) }
            .map {
                max(0, messageDeathAnimationDuration(for: $0.lens) - now.timeIntervalSince($0.startedAt))
            }
            .max() ?? 0

        let normalizedPeople = Set(dyingPeople.map(PeopleRingMessageScope.normalizedEmail))
        let peopleRemaining = personSnapshots
            .filter {
                normalizedPeople.contains(PeopleRingMessageScope.normalizedEmail($0.hub.email))
            }
            .map {
                peopleDeathWormholePhase(startedAt: $0.startedAt).remainingDuration(at: now)
            }
            .max() ?? 0

        return max(messageRemaining, peopleRemaining)
    }

    nonisolated static func deletionReturnDelay(
        messageIds: Set<String>,
        dying: [DyingNodeSnapshot],
        dyingPeople: Set<String>,
        personSnapshots: [DyingPersonSnapshot],
        activeFrame: FrameKey,
        hasLivePersonFocus: Bool,
        now: Date
    ) -> TimeInterval {
        let animationRemaining = deletionAnimationRemainingDuration(
            messageIds: messageIds,
            dying: dying,
            dyingPeople: dyingPeople,
            personSnapshots: personSnapshots,
            now: now
        )
        guard animationRemaining > 0,
              activeFrame.spatialLens == .people,
              hasLivePersonFocus else {
            return animationRemaining
        }
        return animationRemaining + peopleFocusedDeletionReturnSettleDelay
    }

    nonisolated static func messageDeathAnimationDuration(for lens: FrameKey) -> TimeInterval {
        lens.spatialLens == .meaning ? meaningDeathAnimationDuration : deathAnimationDuration
    }

    nonisolated static func suppressesNoMessagesMeetFilterStatus(
        pendingDeletionReturn: PendingLockedDeletionReturn?,
        activeFrame: FrameKey,
        lockRevealSequence: Int,
        lockedVectorId: Int64?,
        livePersonEmail: String?
    ) -> Bool {
        guard isCurrentPendingLockedDeletionReturn(
                pendingDeletionReturn: pendingDeletionReturn,
                activeFrame: activeFrame,
                lockRevealSequence: lockRevealSequence,
                lockedVectorId: lockedVectorId
              ),
              let pendingDeletionReturn else {
            return false
        }
        guard activeFrame.spatialLens == .people,
              let pendingEmail = pendingDeletionReturn.personEmail else {
            return true
        }
        guard let livePersonEmail else { return false }
        let normalizedPendingEmail = PeopleRingMessageScope.normalizedEmail(pendingEmail)
        guard !normalizedPendingEmail.isEmpty,
              PeopleRingMessageScope.normalizedEmail(livePersonEmail) == normalizedPendingEmail else {
            return false
        }
        return true
    }

    nonisolated static func isCurrentPendingLockedDeletionReturn(
        pendingDeletionReturn: PendingLockedDeletionReturn?,
        activeFrame: FrameKey,
        lockRevealSequence: Int,
        lockedVectorId: Int64?
    ) -> Bool {
        guard let pendingDeletionReturn,
              suppressesNoMessagesMeetFilterStatusDuringDeletionReturn(frame: activeFrame),
              pendingDeletionReturn.frame.spatialLens == activeFrame.spatialLens,
              pendingDeletionReturn.sequence == lockRevealSequence,
              pendingDeletionReturn.lockedVectorId == lockedVectorId else {
            return false
        }
        return true
    }

    nonisolated static func suppressesNoMessagesMeetFilterStatusDuringDeletionReturn(frame: FrameKey) -> Bool {
        switch frame.spatialLens {
        case .meaning, .people:
            return true
        default:
            return false
        }
    }

    @MainActor
    private func finalDyingFocusedPersonEmails(
        currentDeletedMessageIds: Set<String>,
        alreadyDyingMessageIds: Set<String>,
        alreadyDyingPersonEmails: Set<String>
    ) -> Set<String> {
        guard !currentDeletedMessageIds.isEmpty else { return [] }
        let removedOrDyingMessageIds = currentDeletedMessageIds.union(alreadyDyingMessageIds)
        let normalizedAlreadyDyingPersonEmails = Set(
            alreadyDyingPersonEmails.map(PeopleRingMessageScope.normalizedEmail)
        )
        return Set(activePeopleFocuses().compactMap { personFocus in
            let email = PeopleRingMessageScope.normalizedEmail(personFocus.email)
            guard !email.isEmpty,
                  !normalizedAlreadyDyingPersonEmails.contains(email),
                  !personFocus.messageIds.isEmpty,
                  !personFocus.messageIds.isDisjoint(with: currentDeletedMessageIds),
                  personFocus.messageIds.isSubset(of: removedOrDyingMessageIds) else {
                return nil
            }
            return email
        })
    }

    @MainActor
    private func activePeopleFocuses() -> [LockedPersonFocus] {
        [liveLockPersonFocus].compactMap { $0 }
    }

    nonisolated static func fallbackDyingPersonSnapshot(
        for personFocus: LockedPersonFocus,
        now: Date
    ) -> DyingPersonSnapshot {
        let email = PeopleRingMessageScope.normalizedEmail(personFocus.email)
        let hubRadius = max(
            0.052,
            min(
                0.110,
                personFocus.outerRingEdgeRadius > 0 ? personFocus.outerRingEdgeRadius * 0.42 : 0.070
            )
        )
        let ringRadius = max(
            hubRadius + 0.030,
            personFocus.outerRingEdgeRadius > 0 ? personFocus.outerRingEdgeRadius : hubRadius + 0.060
        )
        let ringThickness: Float = 0.012
        let ringGeometry = PersonHubInstance.RingGeometry(
            tier: .receivedDirect,
            radius: ringRadius,
            thickness: ringThickness
        )
        let hubColor = AccountColorPalette.correspondentAccentRGB()
        let ringColor = AccountColorPalette.ringAccentRGB()
        let representativeMessageId = personFocus.messageIds.sorted().first
        let hub = PersonHubInstance(
            email: email,
            displayName: personFocus.displayName,
            position: personFocus.worldPosition,
            radius: hubRadius,
            sentCount: 0,
            receivedCount: max(1, personFocus.messageIds.count),
            reciprocalScore: 0,
            recencyScore: 1,
            isInstitutional: false,
            color: hubColor,
            representativeMessageId: representativeMessageId,
            representativeVectorId: nil,
            messageIds: personFocus.messageIds,
            focusGlow: 1,
            contextDim: 1,
            rings: [ringGeometry],
            ringNormal: personFocus.ringNormal
        )
        let ring = PersonRingInstance(
            email: email,
            center: personFocus.worldPosition,
            radius: ringRadius,
            thickness: ringThickness,
            normal: personFocus.ringNormal,
            color: ringColor,
            accountColor: hubColor,
            alpha: 1,
            tier: .receivedDirect,
            shimmer: true,
            radialGlow: true
        )
        return DyingPersonSnapshot(
            hub: hub,
            rings: [ring],
            startedAt: now
        )
    }

    @MainActor
    private func clearPeopleHoverIfDyingHubWasHovered(_ dyingEmails: Set<String>) {
        guard let hoveredPersonEmail else { return }
        let normalizedDyingEmails = Set(dyingEmails.map(PeopleRingMessageScope.normalizedEmail))
        guard normalizedDyingEmails.contains(PeopleRingMessageScope.normalizedEmail(hoveredPersonEmail)) else {
            return
        }
        self.hoveredPersonEmail = nil
        hoverNodePoint = .zero
    }

    @MainActor
    @discardableResult
    private func releasePeopleFocusIfDyingHubWasLocked(
        _ dyingEmails: Set<String>,
        deletedMessageIds: Set<String> = []
    ) -> Bool {
        guard !dyingEmails.isEmpty,
              state.activeFrame.spatialLens == .people else {
            return false
        }
        let dying = Set(dyingEmails.map(PeopleRingMessageScope.normalizedEmail))
        var releasedFocus = false
        if let personFocus = liveLockPersonFocus {
            let locked = PeopleRingMessageScope.normalizedEmail(personFocus.email)
            if dying.contains(locked) {
                releasedFocus = scheduleLockedDeletionReturnAfterAnimation(
                    messageIds: deletedMessageIds,
                    dyingPeople: dyingEmails,
                    lockedVectorId: state.lockedVectorId
                )
            }
        }
        return releasedFocus
    }

    struct PeopleFocusLockAnchor: Equatable, Sendable {
        let vectorId: Int64
        let messageId: String
    }

    /// A People correspondent lock borrows one ring email's vector as the
    /// shared locked-overlay identity. If that email is deleted while other
    /// ring messages survive, move the implementation anchor to a surviving
    /// ring email so the correspondent summary, hover dial, and Tab traversal
    /// remain mounted. The portrait's world/camera focus stays on the person.
    nonisolated static func survivingPeopleFocusLockAnchor(
        currentLockedVectorId: Int64?,
        removedVectorIds: Set<Int64>,
        focusedMessageIds: Set<String>,
        candidates: [PeopleFocusLockAnchor]
    ) -> PeopleFocusLockAnchor? {
        guard let currentLockedVectorId,
              removedVectorIds.contains(currentLockedVectorId),
              !focusedMessageIds.isEmpty else {
            return nil
        }
        return candidates
            .filter { candidate in
                candidate.vectorId > 0
                    && !removedVectorIds.contains(candidate.vectorId)
                    && focusedMessageIds.contains(candidate.messageId)
            }
            .sorted { lhs, rhs in
                if lhs.messageId != rhs.messageId {
                    return lhs.messageId < rhs.messageId
                }
                return lhs.vectorId < rhs.vectorId
            }
            .first
    }

    /// Visible records whose message is still in the scene index, as lock
    /// anchor candidates. One pass over the records against one index.
    nonisolated static func peopleFocusLockAnchorCandidates(
        records: some Sequence<VectorRecord>,
        messageIndex: [String: MessageFilterRow]
    ) -> [PeopleFocusLockAnchor] {
        records.compactMap { record in
            guard messageIndex[record.messageId] != nil else { return nil }
            return PeopleFocusLockAnchor(vectorId: record.vectorId, messageId: record.messageId)
        }
    }

    @MainActor
    @discardableResult
    private func reanchorSurvivingPeopleFocusIfNeeded(
        removedVectorIds: Set<Int64>,
        deletedMessageIds: Set<String>
    ) -> Bool {
        guard state.activeFrame.spatialLens == .people,
              let personFocus = liveLockPersonFocus,
              let currentLockedVectorId = state.lockedVectorId,
              removedVectorIds.contains(currentLockedVectorId) else {
            return false
        }

        let survivingMessageIds = peopleRingMessageIds(for: personFocus)
            .subtracting(deletedMessageIds)
        // `currentMessageIndex` filters the whole snapshot index on every
        // read; resolve it once for the candidate pass, not once per record.
        let messageIndex = currentMessageIndex
        let candidates = Self.peopleFocusLockAnchorCandidates(
            records: visibleRecordCache.values,
            messageIndex: messageIndex
        )
        guard let replacement = Self.survivingPeopleFocusLockAnchor(
            currentLockedVectorId: currentLockedVectorId,
            removedVectorIds: removedVectorIds,
            focusedMessageIds: survivingMessageIds,
            candidates: candidates
        ), let row = messageIndex[replacement.messageId] else {
            return false
        }

        state.lockedVectorId = replacement.vectorId
        if revealedLockedVectorId == currentLockedVectorId {
            revealedLockedVectorId = replacement.vectorId
        }
        if suppressedPendingLockIndicatorVectorId == currentLockedVectorId {
            suppressedPendingLockIndicatorVectorId = replacement.vectorId
        }
        lockEntryEnrichmentToken = LockEntryEnrichmentToken(
            vectorId: replacement.vectorId,
            sequence: lockRevealSequence
        )
        lockSummaryInFlightToken = nil
        relatedSummaryPrewarmTask?.cancel()
        relatedSummaryPrewarmTask = nil
        lockedNodeIDStorage = replacement.messageId
        lockedNodeClassificationStorage = effectiveClassification(
            messageId: replacement.messageId,
            fallbackRow: row
        ).flatMap { try? MailClassificationJSON.encode($0) } ?? ""
        lockedNodeCustomKeysStorage = (try? CustomCategoryKeysJSON.encode(
            effectiveCustomCategoryKeys(messageId: replacement.messageId, fallbackRow: row)
        )) ?? ""
        return true
    }

    @MainActor
    @discardableResult
    private func scheduleLockedDeletionReturnAfterAnimation(
        messageIds: Set<String>,
        dyingPeople: Set<String>,
        lockedVectorId expectedLockedVectorId: Int64? = nil
    ) -> Bool {
        guard state.lockedVectorId != nil || liveLockPersonFocus != nil else { return false }
        if let expectedLockedVectorId,
           state.lockedVectorId != expectedLockedVectorId {
            return false
        }

        let now = Date.now
        let delay = Self.deletionReturnDelay(
            messageIds: messageIds,
            dying: dyingSnapshots,
            dyingPeople: dyingPeople,
            personSnapshots: dyingPersonSnapshots,
            activeFrame: state.activeFrame,
            hasLivePersonFocus: liveLockPersonFocus != nil,
            now: now
        )
        let releaseSequence = lockRevealSequence
        let releaseFrame = state.activeFrame.spatialLens
        let releaseLockedVectorId = state.lockedVectorId
        let releasePersonEmail = liveLockPersonFocus.map {
            PeopleRingMessageScope.normalizedEmail($0.email)
        }

        let release = { @MainActor in
            let isDeletionReturn = Self.isCurrentPendingLockedDeletionReturn(
                pendingDeletionReturn: pendingLockedDeletionReturn,
                activeFrame: state.activeFrame,
                lockRevealSequence: lockRevealSequence,
                lockedVectorId: state.lockedVectorId
            )
            finishLiveMetalLockRelease(
                releaseTime: Date.now,
                restoreCamera: true,
                shouldRefreshExplorer: true,
                isDeletionReturn: isDeletionReturn
            )
        }

        guard delay > 0 else {
            release()
            return true
        }

        if Self.suppressesNoMessagesMeetFilterStatusDuringDeletionReturn(frame: state.activeFrame) {
            pendingLockedDeletionReturn = PendingLockedDeletionReturn(
                sequence: releaseSequence,
                frame: releaseFrame,
                lockedVectorId: releaseLockedVectorId,
                personEmail: releasePersonEmail
            )
        }

        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard lockRevealSequence == releaseSequence,
                  state.activeFrame.spatialLens == releaseFrame,
                  state.lockedVectorId == releaseLockedVectorId else {
                return
            }
            if let releasePersonEmail {
                let currentEmail = liveLockPersonFocus.map {
                    PeopleRingMessageScope.normalizedEmail($0.email)
                }
                guard currentEmail == releasePersonEmail else { return }
            }
            release()
        }
        return true
    }

    @MainActor
    private func dyingPersonSnapshot(for email: String?) -> DyingPersonSnapshot? {
        guard let email else { return nil }
        let normalizedEmail = PeopleRingMessageScope.normalizedEmail(email)
        return dyingPersonSnapshots.first {
            PeopleRingMessageScope.normalizedEmail($0.hub.email) == normalizedEmail
        }
    }

    @MainActor
    private func visibleMessageIds(forVectorIds vectorIds: Set<Int64>) -> Set<String> {
        guard !vectorIds.isEmpty else { return [] }
        var messageIds = Set<String>()
        for proxy in renderPacket.hitProxies where vectorIds.contains(proxy.vectorId) {
            messageIds.insert(proxy.messageId)
        }
        for id in vectorIds {
            if let messageId = visibleRecordCache[id]?.messageId {
                messageIds.insert(messageId)
            }
        }
        return messageIds
    }

    @MainActor
    private func captureBirthingNodes(
        from newPacket: ConstellationRenderPacket,
        observedMessageIds: Set<String>,
        now: Date,
        transition: ConstellationVisibilityTransition
    ) {
        let visibleMessageIds = Set(newPacket.stars.map(\.messageId))
        birthingSnapshots.removeAll { !visibleMessageIds.contains($0.messageId) }
        let enteringMessageIds = visibleNodeLifecycle.enteringMessageIds(
            nextVisibleMessageIds: visibleMessageIds,
            observedMessageIds: observedMessageIds,
            transition: transition,
            animatesInitialNonEmptyPacket: onboardingMode
        )
        guard !enteringMessageIds.isEmpty else { return }
        var scheduledBirthMessageIds = Set(birthingSnapshots.map(\.messageId))
        var queuedBirthMessageIds = scheduledBirthMessageIds
        let enteringStars = newPacket.stars
            .filter { enteringMessageIds.contains($0.messageId) }
            .sorted { lhs, rhs in
                if lhs.arrivalTime != rhs.arrivalTime { return lhs.arrivalTime < rhs.arrivalTime }
                return lhs.representativeVectorId < rhs.representativeVectorId
            }
            .filter { queuedBirthMessageIds.insert($0.messageId).inserted }
        let birthInterval = Self.birthStaggerInterval(
            enteringCount: enteringStars.count,
            transition: transition
        )

        for (offset, star) in enteringStars.enumerated() {
            guard scheduledBirthMessageIds.insert(star.messageId).inserted
            else { continue }
            birthingSnapshots.append(BirthingNodeSnapshot(
                messageId: star.messageId,
                startedAt: now.addingTimeInterval(Double(offset) * birthInterval)
            ))
        }
        if !birthingSnapshots.isEmpty {
            startAnimationTickerIfNeeded()
        }
    }

    private static func birthStaggerInterval(
        enteringCount: Int,
        transition: ConstellationVisibilityTransition
    ) -> TimeInterval {
        guard enteringCount > 1 else { return 0 }
        let maxSpan: TimeInterval
        let maxInterval: TimeInterval
        switch transition {
        case .continuous:
            maxSpan = 0.65
            maxInterval = 0.035
        case .filterChange:
            maxSpan = 2.4
            maxInterval = 0.055
        case .frameSwitch:
            return 0
        }
        return min(maxInterval, maxSpan / Double(max(1, enteringCount - 1)))
    }

    @MainActor
    private func startAnimationTickerIfNeeded() {
        guard animationTickerTask == nil else { return }
        guard !dyingSnapshots.isEmpty || !dyingPersonSnapshots.isEmpty || !birthingSnapshots.isEmpty else { return }
        animationTickerTask = Task { @MainActor in
            defer { animationTickerTask = nil }
            while !dyingSnapshots.isEmpty || !dyingPersonSnapshots.isEmpty || !birthingSnapshots.isEmpty {
                let now = Date.now
                dyingSnapshots.removeAll {
                    now.timeIntervalSince($0.startedAt) >= Self.messageDeathAnimationDuration(for: $0.lens)
                }
                pruneCompletedDyingPersonSnapshots(for: basePacket, now: now)
                birthingSnapshots.removeAll {
                    now.timeIntervalSince($0.startedAt) >= Self.birthAnimationDuration
                }
                renderPacket = Self.combinePacket(
                    base: basePacket,
                    dying: dyingSnapshots,
                    dyingPeople: dyingPersonSnapshots,
                    birthing: birthingSnapshots,
                    now: now
                )
                recordColdFirstPaintPacketIfNeeded()
                if dyingSnapshots.isEmpty && dyingPersonSnapshots.isEmpty && birthingSnapshots.isEmpty { break }
                try? await Task.sleep(for: Self.animationTickInterval)
            }
            let now = Date.now
            pruneCompletedDyingPersonSnapshots(for: basePacket, now: now)
            renderPacket = Self.combinePacket(
                base: basePacket,
                dying: dyingSnapshots,
                dyingPeople: dyingPersonSnapshots,
                birthing: birthingSnapshots,
                now: now
            )
            recordColdFirstPaintPacketIfNeeded()
        }
    }

    @MainActor
    private func pruneCompletedDyingPersonSnapshots(
        for packet: ConstellationRenderPacket,
        now: Date
    ) {
        guard !dyingPersonSnapshots.isEmpty else { return }
        let livePersonEmails = Set(packet.personHubs.map {
            PeopleRingMessageScope.normalizedEmail($0.email)
        })
        dyingPersonSnapshots.removeAll { snapshot in
            let elapsed = now.timeIntervalSince(snapshot.startedAt)
            guard elapsed >= Self.peopleDeathAnimationDuration else { return false }
            let email = PeopleRingMessageScope.normalizedEmail(snapshot.hub.email)
            let stillInBasePacket = livePersonEmails.contains(email)
            return !stillInBasePacket || elapsed >= Self.peopleDeathSuppressionMaxDuration
        }
    }

    /// Pure: builds a render packet that fuses the planner's latest output
    /// with any in-flight death-collapse snapshots and birth supernova
    /// snapshots. Death snapshots replace any duplicate base entries with
    /// the captured ghost (so the alive/dying don't render together for
    /// one frame); birth snapshots either hide future-staggered entries
    /// or patch `signal.birth` on visible base entries to drive the
    /// shader's supernova path.
    nonisolated static func combinePacket(
        base: ConstellationRenderPacket,
        dying: [DyingNodeSnapshot],
        dyingPeople: [DyingPersonSnapshot] = [],
        birthing: [BirthingNodeSnapshot],
        now: Date
    ) -> ConstellationRenderPacket {
        if dying.isEmpty && dyingPeople.isEmpty && birthing.isEmpty { return base }

        let dyingMessageIds = Set(dying.map(\.star.messageId))
        let dyingPersonEmails = Set(dyingPeople.map {
            PeopleRingMessageScope.normalizedEmail($0.hub.email)
        })
        let birthStartByMessageId = birthing.reduce(into: [String: Date]()) { starts, snapshot in
            guard let existing = starts[snapshot.messageId] else {
                starts[snapshot.messageId] = snapshot.startedAt
                return
            }
            if snapshot.startedAt < existing {
                starts[snapshot.messageId] = snapshot.startedAt
            }
        }
        let hiddenBirthMessageIds = Set(birthStartByMessageId.compactMap { messageId, startedAt in
            now < startedAt ? messageId : nil
        })
        let suppressedMessageIds = dyingMessageIds.union(hiddenBirthMessageIds)
        var stars = base.stars.filter { suppressedMessageIds.contains($0.messageId) == false }
        var satellites = base.satellites.filter {
            suppressedMessageIds.contains($0.parentMessageId) == false
        }
        var personHubs = base.personHubs.filter {
            dyingPersonEmails.contains(PeopleRingMessageScope.normalizedEmail($0.email)) == false
        }
        var personRings = base.personRings.filter {
            dyingPersonEmails.contains(PeopleRingMessageScope.normalizedEmail($0.email)) == false
        }
        let personRelations = base.personRelations.filter {
            dyingPersonEmails.contains(PeopleRingMessageScope.normalizedEmail($0.sourceEmail)) == false
                && dyingPersonEmails.contains(PeopleRingMessageScope.normalizedEmail($0.targetEmail)) == false
        }
        let personHitProxies = base.personHitProxies.filter {
            dyingPersonEmails.contains(PeopleRingMessageScope.normalizedEmail($0.email)) == false
        }
        let personAtoms = base.personAtoms.filter {
            dyingPersonEmails.contains(PeopleRingMessageScope.normalizedEmail($0.hubEmail)) == false
                && suppressedMessageIds.contains($0.parentMessageId) == false
        }

        // Apply birth progress to surviving base stars/satellites.
        if !birthing.isEmpty {
            let birthProgressByMessageId: [String: Float] = Dictionary(
                uniqueKeysWithValues: birthStartByMessageId.compactMap { messageId, startedAt in
                    let elapsed = now.timeIntervalSince(startedAt)
                    guard elapsed >= 0 else { return nil }
                    // Clamp into (0, 1) — exactly 0 means "settled" to the
                    // shader, so we never hit that boundary while in flight.
                    let progress = Float(max(0.0001, min(0.9999, elapsed / birthAnimationDuration)))
                    return (messageId, progress)
                }
            )
            stars = stars.map { star in
                guard let progress = birthProgressByMessageId[star.messageId] else { return star }
                var s = star.signal
                s.birth = progress
                return star.withSignal(s)
            }
            satellites = satellites.map { sat in
                guard let progress = birthProgressByMessageId[sat.parentMessageId] else { return sat }
                var s = sat.signal
                s.birth = progress
                return MessageSatelliteInstance(
                    vectorId: sat.vectorId,
                    parentMessageId: sat.parentMessageId,
                    position: sat.position,
                    color: sat.color,
                    radius: sat.radius,
                    signal: s
                )
            }
        }

        // Append dying People hubs/rings with deletion progress baked in.
        if !dyingPeople.isEmpty {
            personHubs.reserveCapacity(personHubs.count + dyingPeople.count)
            personRings.reserveCapacity(personRings.count + dyingPeople.reduce(0) { $0 + $1.rings.count })
            for snapshot in dyingPeople {
                let sample = peopleDeathWormholePhase(startedAt: snapshot.startedAt).at(now)
                guard !sample.isComplete else { continue }
                personHubs.append(dyingPersonHub(snapshot.hub, sample: sample))
                personRings.append(contentsOf: snapshot.rings.map {
                    dyingPersonRing($0, sample: sample)
                })
            }
        }

        // Append dying ghosts with deletion progress baked in.
        stars.reserveCapacity(stars.count + dying.count)
        for snapshot in dying {
            let elapsed = now.timeIntervalSince(snapshot.startedAt)
            let duration = messageDeathAnimationDuration(for: snapshot.lens)
            // Clamp into (0, 1] — exactly 0 means "live" to the renderer's
            // pick aligner. Ghosts have no hit proxies (filtered above), so
            // the aligner excludes deletion-marked instances from proxy
            // pairing; a first-frame ghost at elapsed 0 must already carry
            // the marker or satellite proxies pair against ghost stars for
            // that frame (wrong pick radius/lane). Mirrors the birth clamp.
            let progress = Float(max(0.0001, min(1, elapsed / duration)))
            var starSignal = snapshot.star.signal
            starSignal.deletion = progress
            stars.append(dyingMessageStar(snapshot.star, signal: starSignal, lens: snapshot.lens))
            for sat in snapshot.satellites {
                var satSignal = sat.signal
                satSignal.deletion = progress
                satellites.append(MessageSatelliteInstance(
                    vectorId: sat.vectorId,
                    parentMessageId: sat.parentMessageId,
                    position: sat.position,
                    color: sat.color,
                    radius: sat.radius,
                    signal: satSignal
                ))
            }
        }

        return ConstellationRenderPacket(
            stars: stars,
            satellites: satellites,
            nebulae: base.nebulae,
            semanticDensityFields: base.semanticDensityFields,
            fibers: base.fibers.filter {
                suppressedMessageIds.contains($0.sourceMessageId) == false
                    && suppressedMessageIds.contains($0.targetMessageId) == false
            },
            // Hit proxies intentionally omit hidden birth entries and dying
            // ghosts. Future-staggered nodes are not on-screen yet, and
            // deleting nodes may already point at SwiftData rows that have
            // been torn down. Dying person hubs drop their "person:<email>"
            // proxies for the same reason: a collapsing hub must not stay
            // hover/clickable, or the click opens a correspondent lock over
            // messages that were just deleted.
            hitProxies: base.hitProxies.filter { proxy in
                if suppressedMessageIds.contains(proxy.messageId) { return false }
                if dyingPersonEmails.isEmpty == false,
                   proxy.messageId.hasPrefix(personProxyMessagePrefix) {
                    let email = PeopleRingMessageScope.normalizedEmail(
                        String(proxy.messageId.dropFirst(personProxyMessagePrefix.count))
                    )
                    return dyingPersonEmails.contains(email) == false
                }
                return true
            },
            budget: base.budget,
            totalMessageCount: base.totalMessageCount,
            totalVectorCount: base.totalVectorCount,
            fieldDimFactor: base.fieldDimFactor,
            // Bump generatedAt so `ConstellationMetalView.Coordinator.install`
            // re-uploads the buffer this tick.
            generatedAt: Date.now.timeIntervalSince1970,
            // Carry the frame-aware payloads through every animation tick.
            // Without this, in-flight births/deaths would replace the packet
            // with one whose `visualLanguage` defaults to `.meaning`, losing
            // any compatibility arc-label payload the planner provided.
            visualLanguage: base.visualLanguage,
            arcLabels: base.arcLabels,
            personHubs: personHubs,
            personRelations: personRelations,
            personHitProxies: personHitProxies,
            meaningClusterHubs: base.meaningClusterHubs,
            meaningClusterVisibility: base.meaningClusterVisibility,
            personRings: personRings,
            personAtoms: personAtoms,
            renderHubsAsPlanets: base.renderHubsAsPlanets,
            // The solar system must survive every birth/death animation
            // tick — dropping the sun here would collapse the People
            // layout to a sunless field mid-animation.
            personSun: base.personSun,
            personOrbitPathColor: base.personOrbitPathColor
        )
    }

    nonisolated private static func dyingMessageStar(
        _ star: MessageStarInstance,
        signal: VisualSignalState,
        lens: FrameKey
    ) -> MessageStarInstance {
        MessageStarInstance(
            messageId: star.messageId,
            representativeVectorId: star.representativeVectorId,
            position: star.position,
            color: star.color,
            radius: star.radius,
            vectorCount: star.vectorCount,
            evidenceWeight: star.evidenceWeight,
            arrivalTime: star.arrivalTime,
            lastMoveMagnitude: eventHorizonExpansionBoost(for: lens),
            signal: signal,
            glyphCode: star.glyphCode,
            emergeMask: star.emergeMask,
            defaultCorrespondentTint: star.defaultCorrespondentTint,
            fadesWithPeopleContext: star.fadesWithPeopleContext,
            peopleHubEmail: star.peopleHubEmail
        )
    }

    nonisolated private static func eventHorizonExpansionBoost(for lens: FrameKey) -> Float {
        lens.spatialLens == .meaning ? meaningEventHorizonExpansionBoost : 0
    }

    nonisolated private static func dyingPersonHub(
        _ hub: PersonHubInstance,
        sample: WormholePhase.Sample
    ) -> PersonHubInstance {
        let progress = Float(sample.progress)
        let scale = peopleDeathWormholeScale(sample: sample)
            * peopleDeathWormholeVisualLift(sample: sample)
        let rings = hub.rings.map { ring in
            PersonHubInstance.RingGeometry(
                tier: ring.tier,
                radius: ring.radius * scale,
                thickness: max(0.0001, ring.thickness * scale)
            )
        }
        return PersonHubInstance(
            email: hub.email,
            displayName: hub.displayName,
            position: hub.position,
            radius: max(0.001, hub.radius * scale),
            sentCount: hub.sentCount,
            receivedCount: hub.receivedCount,
            appearanceCount: hub.appearanceCount,
            reciprocalScore: hub.reciprocalScore,
            recencyScore: hub.recencyScore,
            isInstitutional: hub.isInstitutional,
            color: hub.color,
            representativeMessageId: hub.representativeMessageId,
            representativeVectorId: hub.representativeVectorId,
            messageIds: hub.messageIds,
            focusGlow: hub.focusGlow,
            contextDim: hub.contextDim,
            deletionProgress: progress,
            rings: rings,
            ringNormal: hub.ringNormal
        )
    }

    nonisolated private static func dyingPersonRing(
        _ ring: PersonRingInstance,
        sample: WormholePhase.Sample
    ) -> PersonRingInstance {
        let progress = Float(sample.progress)
        let scale = peopleDeathWormholeScale(sample: sample)
            * peopleDeathWormholeVisualLift(sample: sample)
        let fade = 1 - smoothStep(edge0: 0.70, edge1: 1.0, x: progress)
        return PersonRingInstance(
            email: ring.email,
            center: ring.center,
            radius: max(0.0001, ring.radius * scale),
            thickness: max(0.0001, ring.thickness * scale),
            normal: ring.normal,
            color: ring.color,
            accountColor: ring.accountColor,
            alpha: ring.alpha * fade,
            tier: ring.tier,
            shimmer: true,
            radialGlow: true,
            arcStartFraction: ring.arcStartFraction,
            arcEndFraction: ring.arcEndFraction,
            fadesWithPeopleContext: ring.fadesWithPeopleContext,
            deletionProgress: progress
        )
    }

    nonisolated static func peopleDeathWormholePhase(startedAt: Date) -> WormholePhase {
        WormholePhase(
            startedAt: startedAt,
            direction: .closing,
            duration: peopleDeathAnimationDuration
        )
    }

    nonisolated private static func peopleDeathWormholeScale(sample: WormholePhase.Sample) -> Float {
        let popupScale = Float(sample.popupScale)
        let opacity = Float(sample.popupOpacity)
        let retraction = Float(sample.paneTowardAnchor)
        let suctionScale = max(0.012, 1 - 0.94 * retraction)
        let dematerializedScale = max(0.018, opacity)
        return max(0.006, min(1, popupScale * suctionScale * dematerializedScale))
    }

    nonisolated private static func peopleDeathWormholeVisualLift(sample: WormholePhase.Sample) -> Float {
        1 + Float(sample.vortexOpacity) * peopleDeathWormholeBodyLift
    }

    nonisolated private static func smoothStep(edge0: Float, edge1: Float, x: Float) -> Float {
        guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private static let sidebarSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    private static let focusClickAcknowledgementDelay = OhiaAnimationCadence.frameDuration
    private static let lockEnrichmentSettleDuration = Duration.milliseconds(180)
    private static let lockSummaryStartDelay = Duration.milliseconds(80)
    private static let peopleFocusExitHandoffGeneratedAtOffset: TimeInterval = 0.000_101
    private static let peopleLiveLODGeneratedAtOffset: TimeInterval = 0.000_202
    private static let peopleLiveLODHubTrigger = 240
    private static let peopleLiveLODStarTrigger = 900
    private static let peopleLiveLODCPUFrameMilliseconds: Double = 22
    private static let peopleLiveLODUploadMilliseconds: Double = 10
    private static let peopleLiveLODCameraDistance: Float = 2.35
    private static let peopleLiveFocusReframeDistanceThreshold: Float = 0.015
    private static let cameraReplanIdleDelay: TimeInterval = 0.28
    private static let tabKeyCode: UInt16 = 0x30
    private static let returnKeyCode: UInt16 = 0x24
    private static let keypadEnterKeyCode: UInt16 = 0x4C
    private static let gKeyCode: UInt16 = 0x05
    private static let deleteKeyCode: UInt16 = 0x33  // ⌫ Backspace
    private static let leftArrowKeyCode: UInt16 = 0x7B
    private static let rightArrowKeyCode: UInt16 = 0x7C
    private static let timelineSearchWarpViewportSpan: TimeInterval = 14 * 86_400
    nonisolated private static let personProxyMessagePrefix = "person:"
    private static let meaningClusterProxyMessagePrefix = MeaningClusterHubInstance.hitProxyMessageIdPrefix
    private static let lockFocusCameraFill: Float = 0.60
    private static let lockFocusCameraMinDistance: Float = 0.34
    private static let lockFocusCameraPadding: Float = 0.12
    private static let lockFocusCameraOutlierTrimFraction: Float = 0.10
    private static let minSidebarWidth: CGFloat = 380
    private static let legacyDefaultSidebarWidth: CGFloat = 380
    private static let maxSidebarWidth: CGFloat = 640
    private static let sidebarDividerThickness: CGFloat = 10
    /// Resize bounds for the Withheld drawer. The minimum
    /// and default both match the Search/Ask sidebar (minSidebarWidth = 380 and the
    /// constellationWithheldWidth default = 380) so both panels open at the same
    /// size and share the same floor. The ceiling stops it from swallowing the scene.
    private static let withheldMinWidth: Double = 380
    private static let withheldMaxWidth: Double = 820
    private static let onboardingCameraScreenPadding: Float = 1.05
    private static let onboardingCameraDepthScale: Float = 0.55
    private static let onboardingCameraDepthPadding: Float = 0.22
    private static let onboardingCameraMinDistance: Float = 0.34
    private static let onboardingCameraMaxDistance: Float = 0.95

    private static let onboardingEmptyCameraState = CameraState(
        position: SIMD3<Float>(0, 0, 0.62),
        velocity: .zero,
        yaw: 0,
        pitch: 0,
        yawRate: 0,
        pitchRate: 0,
        roll: 0,
        rollRate: 0
    )

    private static func bounds(for positions: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var minP = positions.first, var maxP = positions.first else {
            return nil
        }

        for position in positions.dropFirst() {
            minP = SIMD3<Float>(
                Swift.min(minP.x, position.x),
                Swift.min(minP.y, position.y),
                Swift.min(minP.z, position.z)
            )
            maxP = SIMD3<Float>(
                Swift.max(maxP.x, position.x),
                Swift.max(maxP.y, position.y),
                Swift.max(maxP.z, position.z)
            )
        }
        return (minP, maxP)
    }

    private static func onboardingCameraState(for positions: [SIMD3<Float>]) -> CameraState? {
        guard let bounds = bounds(for: positions) else { return nil }
        let minP = bounds.min
        let maxP = bounds.max
        let center = (minP + maxP) * 0.5
        let span = maxP - minP
        let halfScreenSpan = max(span.x, span.y) * 0.5
        let tanHalfVerticalFOV: Float = 0.57735026
        let screenDistance = (halfScreenSpan / tanHalfVerticalFOV) * onboardingCameraScreenPadding
        let depthClearance = span.z * onboardingCameraDepthScale + onboardingCameraDepthPadding
        let distance = min(
            max(screenDistance, depthClearance, onboardingCameraMinDistance),
            onboardingCameraMaxDistance
        )

        return CameraState(
            position: SIMD3<Float>(center.x, center.y, center.z + distance),
            velocity: .zero,
            yaw: 0,
            pitch: 0,
            yawRate: 0,
            pitchRate: 0,
            roll: 0,
            rollRate: 0
        )
    }
}

enum WithheldRestoreRoutingPolicy {
    static func canAttemptRemotePromotion(_ row: WithheldRow) -> Bool {
        let hasProviderCoordinates = !row.folderPath.isEmpty
            && row.uid > 0
            && row.uidValidity > 0
        return hasProviderCoordinates || canonicalProviderMessageID(row.messageId) != nil
    }
}

enum ConstellationHitKind: Equatable {
    case personHub
    case meaningClusterHub
    case messageNode
}

enum ConstellationClickRoute: Equatable {
    case personHubLock
    case meaningClusterFilter
    case messageLock
    case ignore
}

enum AskCitationLensRoute: Equatable {
    case metalMessageFocus
    case timelineWorkspace
    case projectsWorkspace
    case frontPageWorkspace
}

enum StarburstLensRoute: Equatable {
    case metalMessageFocus
    case timelineWorkspace
    case projectsWorkspace
    case frontPageWorkspace
}

enum StarburstLensRoutingPolicy {
    static func route(activeFrame: FrameKey) -> StarburstLensRoute {
        switch activeFrame.spatialLens {
        case .timeline:
            return .timelineWorkspace
        case .projects:
            return .projectsWorkspace
        case .frontPage:
            return .frontPageWorkspace
        default:
            return .metalMessageFocus
        }
    }
}

enum StarburstClickIntent: Equatable {
    case navigateToArrival(messageId: String)
    case acknowledgeSearch
    case manualRefresh
}

enum StarburstClickIntentPolicy {
    static func resolve(
        unvisitedArrivalIdsInOldestFirstOrder: [String],
        isSearching: Bool,
        hasFailure: Bool = false
    ) -> StarburstClickIntent {
        if hasFailure {
            return .manualRefresh
        }
        if let messageId = unvisitedArrivalIdsInOldestFirstOrder.first {
            return .navigateToArrival(messageId: messageId)
        }
        return isSearching ? .acknowledgeSearch : .manualRefresh
    }
}

enum StarburstArrivalOrderingPolicy {
    static func oldestFirst(
        unvisitedArrivalIds: [String],
        receivedAtByMessageId: [String: Date]
    ) -> [String] {
        let ledgerRank = Dictionary(
            uniqueKeysWithValues: unvisitedArrivalIds.enumerated().map { ($0.element, $0.offset) }
        )
        return unvisitedArrivalIds.sorted { lhs, rhs in
            let leftDate = receivedAtByMessageId[lhs] ?? .distantFuture
            let rightDate = receivedAtByMessageId[rhs] ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
            return ledgerRank[lhs, default: 0] < ledgerRank[rhs, default: 0]
        }
    }
}

enum StarburstFocusSupersessionPolicy {
    static func mayQueueFocus(
        hasPendingFocus: Bool,
        isDirectBeaconClick: Bool
    ) -> Bool {
        isDirectBeaconClick || hasPendingFocus == false
    }
}

enum StarburstMetalFocusCompletionDisposition: Equatable {
    case consumeBadge
    case retryAfterRefresh
    case retainBadge
}

enum StarburstMetalFocusCompletionPolicy {
    static func disposition(
        for result: SelectedNodeFocusCommitResult,
        hasRetriedAfterRefresh: Bool
    ) -> StarburstMetalFocusCompletionDisposition {
        switch result {
        case .committed:
            return .consumeBadge
        case .unavailable:
            return hasRetriedAfterRefresh ? .retainBadge : .retryAfterRefresh
        case .superseded:
            return .retainBadge
        }
    }
}

enum StarburstPeopleFocusSelectionPolicy {
    static func initialSelectionMessageId(
        activeFrame: FrameKey,
        hasCorrespondentFocus: Bool,
        arrivalMessageId: String
    ) -> String? {
        guard activeFrame.spatialLens == .people,
              hasCorrespondentFocus else {
            return nil
        }
        return arrivalMessageId
    }
}

enum AskCitationLensRoutingPolicy {
    static func route(activeFrame: FrameKey) -> AskCitationLensRoute {
        switch activeFrame.spatialLens {
        case .timeline:
            return .timelineWorkspace
        case .projects:
            return .projectsWorkspace
        case .frontPage:
            return .frontPageWorkspace
        default:
            return .metalMessageFocus
        }
    }
}

enum ConstellationClickRoutingPolicy {
    static func hitKind(
        isPersonHub: Bool,
        isMeaningClusterHub: Bool
    ) -> ConstellationHitKind {
        if isPersonHub { return .personHub }
        if isMeaningClusterHub { return .meaningClusterHub }
        return .messageNode
    }

    static func route(
        activeFrame: FrameKey,
        renderPacketFrame: FrameKey,
        hitKind: ConstellationHitKind
    ) -> ConstellationClickRoute {
        guard activeFrame.spatialLens == renderPacketFrame.spatialLens else {
            return .ignore
        }

        switch activeFrame.spatialLens {
        case .people:
            return hitKind == .personHub ? .personHubLock : .ignore
        case .meaning:
            switch hitKind {
            case .meaningClusterHub:
                return .meaningClusterFilter
            case .messageNode:
                return .messageLock
            case .personHub:
                return .ignore
            }
        case .timeline, .projects:
            return .ignore
        default:
            return hitKind == .messageNode ? .messageLock : .ignore
        }
    }
}

enum PeopleConstellationHoverPolicy {
    static func shouldShowEmailHover(
        activeFrame: FrameKey,
        lockedVectorId: Int64?,
        hasLivePersonFocus: Bool
    ) -> Bool {
        guard activeFrame.spatialLens == .people else {
            return true
        }
        return lockedVectorId != nil || hasLivePersonFocus
    }
}

enum FrameRenderProgressAction: Equatable {
    case begin
    case clear
}

enum ConstellationFrameSwitchPolicy {
    static func frameRenderProgressAction(
        for nextFrame: FrameKey,
        hasRetainedSurface: Bool = false
    ) -> FrameRenderProgressAction {
        ConstellationModeView.usesMetalScene(nextFrame) && !hasRetainedSurface ? .begin : .clear
    }

    static func shouldClearLiveMetalLock(
        from activeFrame: FrameKey,
        to nextFrame: FrameKey,
        lockedVectorId: Int64?,
        hasLivePersonFocus: Bool
    ) -> Bool {
        guard activeFrame.spatialLens != nextFrame.spatialLens else {
            return false
        }
        switch activeFrame.spatialLens {
        case .people:
            return lockedVectorId != nil || hasLivePersonFocus
        case .meaning:
            return lockedVectorId != nil
        default:
            return false
        }
    }
}

enum PeopleFocusExitHandoffPolicy {
    static func shouldPublishSourcePacket(
        activeFrame: FrameKey,
        sourceFrame: FrameKey,
        sourceFilter: VectorFilter?,
        currentFilter: VectorFilter,
        isDeletionReturn: Bool = false
    ) -> Bool {
        guard !isDeletionReturn,
              activeFrame.spatialLens == .people,
              sourceFrame.spatialLens == .people,
              let sourceFilter else {
            return false
        }
        return sourceFilter == currentFilter
    }
}

enum LiveMetalFocusTransitionPolicy {
    nonisolated static let maximumSourceWarpPhase: Float = 0.42

    /// The live-lock source warp is a pure field-dim ramp —
    /// frame-agnostic, so every lens that runs a live
    /// lock animates its dim through it. The only requirement is that the
    /// effect was created for the lens that is still active; a lens switch
    /// mid-flight drops the effect rather than dimming the wrong scene.
    static func usesSourceWarp(
        activeFrame: FrameKey,
        effectFrame: FrameKey
    ) -> Bool {
        activeFrame.spatialLens == effectFrame.spatialLens
    }

    static func sourceWarpDuration(
        totalDuration: TimeInterval,
        endProgress: Float
    ) -> TimeInterval {
        let clampedProgress = min(max(endProgress, 0.05), 1)
        return max(0.18, totalDuration * Double(clampedProgress))
    }

    static func sourceWarpSafetyTimeout(rampDuration: TimeInterval) -> TimeInterval {
        max(3.0, rampDuration + 2.0)
    }

    static func sourceWarpPhase(progress: Float) -> Float {
        maximumSourceWarpPhase * smootherStep(min(max(progress, 0), 1))
    }

    static func fieldDimPhase(progress: Float) -> Float {
        smootherStep(min(max(progress, 0), 1))
    }

    static func packetContainsFocusedLock(
        _ packet: ConstellationRenderPacket,
        vectorId: Int64,
        messageId: String?
    ) -> Bool {
        focusedLockWorldPosition(packet, vectorId: vectorId, messageId: messageId) != nil
    }

    static func focusedLockWorldPosition(
        _ packet: ConstellationRenderPacket,
        vectorId: Int64,
        messageId: String?
    ) -> SIMD3<Float>? {
        if let messageId,
           let messageStar = packet.stars.first(where: { star in
               star.signal.lockFocus > 0 && star.messageId == messageId
           }) {
            return messageStar.position
        }
        if let vectorStar = packet.stars.first(where: { star in
            guard star.signal.lockFocus > 0 else { return false }
            return star.representativeVectorId == vectorId
        }) {
            return vectorStar.position
        }
        if let vectorSatellite = packet.satellites.first(where: { satellite in
            guard satellite.signal.lockFocus > 0 else { return false }
            return satellite.vectorId == vectorId
        }) {
            return vectorSatellite.position
        }
        if let messageId,
           let messageSatellite = packet.satellites.first(where: { satellite in
               satellite.signal.lockFocus > 0 && satellite.parentMessageId == messageId
           }) {
            return messageSatellite.position
        }
        return nil
    }

    private static func smootherStep(_ value: Float) -> Float {
        let x = min(max(value, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}

enum PeopleLiveFocusTransitionPolicy {
    nonisolated static let sceneContractionProgress: Float = 0.04
    nonisolated static let backgroundDimStartProgress: Float = sceneContractionProgress
    nonisolated static let backgroundDimCompleteProgress: Float = 0.94
    nonisolated static let entryPortraitStandoffScale: Float = 0.88
    /// Post-install context recede for a People email-node lock. The
    /// correspondent portrait derives its ramp from the warp duration;
    /// the email lock reveals at arrival, so it uses this fixed short
    /// ramp instead.
    nonisolated static let emailLockDimRampDuration: TimeInterval = 0.45

    static func entryPortraitStandoff(systemStandoff: Float) -> Float {
        max(0.01, systemStandoff * entryPortraitStandoffScale)
    }

    static func backgroundDimRampDuration(totalWarpDuration: TimeInterval) -> TimeInterval {
        let span = max(0.05, Double(backgroundDimCompleteProgress - backgroundDimStartProgress))
        return max(0.30, min(1.10, totalWarpDuration * span))
    }

    static func backgroundContextDimPhase(rampProgress: Float) -> Float {
        smootherStep(rampProgress)
    }

    static func backgroundContextDimExitPhase(progress: Float) -> Float {
        1 - smootherStep(progress)
    }

    /// Exit reversal anchored at the phase the entry recede actually
    /// reached. A release that lands mid-entry-ramp (rapid lock/unlock)
    /// starts the fade-back from `startPhase`, not from fully receded —
    /// otherwise the background snaps to its darkest for one frame before
    /// fading back in.
    static func backgroundContextDimExitPhase(progress: Float, startPhase: Float) -> Float {
        min(max(startPhase, 0), 1) * (1 - smootherStep(progress))
    }

    static func backgroundContextRingVisibility(dimPhase: Float) -> Float {
        1 - min(max(dimPhase, 0), 1)
    }

    static func backgroundContextDimPhase(progress: Float) -> Float {
        let span = max(0.001, backgroundDimCompleteProgress - backgroundDimStartProgress)
        let normalized = (progress - backgroundDimStartProgress) / span
        return smootherStep(normalized)
    }

    static func exitRestoreCamera(
        defaultCamera: CameraState?,
        currentCamera: CameraState
    ) -> CameraState {
        defaultCamera ?? currentCamera
    }

    static func packetContainsFocusedCorrespondent(
        _ packet: ConstellationRenderPacket,
        email: String
    ) -> Bool {
        let normalized = normalizedEmail(email)
        guard !normalized.isEmpty else { return false }
        return packet.personHubs.contains { hub in
            normalizedEmail(hub.email) == normalized && hub.focusGlow > 0
        }
    }

    private static func normalizedEmail(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("mailto:") {
            trimmed.removeFirst("mailto:".count)
        }
        return trimmed
    }

    private static func smootherStep(_ value: Float) -> Float {
        let x = min(max(value, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}

enum PeopleLiveFocusReframePolicy {
    static func shouldReframe(
        activeFrame: FrameKey,
        renderPacketFrame: FrameKey,
        lockedVectorId: Int64?,
        hasLivePersonFocus: Bool,
        renderPacketFilter: VectorFilter?,
        currentFilter: VectorFilter
    ) -> Bool {
        guard activeFrame.spatialLens == .people,
              renderPacketFrame.spatialLens == .people,
              lockedVectorId != nil,
              hasLivePersonFocus,
              let renderPacketFilter else {
            return false
        }
        return renderPacketFilter == currentFilter
    }
}

enum PeoplePortraitCameraPolicy {
    private static let halfVerticalFOV: Float = 0.5236
    private static let fillFraction: Float = 0.45
    private static let minimumStandoff: Float = 0.06
    /// Floor on the hub radius feeding the extent floors below, in SOLAR
    /// world units: the pre-solar 0.042 body floor scaled by the same
    /// `solarScale` the builder applies to every planet and ring radius.
    /// Left unscaled it exceeded every solar planet's radius (~0.013 to
    /// 0.033), so all portrait floors collapsed to one big-system
    /// constant and low-volume correspondents (tiny planet, one thin
    /// ring) were framed roughly 10× too far away — an unlabeled dot.
    private static let minimumHubRadius: Float = 0.042 * PeopleGraphBuilder.solarScale
    private static let minimumFilteredSystemRadiusMultiplier: Float = 3.5
    private static let emptyRingSystemRadiusMultiplier: Float = 6.0

    static func systemExtent(
        hubRadius: Float,
        ringOuterEdges: [Float]
    ) -> Float {
        let resolvedHubRadius = max(hubRadius.isFinite ? hubRadius : 0, minimumHubRadius)
        let measuredRingExtent = ringOuterEdges
            .filter { $0.isFinite && $0 > 0 }
            .max()
        let fallbackRingExtent = resolvedHubRadius * emptyRingSystemRadiusMultiplier
        let filterStableFloor = resolvedHubRadius * minimumFilteredSystemRadiusMultiplier
        return max(measuredRingExtent ?? fallbackRingExtent, filterStableFloor)
    }

    static func standoffDistance(systemExtent: Float) -> Float {
        let extent = max(0, systemExtent.isFinite ? systemExtent : 0)
        return max(minimumStandoff, extent / tanf(halfVerticalFOV * fillFraction))
    }

    /// Camera→portrait axis: the ring-plane normal, hemisphere-corrected
    /// so the camera settles on its own side of the plane instead of
    /// flying through the rings. Falls back to the bearing from the
    /// current camera when no usable normal is known, and to world +Z
    /// when the camera sits on the center itself. Every People portrait
    /// framing (lock entry, in-lock reframe, recenter, node locks)
    /// routes through this axis so the composition never depends on
    /// where in the solar system the body happens to sit.
    static func portraitApproachAxis(
        ringNormal: SIMD3<Float>?,
        cameraPosition: SIMD3<Float>,
        center: SIMD3<Float>
    ) -> SIMD3<Float> {
        let toCamera = cameraPosition - center
        if let ringNormal, simd_length(ringNormal) > 0.0001 {
            let normal = simd_normalize(ringNormal)
            return simd_dot(normal, toCamera) < 0 ? -normal : normal
        }
        if simd_length(toCamera) > 0.0001 {
            return simd_normalize(toCamera)
        }
        return SIMD3<Float>(0, 0, 1)
    }

    static func frontFacingCameraState(
        center: SIMD3<Float>,
        ringNormal: SIMD3<Float>,
        standoff: Float,
        cameraPosition: SIMD3<Float>
    ) -> CameraState {
        let resolvedNormal = portraitApproachAxis(
            ringNormal: ringNormal,
            cameraPosition: cameraPosition,
            center: center
        )
        let distance = max(minimumStandoff, standoff.isFinite ? standoff : minimumStandoff)
        let position = center + resolvedNormal * distance
        let direction = simd_normalize(center - position)
        return CameraState(
            position: position,
            velocity: .zero,
            yaw: atan2(-direction.x, -direction.z),
            pitch: asin(direction.y),
            yawRate: 0,
            pitchRate: 0,
            roll: 0,
            rollRate: 0
        )
    }
}

/// Gates the 70pt window-edge control column. The column is a LAYOUT
/// SIBLING of the Metal scene, so every mount/unmount resizes the scene's
/// viewport and shifts every rendered node sideways — the gate must
/// therefore hold the column steady across transient states (lock
/// entry/exit flight, filter loading, empty results, Meaning click-resolve),
/// not just settled ones.
enum ConstellationEdgeColumnPolicy {
    /// People correspondent locks keep the close column mounted for the
    /// ENTIRE lock lifecycle — click, flight, settled portrait, and exit
    /// pullback. Unmounting it between click and reveal (and again during
    /// the pullback) resized the viewport by 70pt four times per lock.
    /// Email-node locks (`hasLivePersonFocus == false`) keep the default
    /// lens behavior.
    static func peopleLockColumnActive(
        activeLens: FrameKey,
        lockedVectorId: Int64?,
        hasLivePersonFocus: Bool
    ) -> Bool {
        activeLens.spatialLens == .people
            && lockedVectorId != nil
            && hasLivePersonFocus
    }

    /// A selected ring email supplies its own complete action group, including
    /// Compose when eligible. Keep the standalone locked-email Compose disc only
    /// while that group is absent so the rail never presents duplicate actions.
    static func showsStandalonePeopleComposeDisc(
        hasRingSelectionActions: Bool
    ) -> Bool {
        hasRingSelectionActions == false
    }

    static func showsColumn(
        activeLens: FrameKey,
        isOnboarding: Bool,
        lensSurfaceStatus _: ConstellationLensSurfaceStatus?,
        peopleLockColumnActive: Bool,
        hasActiveWorkspace: Bool,
        lockedVectorId: Int64?
    ) -> Bool {
        guard !isOnboarding else { return false }
        if peopleLockColumnActive { return true }

        switch activeLens.spatialLens {
        case .frontPage, .timeline, .projects:
            return hasActiveWorkspace
        case .meaning:
            // Mounted through the click-resolve pending state too:
            // hiding it for the ~100ms pending window resized the
            // viewport at every Meaning node click and again at resolve.
            return true
        default:
            return lockedVectorId == nil
        }
    }
}

enum LockedRecenterControlPolicy {
    static func isEnabled(
        lockedVectorId: Int64?,
        revealedLockedVectorId: Int64?
    ) -> Bool {
        guard let lockedVectorId else { return true }
        return revealedLockedVectorId == lockedVectorId
    }
}

enum LiveFocusExitPolicy {
    /// A live node lock in ANY lens exits through the reverse camera
    /// pullback. People correspondent locks are the one exception — their
    /// exit (portrait → galaxy) runs through
    /// `beginPeopleLiveFocusExitTransition` first, so `hasLivePersonFocus`
    /// keeps this generic path out of their way.
    static func shouldBeginExit(
        activeFrame: FrameKey,
        lockedVectorId: Int64?,
        hasLivePersonFocus: Bool,
        exitInFlight: Bool
    ) -> Bool {
        guard !exitInFlight,
              lockedVectorId != nil,
              !hasLivePersonFocus else {
            return false
        }
        return true
    }

    static func shouldExposeReleaseControls(
        lockedVectorId: Int64?,
        exitInFlight: Bool
    ) -> Bool {
        lockedVectorId != nil && !exitInFlight
    }
}

enum LiveFocusAnchorPolicy {
    static func shouldRefreshFocusedAnchor(
        activeFrame: FrameKey,
        lockedVectorId: Int64?,
        revealedLockedVectorId: Int64?,
        pendingRevealVectorId: Int64?,
        hasLivePersonFocus: Bool,
        exitInFlight: Bool
    ) -> Bool {
        guard !exitInFlight,
              !hasLivePersonFocus,
              let lockedVectorId else {
            return false
        }
        return pendingRevealVectorId == lockedVectorId
            || revealedLockedVectorId == lockedVectorId
    }
}

private struct PendingFocusClick {
    let id: Int
    let vectorId: Int64
    let world: SIMD3<Float>?
    let fallbackPoint: CGPoint?
    let transitionFallbackPoint: CGPoint?
    let sourceColor: SIMD4<Float>
    let personFocus: LockedPersonFocus?
    let startedAt: Date
}

private struct PendingTimelineNewStar: Equatable {
    let messageID: UUID
    let fallbackDate: Date
}

private struct PendingMetalNewStar: Equatable {
    let messageId: String
    let frame: FrameKey
    let hasRetriedAfterRefresh: Bool
}

private struct PendingTimelineAskCitation: Equatable {
    let messageID: UUID
    let fallbackDate: Date?
}

private struct TimelineSnapshotObservationKey: Equatable {
    let signature: TimelineLayoutSignature?
    let builtAt: Date?
    let latestMessageID: UUID?
    let latestMessageDate: Date?
    let count: Int

    init(snapshot: TimelineLayoutSnapshot?) {
        signature = snapshot?.signature
        builtAt = snapshot?.builtAt
        let latest = snapshot?.sortedEligibleEntries.last
        latestMessageID = latest?.id
        latestMessageDate = latest?.date
        count = snapshot?.sortedEligibleEntries.count ?? 0
    }
}

private struct NewStarFocusTarget {
    let vectorId: Int64
    let world: SIMD3<Float>
    let sourceColor: SIMD4<Float>
    let personFocus: LockedPersonFocus?
    let allowsPeopleEmailFocus: Bool
    let initialPeopleRingSelectionMessageId: String?
}

private enum FocusSourcePreviewCoordinates {
    case detail
    case transition
}

private struct FocusSourcePreview: Identifiable {
    let id: Int
    let messageId: String
    let row: MessageFilterRow
    let summaryOverride: String?
    let classificationOverride: MailClassification?
    let clickPoint: CGPoint
    let popupCenter: CGPoint
    let transitionClickPoint: CGPoint
    let transitionPopupCenter: CGPoint
    let sourceColor: SIMD4<Float>

    func clickPoint(in coordinates: FocusSourcePreviewCoordinates) -> CGPoint {
        switch coordinates {
        case .detail:
            return clickPoint
        case .transition:
            return transitionClickPoint
        }
    }

    func popupCenter(in coordinates: FocusSourcePreviewCoordinates) -> CGPoint {
        switch coordinates {
        case .detail:
            return popupCenter
        case .transition:
            return transitionPopupCenter
        }
    }
}

struct LiveFocusFramingPolicy {
    nonisolated static let maxContextPositionCount = 24
    nonisolated static let nodeFocusSceneContractionProgress: Float = 1.0
    nonisolated static let nodeFocusOverlayRevealProgress: Float = nodeFocusSceneContractionProgress
    nonisolated static let sceneContractionProgress: Float = 0.88
    nonisolated static let overlayRevealProgress: Float = 0.93
    nonisolated static let minimumFocusRadius: Float = 0.045
    nonisolated static let maximumFocusRadius: Float = 0.11
    nonisolated static let cameraDistanceMultiplier: Float = 0.48
    nonisolated static let cameraDistancePadding: Float = 0.018
    nonisolated static let minimumCameraDistance: Float = 0.070
    nonisolated static let maximumCameraDistance: Float = 0.22

    static func contextPositions(
        center: SIMD3<Float>,
        candidates: [SIMD3<Float>]
    ) -> [SIMD3<Float>] {
        let nearest = candidates.sorted {
            simd_distance_squared($0, center) < simd_distance_squared($1, center)
        }
        .prefix(maxContextPositionCount)
        return [center] + Array(nearest)
    }

    static func focusRadius(
        center: SIMD3<Float>,
        contextPositions: [SIMD3<Float>]
    ) -> Float {
        let distances = contextPositions
            .dropFirst()
            .map { simd_distance($0, center) }
            .sorted()
        guard distances.isEmpty == false else {
            return minimumFocusRadius
        }
        let sampleIndex = min(
            distances.count - 1,
            max(0, Int((Double(distances.count - 1) * 0.60).rounded()))
        )
        let sampledRadius = distances[sampleIndex]
        return min(maximumFocusRadius, max(minimumFocusRadius, sampledRadius))
    }

    static func cameraDistance(focusRadius: Float) -> Float {
        let fitRadius = min(max(0, focusRadius), maximumFocusRadius)
        let fitDistance = (fitRadius / SelectedNodeFocusCameraMath.tanHalfVerticalFOV)
            * cameraDistanceMultiplier
            + cameraDistancePadding
        return min(maximumCameraDistance, max(minimumCameraDistance, fitDistance))
    }

    /// Fixed focus radius for email-node locks inside the People solar
    /// system. The density-sampled radius above keys off the nearest
    /// context bodies, and in the solar system that density tracks
    /// distance from the sun (dense core, sparse rim) — near-sun locks
    /// pulled the camera in close while far locks pushed it out. A
    /// constant keeps every node lock at one depth no matter where its
    /// planet orbits.
    nonisolated static let peopleSolarFocusRadius: Float = 0.08

    /// Deterministic target camera for a People solar-system email-node
    /// lock: the clicked node centered, at the fixed solar depth, viewed
    /// along the ecliptic normal (hemisphere-corrected toward the
    /// current camera) so the ring plane is seen front-facing — the same
    /// vantage the correspondent portrait settles at.
    static func peopleSolarTargetCamera(
        center: SIMD3<Float>,
        current: CameraState,
        eclipticNormal: SIMD3<Float>
    ) -> CameraState {
        let distance = cameraDistance(focusRadius: peopleSolarFocusRadius)
        let axis = PeoplePortraitCameraPolicy.portraitApproachAxis(
            ringNormal: eclipticNormal,
            cameraPosition: current.position,
            center: center
        )
        let position = center + axis * distance
        let lookDirection = simd_normalize(center - position)
        return CameraState(
            position: position,
            velocity: .zero,
            yaw: atan2(-lookDirection.x, -lookDirection.z),
            pitch: asin(lookDirection.y),
            yawRate: 0,
            pitchRate: 0,
            roll: 0,
            rollRate: 0
        )
    }

    static func targetCamera(
        center: SIMD3<Float>,
        current: CameraState,
        focusRadius: Float
    ) -> CameraState {
        let distance = cameraDistance(focusRadius: focusRadius)
        let delta = center - current.position
        let viewDirection: SIMD3<Float>
        if simd_length(delta) > 0.001 {
            viewDirection = simd_normalize(delta)
        } else {
            viewDirection = forwardVector(yaw: current.yaw, pitch: current.pitch)
        }
        let position = center - viewDirection * distance
        let lookDirection = simd_normalize(center - position)
        return CameraState(
            position: position,
            velocity: .zero,
            yaw: atan2(-lookDirection.x, -lookDirection.z),
            pitch: asin(lookDirection.y),
            yawRate: 0,
            pitchRate: 0,
            roll: 0,
            rollRate: 0
        )
    }

    private static func forwardVector(yaw: Float, pitch: Float) -> SIMD3<Float> {
        let cy = cos(yaw)
        let sy = sin(yaw)
        let cp = cos(pitch)
        let sp = sin(pitch)
        return SIMD3<Float>(sy * cp, -sp, -cy * cp)
    }

}

private struct FocusTransitionSourceSnapshot {
    let packet: ConstellationRenderPacket
    let camera: CameraState
    let renderedFrame: FrameKey
    let renderedFilter: VectorFilter?
}

private struct LiveFocusRevealGate {
    let sequence: Int
    let vectorId: Int64
    let messageId: String
}

private struct PeopleLiveFocusRevealGate {
    let sequence: Int
    let vectorId: Int64
    let email: String
    let dimRampDuration: TimeInterval
}

private struct LiveMetalFocusWarpEffect: Identifiable {
    let id: Int
    let frame: FrameKey
    let vectorId: Int64
    let messageId: String
    let startedAt: Date
    let duration: TimeInterval
    let directionSign: Float
    let fieldDimTarget: Float?
    var awaitsFocusedPacket: Bool

    /// Timing descriptor handed to the Metal host; the draw loop derives
    /// the per-frame `ConstellationSourceWarp` from it (`warp(at:)`), so
    /// the effect crosses SwiftUI only when it arms or clears. Lens gating
    /// stays with `activeLiveMetalFocusWarpEffect`, which nils the effect
    /// when the active lens no longer matches `frame`.
    var sourceWarpDrive: ConstellationSourceWarpDrive {
        ConstellationSourceWarpDrive(
            id: id,
            startedAt: startedAt,
            duration: duration,
            directionSign: directionSign,
            fieldDimTarget: fieldDimTarget,
            meaningClusterVisibilityTarget: 0
        )
    }
}

extension ConstellationRenderPacket {
    func reissued(
        generatedAt: TimeInterval,
        fieldDimFactor fieldDimOverride: Float? = nil,
        meaningClusterVisibility meaningClusterVisibilityOverride: Float? = nil
    ) -> ConstellationRenderPacket {
        ConstellationRenderPacket(
            stars: stars,
            satellites: satellites,
            nebulae: nebulae,
            semanticDensityFields: semanticDensityFields,
            fibers: fibers,
            hitProxies: hitProxies,
            budget: budget,
            totalMessageCount: totalMessageCount,
            totalVectorCount: totalVectorCount,
            fieldDimFactor: fieldDimOverride ?? fieldDimFactor,
            generatedAt: generatedAt,
            visualLanguage: visualLanguage,
            arcLabels: arcLabels,
            personHubs: personHubs,
            personRelations: personRelations,
            personHitProxies: personHitProxies,
            meaningClusterHubs: meaningClusterHubs,
            meaningClusterVisibility: meaningClusterVisibilityOverride ?? meaningClusterVisibility,
            personRings: personRings,
            personAtoms: personAtoms,
            renderHubsAsPlanets: renderHubsAsPlanets,
            // Solar fields MUST survive the reissue. This copy is used by
            // the lock-release republish paths (source-galaxy handoff,
            // dim-released reissue); dropping `personSun` to its nil
            // default collapsed the whole solar presentation for the
            // release→refresh window — sun gone, orbit paths gone, and
            // every planet's ring satellites rendered uncollapsed (the
            // displacement/detail-fade table guards on the sun), which
            // read as a one-second "rings on every orb" flash at exit.
            personSun: personSun,
            personOrbitPathColor: personOrbitPathColor
        )
    }
}

private struct FocusJumpPendingIndicator: View {
    let startedAt: Date
    let sourceColor: SIMD4<Float>

    var body: some View {
        TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { context in
            let elapsed = Swift.max(0, context.date.timeIntervalSince(startedAt))
            let phase = CGFloat((elapsed / 1.2).truncatingRemainder(dividingBy: 1))
            let triangle = 1 - abs(2 * phase - 1)
            let eased = triangle * triangle * (3 - 2 * triangle)
            let accent = color(from: sourceColor)

            ZStack {
                Circle()
                    .fill(OhiaColors.surface(0.10))
                    .frame(width: 24, height: 24)
                    .shadow(color: accent.opacity(0.18), radius: 8)

                Circle()
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                    .frame(width: 40, height: 40)
                    .scaleEffect(1 + eased * 0.18)
                    .opacity(0.52 - eased * 0.24)

                Capsule()
                    .fill(accent.opacity(0.64))
                    .frame(width: 9 + eased * 4, height: 1.4)
                    .offset(x: 17 + eased * 2)

                Capsule()
                    .fill(accent.opacity(0.64))
                    .frame(width: 9 + eased * 4, height: 1.4)
                    .offset(x: -17 - eased * 2)

                Capsule()
                    .fill(accent.opacity(0.64))
                    .frame(width: 1.4, height: 9 + eased * 4)
                    .offset(y: 17 + eased * 2)

                Capsule()
                    .fill(accent.opacity(0.64))
                    .frame(width: 1.4, height: 9 + eased * 4)
                    .offset(y: -17 - eased * 2)

                Circle()
                    .strokeBorder(accent.opacity(0.72), lineWidth: 1)
                    .frame(width: 14, height: 14)
            }
            .frame(width: 58, height: 58)
        }
    }

    private func color(from source: SIMD4<Float>) -> Color {
        Color(
            .sRGB,
            red: Double(clamp(source.x)),
            green: Double(clamp(source.y)),
            blue: Double(clamp(source.z)),
            opacity: Double(clamp(source.w))
        )
    }

    private func clamp(_ value: Float) -> Float {
        Swift.min(Swift.max(value, 0), 1)
    }
}

private struct CameraPlanningSignature: Equatable {
    static let unset = CameraPlanningSignature(
        position: SIMD3<Float>(repeating: .greatestFiniteMagnitude),
        yaw: .greatestFiniteMagnitude,
        pitch: .greatestFiniteMagnitude,
        roll: .greatestFiniteMagnitude
    )

    let position: SIMD3<Float>
    let yaw: Float
    let pitch: Float
    let roll: Float

    nonisolated init(_ state: CameraState) {
        position = state.position
        yaw = state.yaw
        pitch = state.pitch
        roll = state.roll
    }

    private nonisolated init(position: SIMD3<Float>, yaw: Float, pitch: Float, roll: Float) {
        self.position = position
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    func isMeaningfullyDifferent(from previous: CameraPlanningSignature) -> Bool {
        let delta = position - previous.position
        return simd_dot(delta, delta) > 0.0004
            || angularDistance(yaw, previous.yaw) > 0.006
            || angularDistance(pitch, previous.pitch) > 0.006
            || angularDistance(roll, previous.roll) > 0.006
    }

    func needsReplan(comparedTo previous: CameraPlanningSignature) -> Bool {
        guard previous != Self.unset else { return true }
        let delta = position - previous.position
        return simd_dot(delta, delta) > 0.0144
            || angularDistance(yaw, previous.yaw) > 0.12
            || angularDistance(pitch, previous.pitch) > 0.12
            || angularDistance(roll, previous.roll) > 0.12
    }

    private func angularDistance(_ lhs: Float, _ rhs: Float) -> Float {
        let fullTurn = Float.pi * 2
        let raw = abs(lhs - rhs).truncatingRemainder(dividingBy: fullTurn)
        return min(raw, fullTurn - raw)
    }
}

private struct CorrespondentSuggestionAccumulator: Sendable {
    let value: String
    var title: String
    var subtitle: String?
    var frequency: Int = 0
    var lastSeen: Date?

    nonisolated var suggestion: CorrespondentFilterSuggestion {
        CorrespondentFilterSuggestion(
            value: value,
            title: title,
            subtitle: subtitle,
            frequency: frequency,
            lastSeen: lastSeen
        )
    }

    nonisolated mutating func observe(title candidateTitle: String, subtitle candidateSubtitle: String?, date: Date?) {
        frequency += 1
        if shouldPrefer(candidateTitle, over: title) {
            title = candidateTitle
            subtitle = candidateSubtitle
        }
        if let date, lastSeen.map({ date > $0 }) ?? true {
            lastSeen = date
        }
    }

    nonisolated private func shouldPrefer(_ candidate: String, over current: String) -> Bool {
        let normalizedCandidate = candidate.normalizedForCorrespondentAutocomplete
        let normalizedCurrent = current.normalizedForCorrespondentAutocomplete
        if normalizedCandidate == value.normalizedForCorrespondentAutocomplete {
            return false
        }
        if normalizedCurrent == value.normalizedForCorrespondentAutocomplete {
            return true
        }
        return candidate.count > current.count
    }
}

@MainActor
private final class OnboardingRevealSchedule {
    private static let immediateRevealCount = 1

    private var revealTimesByVectorId: [Int64: TimeInterval] = [:]
    private var nextRevealAt: TimeInterval?

    func reset() {
        revealTimesByVectorId.removeAll()
        nextRevealAt = nil
    }

    func sync(stars: [MessageStarInstance], now: Date) {
        let nowSeconds = now.timeIntervalSince1970
        let liveIds = Set(stars.map(\.representativeVectorId))
        for id in Array(revealTimesByVectorId.keys) where !liveIds.contains(id) {
            revealTimesByVectorId.removeValue(forKey: id)
        }

        let newStars = stars
            .filter { revealTimesByVectorId[$0.representativeVectorId] == nil }
            .sorted { lhs, rhs in
                let leftTime = lhs.arrivalTime > 0 ? lhs.arrivalTime : nowSeconds
                let rightTime = rhs.arrivalTime > 0 ? rhs.arrivalTime : nowSeconds
                if leftTime != rightTime { return leftTime < rightTime }
                return lhs.representativeVectorId < rhs.representativeVectorId
            }
        guard !newStars.isEmpty else {
            nextRevealAt = revealTimesByVectorId.values.max()
            return
        }

        let pendingFutureCount = revealTimesByVectorId.values.filter { $0 > nowSeconds }.count
        let interval = Self.revealInterval(forBacklog: pendingFutureCount + newStars.count)
        let existingCount = revealTimesByVectorId.count
        var cursor = max(nextRevealAt ?? nowSeconds, nowSeconds)

        for (offset, star) in newStars.enumerated() {
            let revealAt: TimeInterval
            if existingCount + offset < Self.immediateRevealCount {
                revealAt = nowSeconds
            } else {
                cursor += interval
                revealAt = cursor
            }
            revealTimesByVectorId[star.representativeVectorId] = revealAt
        }
        nextRevealAt = cursor
    }

    func remove(vectorIds: [Int64]) {
        for id in vectorIds {
            revealTimesByVectorId.removeValue(forKey: id)
        }
        nextRevealAt = revealTimesByVectorId.values.max()
    }

    func revealedVectorIds(now: Date) -> Set<Int64> {
        let nowSeconds = now.timeIntervalSince1970
        return Set(revealTimesByVectorId.compactMap { vectorId, revealAt in
            revealAt <= nowSeconds ? vectorId : nil
        })
    }

    func hasFutureReveals(now: Date) -> Bool {
        let nowSeconds = now.timeIntervalSince1970
        return revealTimesByVectorId.values.contains { $0 > nowSeconds }
    }

    private static func revealInterval(forBacklog backlog: Int) -> TimeInterval {
        if backlog >= 1_000 { return 0.080 }
        if backlog >= 250 { return 0.120 }
        return 0.220
    }
}

private struct PlacementObservation: Equatable {
    let total: Int
    let placed: Int
}

enum ConstellationVisibilityTransition: Sendable, Equatable {
    case continuous
    case filterChange
    case frameSwitch
}

struct ConstellationVisibleNodeLifecycle: Sendable, Equatable {
    private(set) var hasBaseline = false
    private(set) var visibleMessageIds: Set<String> = []
    // All message IDs observed in the latest snapshot universe, including
    // nodes hidden by the active filter. This prevents Day -> Month style
    // filter expansions from making already-known messages look newly born.
    private(set) var knownMessageIds: Set<String> = []
    // Message IDs that were first observed after the baseline but have not yet
    // rendered. If a truly new message is hidden by the current filter, it can
    // still get exactly one birth animation the first time it becomes visible.
    private(set) var pendingBirthMessageIds: Set<String> = []
    private(set) var renderedMessageIds: Set<String> = []

    mutating func reset() {
        hasBaseline = false
        visibleMessageIds.removeAll()
        knownMessageIds.removeAll()
        pendingBirthMessageIds.removeAll()
        renderedMessageIds.removeAll()
    }

    mutating func remove(messageIds: Set<String>) {
        visibleMessageIds.subtract(messageIds)
        pendingBirthMessageIds.subtract(messageIds)
    }

    mutating func enteringMessageIds(
        nextVisibleMessageIds: Set<String>,
        observedMessageIds: Set<String>,
        transition: ConstellationVisibilityTransition = .continuous,
        animatesInitialNonEmptyPacket: Bool
    ) -> Set<String> {
        guard hasBaseline else {
            hasBaseline = true
            visibleMessageIds = nextVisibleMessageIds
            knownMessageIds.formUnion(observedMessageIds)
            renderedMessageIds.formUnion(nextVisibleMessageIds)
            return animatesInitialNonEmptyPacket ? nextVisibleMessageIds : []
        }

        let newlyObservedMessageIds = observedMessageIds.subtracting(knownMessageIds)
        pendingBirthMessageIds.formUnion(newlyObservedMessageIds)

        let enteringMessageIds: Set<String>
        switch transition {
        case .continuous, .filterChange:
            enteringMessageIds = nextVisibleMessageIds
                .intersection(pendingBirthMessageIds)
                .subtracting(renderedMessageIds)
        case .frameSwitch:
            pendingBirthMessageIds.subtract(observedMessageIds)
            enteringMessageIds = []
        }

        visibleMessageIds = nextVisibleMessageIds
        knownMessageIds.formUnion(observedMessageIds)
        renderedMessageIds.formUnion(nextVisibleMessageIds)
        pendingBirthMessageIds.subtract(nextVisibleMessageIds)
        return enteringMessageIds
    }
}

private struct LockEntryEnrichmentToken: Equatable {
    let vectorId: Int64
    let sequence: Int
}

/// `.task(id:)` key for the Topics-pulldown counts. Category selection is
/// stripped from the captured filter so toggling a topic chip doesn't
/// recompute counts that are intentionally independent of the live facet
/// selection. `frame` and `snapshotMarker` identify the active lens's message
/// index, whether it came from Metal or a SwiftUI/Canvas workspace snapshot.
private struct TopicCountsRefreshKey: Equatable {
    let filterWithoutCategories: VectorFilter
    let frame: FrameKey
    let snapshotMarker: TimeInterval

    init(filter: VectorFilter, frame: FrameKey, snapshotMarker: TimeInterval) {
        var stripped = filter
        stripped.purposes = nil
        stripped.mailingListCategoryIncluded = nil
        stripped.customCategoryKeys = nil
        self.filterWithoutCategories = stripped
        self.frame = frame
        self.snapshotMarker = snapshotMarker
    }
}

/// `.task(id:)` key for the Voices row counts. The Voices selection (query
/// and list) is stripped because the counts are hypothetical with respect
/// to it. The snapshot revision (scene lenses) or workspace marker (Front
/// Page, Timeline, Projects) tracks content; the arrival gate re-keys the
/// counts when a live arrival is announced; and rolling presets re-key once
/// a minute so their window keeps sliding with the present.
private struct VoicesCountsRefreshKey: Equatable {
    let filterWithoutVoices: VectorFilter
    let selectedTimeRange: TimeRangePreset
    let frame: FrameKey
    let snapshotRevision: UInt64
    let workspaceMarker: TimeInterval?
    let gate: NewMailArrivalVisibilityGate
    let isOnboarding: Bool
    let rollingWindowMinute: Int?

    init(
        filter: VectorFilter,
        selectedTimeRange: TimeRangePreset,
        frame: FrameKey,
        snapshotRevision: UInt64,
        workspaceMarker: TimeInterval?,
        gate: NewMailArrivalVisibilityGate,
        isOnboarding: Bool,
        now: Date
    ) {
        var stripped = filter
        stripped.correspondentQuery = ""
        stripped.listIds = nil
        // The stored window is replaced by the effective one at refresh.
        if selectedTimeRange != .custom { stripped.timeRange = nil }
        self.filterWithoutVoices = stripped
        self.selectedTimeRange = selectedTimeRange
        self.frame = frame
        self.snapshotRevision = snapshotRevision
        self.workspaceMarker = workspaceMarker
        self.gate = gate
        self.isOnboarding = isOnboarding
        switch selectedTimeRange {
        case .all, .custom:
            self.rollingWindowMinute = nil
        default:
            self.rollingWindowMinute = Int(now.timeIntervalSinceReferenceDate / 60)
        }
    }
}

/// `.task(id:)` key for count caches that depend only on the active lens's
/// message index, not on the live filter.
private struct TopBarCountSnapshotRefreshKey: Equatable {
    let frame: FrameKey
    let snapshotMarker: TimeInterval
}

/// `.task(id:)` key for the Voices autocomplete catalog. The catalog depends
/// only on the active correspondent roles/account selection and the current
/// lens's full message snapshot; the typed query merely filters it locally.
private struct CorrespondentSuggestionsRefreshKey: Equatable {
    let scopes: Set<CorrespondentScope>
    let accountIds: Set<UUID>?
    let frame: FrameKey
    let snapshotMarker: TimeInterval
}

/// `.task(id:)` key for the Moments-pulldown counts. Counts depend on the
/// selected Destination accounts and time window. `customRange` is captured
/// separately so adjusting the date-picker re-fires the task. `frame` and
/// `snapshotMarker` identify the active lens's message index.
private struct TimeRangeCountsRefreshKey: Equatable {
    let accountIds: Set<UUID>?
    let frame: FrameKey
    let customRange: ClosedRange<Date>?
    let snapshotMarker: TimeInterval

    init(
        accountIds: Set<UUID>?,
        frame: FrameKey,
        customRange: ClosedRange<Date>?,
        snapshotMarker: TimeInterval
    ) {
        self.accountIds = accountIds
        self.frame = frame
        self.customRange = customRange
        self.snapshotMarker = snapshotMarker
    }
}

struct PersonHubHoverMetrics: Equatable {
    let messageCount: Int
    let receivedCount: Int
    let replyCount: Int
    /// Messages where this correspondent is on the To/Cc line of a third
    /// party's email (someone else sent it; both the user and this hub are
    /// recipients). `messageCount == receivedCount + replyCount + ccdCount`
    /// for the scoped row set used by the hover card.
    let ccdCount: Int
    let firstDate: Date?
    let lastDate: Date?
    let reciprocalScore: Float
    /// Outstanding obligations the user owes in response to mail this
    /// correspondent themselves sent (counted on received messages only). Cc'd
    /// third-party threads are deliberately excluded so a single group message
    /// never registers an obligation against every recipient's card — that
    /// obligation belongs to the actual sender. Per message the
    /// reply/confirmation invariant is binary, but across a correspondent both
    /// counts can be non-zero.
    let needsReplyCount: Int
    let needsConfirmationCount: Int

    init(rows: [MessageFilterRow], email rawEmail: String) {
        let email = Self.normalizedEmail(rawEmail)
        var receivedCount = 0
        var replyCount = 0
        var ccdCount = 0
        var needsReplyCount = 0
        var needsConfirmationCount = 0
        var dates: [Date] = []
        dates.reserveCapacity(rows.count)

        for row in rows {
            if let date = row.receivedAt {
                dates.append(date)
            }

            let sender = Self.normalizedEmail(row.fromAddress)
            let recipients = Set(row.recipientAddresses.map(Self.normalizedEmail))
            if row.isSentByUser {
                if recipients.contains(email) {
                    replyCount += 1
                }
            } else if sender == email {
                receivedCount += 1
            } else if recipients.contains(email) {
                ccdCount += 1
            }

            // Tally what the user still owes in response to mail this
            // correspondent sent (received messages only — cc'd third-party
            // threads belong to their own sender's card, so one group message
            // never counts against every recipient). Reply XOR confirmation per
            // message, mirroring the binary-obligation invariant.
            if !row.isSentByUser, sender == email {
                if row.isActionable == true {
                    needsReplyCount += 1
                } else if row.requiresConfirmation == true {
                    needsConfirmationCount += 1
                }
            }
        }

        let directionalCount = receivedCount + replyCount
        let reciprocalScore: Float
        if directionalCount > 0 {
            reciprocalScore = min(
                1,
                Float(min(receivedCount, replyCount) * 2) / Float(directionalCount)
            )
        } else {
            reciprocalScore = 0
        }

        let sortedDates = dates.sorted()
        self.messageCount = receivedCount + replyCount + ccdCount
        self.receivedCount = receivedCount
        self.replyCount = replyCount
        self.ccdCount = ccdCount
        self.firstDate = sortedDates.first
        self.lastDate = sortedDates.last
        self.reciprocalScore = reciprocalScore
        self.needsReplyCount = needsReplyCount
        self.needsConfirmationCount = needsConfirmationCount
    }

    private nonisolated static func normalizedEmail(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("mailto:") {
            trimmed.removeFirst("mailto:".count)
        }
        return trimmed
    }
}

struct PersonHubMetricAccountContexts: Equatable {
    let messages: HoverAccountContext?
    let received: HoverAccountContext?
    let replies: HoverAccountContext?
    let ccd: HoverAccountContext?

    init(
        rows: [MessageFilterRow],
        email rawEmail: String,
        accountsById: [UUID: HoverAccountContext]
    ) {
        let email = Self.normalizedEmail(rawEmail)
        var messages = AccountAccumulator()
        var received = AccountAccumulator()
        var replies = AccountAccumulator()
        var ccd = AccountAccumulator()

        for row in rows {
            let sender = Self.normalizedEmail(row.fromAddress)
            let recipients = Set(row.recipientAddresses.map(Self.normalizedEmail))
            if row.isSentByUser {
                if recipients.contains(email) {
                    messages.include(row: row, accountsById: accountsById)
                    replies.include(row: row, accountsById: accountsById)
                }
            } else if sender == email {
                messages.include(row: row, accountsById: accountsById)
                received.include(row: row, accountsById: accountsById)
            } else if recipients.contains(email) {
                messages.include(row: row, accountsById: accountsById)
                ccd.include(row: row, accountsById: accountsById)
            }
        }

        self.messages = messages.singleAccountContext(accountsById: accountsById)
        self.received = received.singleAccountContext(accountsById: accountsById)
        self.replies = replies.singleAccountContext(accountsById: accountsById)
        self.ccd = ccd.singleAccountContext(accountsById: accountsById)
    }

    private struct AccountAccumulator: Equatable {
        var count = 0
        var accountIds: Set<UUID> = []
        var hasUnknownAccount = false

        mutating func include(
            row: MessageFilterRow,
            accountsById: [UUID: HoverAccountContext]
        ) {
            count += 1
            guard let accountId = row.accountId,
                  accountsById[accountId] != nil else {
                hasUnknownAccount = true
                return
            }
            accountIds.insert(accountId)
        }

        func singleAccountContext(accountsById: [UUID: HoverAccountContext]) -> HoverAccountContext? {
            guard count > 0,
                  !hasUnknownAccount,
                  accountIds.count == 1,
                  let accountId = accountIds.first else {
                return nil
            }
            return accountsById[accountId]
        }
    }

    private nonisolated static func normalizedEmail(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("mailto:") {
            trimmed.removeFirst("mailto:".count)
        }
        return trimmed
    }
}

private struct PersonHubAccountEntry: Identifiable, Equatable {
    let id: UUID
    let account: HoverAccountContext
    let count: Int
}

/// Everything `PersonHubHoverContext` is computed from: the hub's identity
/// fields, its message scope, the gated message index those ids resolve
/// against (frame, snapshot revision, arrival gate), the drawn packet the
/// trimmed-nodes caption measures, and the accounts the card names.
private struct PersonHubHoverContextKey: Equatable {
    let email: String
    let displayName: String
    let isInstitutional: Bool
    let messageIds: Set<String>
    let frame: FrameKey
    let snapshotRevision: UInt64
    let drawnPacketGeneratedAt: TimeInterval
    let gate: NewMailArrivalVisibilityGate
    let accounts: [PersonHubHoverAccountKey]
}

private struct PersonHubHoverAccountKey: Equatable {
    let id: UUID
    let context: HoverAccountContext
}

private struct PersonHubHoverContext {
    let displayName: String
    let email: String
    let metrics: PersonHubHoverMetrics
    let metricAccounts: PersonHubMetricAccountContexts
    let accountEntries: [PersonHubAccountEntry]
    let isInstitutional: Bool
    /// Emails drawn as nodes when the scene's caps hid some of this
    /// person's in-scope mail; nil otherwise. See `CorrespondentShownNodes`.
    let shownNodeCount: Int?

    var messageCount: Int { metrics.messageCount }
    var receivedCount: Int { metrics.receivedCount }
    var replyCount: Int { metrics.replyCount }
    var ccdCount: Int { metrics.ccdCount }
    var firstDate: Date? { metrics.firstDate }
    var lastDate: Date? { metrics.lastDate }
    var reciprocalScore: Float { metrics.reciprocalScore }
    var needsReplyCount: Int { metrics.needsReplyCount }
    var needsConfirmationCount: Int { metrics.needsConfirmationCount }
    var hasObligations: Bool { needsReplyCount > 0 || needsConfirmationCount > 0 }

    var title: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == email ? email : trimmed
    }

    var subtitle: String? {
        title == email ? nil : email
    }

    /// Same span format as the Meaning cluster card.
    var dateRangeText: String {
        switch (firstDate, lastDate) {
        case let (first?, last?):
            return HoverReadoutDateSpan.text(from: first, to: last)
        case (nil, nil):
            return "No dated messages"
        case let (first?, nil), let (nil, first?):
            return HoverReadoutDateSpan.singleDay(first)
        }
    }

    var shownNodesText: String? {
        shownNodeCount.map {
            CorrespondentShownNodes.caption(shown: $0, messageCount: messageCount)
        }
    }

    var reciprocityText: String {
        if reciprocalScore >= 0.66 { return "reciprocal" }
        if replyCount > 0 { return "partly reciprocal" }
        return isInstitutional ? "broadcast" : "one-way"
    }

    var reciprocityIcon: String {
        if reciprocalScore >= 0.66 { return "arrow.left.arrow.right.circle.fill" }
        if replyCount > 0 { return "arrow.left.arrow.right.circle" }
        return isInstitutional ? "arrow.forward.to.line" : "arrow.forward"
    }

    /// Five-tier freshness based on days since `lastDate`:
    /// active (≤7) / recent (8–30) / fading (31–90) / quiet (91–365) /
    /// dormant (365+). `nil` when there is no dated activity so the row
    /// collapses cleanly to the reciprocity pair alone.
    var freshnessText: String? {
        guard let lastDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
        if days < 0 { return nil }
        if days <= 7 { return "active" }
        if days <= 30 { return "recent" }
        if days <= 90 { return "fading" }
        if days <= 365 { return "quiet" }
        return "dormant"
    }

    var freshnessIcon: String? {
        guard let freshnessText else { return nil }
        switch freshnessText {
        case "active":  return "waveform.path"
        case "recent":  return "waveform"
        case "fading":  return "clock"
        case "quiet":   return "clock.arrow.circlepath"
        case "dormant": return "hourglass.bottomhalf.filled"
        default:        return "clock"
        }
    }

    var accessibilityLabel: String {
        var parts = [
            title,
            "\(messageCount) messages",
            "\(receivedCount) received",
            "\(replyCount) replies sent",
            "\(ccdCount) cc'd",
            dateRangeText
        ]
        if let shownNodesText {
            parts.append(shownNodesText)
        }
        if needsReplyCount > 0 {
            parts.append("\(needsReplyCount) needing reply")
        }
        if needsConfirmationCount > 0 {
            parts.append("\(needsConfirmationCount) needing confirmation")
        }
        if !accountEntries.isEmpty {
            parts.append(accountEntries.map {
                "\($0.account.resolvedDisplayName) \($0.count)"
            }.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }
}

/// The inputs of the People correspondent scope build in flight.
private struct PeopleCorrespondentScopeBuild: Equatable {
    let inputs: PeopleCorrespondentScopeInputs
    let visualFilter: VectorFilter
}

/// Exact count of messages passing the full scene filter for one engaged
/// Meaning cluster scope; `filter` and `selectedTimeRange` name that scope.
private struct MeaningClusterScopeMessageCount: Equatable {
    let filter: VectorFilter
    let selectedTimeRange: TimeRangePreset
    let count: Int
}

struct MeaningClusterHoverContext {
    let clusterId: Int64
    let title: String
    let rawTerms: [String]
    let messageCount: Int
    /// The cluster's share of the visible messages in the current scope, in
    /// [0, 1]; `nil` when the cluster has no hub in the installed packet.
    let scopeShare: Double?
    /// Earliest and latest received date among the visible members.
    let receivedDateRange: ClosedRange<Date>?
    /// The title is a generated overview its model marked low-confidence.
    let isTentativeTitle: Bool
    let tint: SIMD3<Float>

    var tintColor: Color {
        Color(
            red: Double(tint.x),
            green: Double(tint.y),
            blue: Double(tint.z)
        )
    }

    var termsText: String? {
        guard !rawTerms.isEmpty else { return nil }
        return rawTerms.joined(separator: " · ")
    }

    var scopeShareText: String? {
        guard let scopeShare, scopeShare > 0 else { return nil }
        guard scopeShare >= 0.01 else { return "<1%" }
        return "\(Int((min(scopeShare, 1) * 100).rounded()))%"
    }

    /// Day precision inside one calendar year, month precision across years.
    var receivedDateRangeText: String? {
        guard let receivedDateRange else { return nil }
        return HoverReadoutDateSpan.text(
            from: receivedDateRange.lowerBound,
            to: receivedDateRange.upperBound
        )
    }

    var accessibilityLabel: String {
        var parts = ["Meaning cluster", title]
        if isTentativeTitle {
            parts.append("tentative title")
        }
        parts.append("\(messageCount) messages")
        if let scopeShareText {
            parts.append("\(scopeShareText) of scope")
        }
        if let receivedDateRangeText {
            parts.append("received \(receivedDateRangeText)")
        }
        if let termsText {
            parts.append(termsText)
        }
        return parts.joined(separator: ", ")
    }
}

private struct MeaningClusterDisplayLimitChangeObserver: ViewModifier {
    let value: Double
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: value) { _, _ in
            onChange()
        }
    }
}

/// Captures the rendered height of `MeaningClusterHoverCard`. The overlay
/// uses the measurement to position the bordered card body so its top edge
/// sits on the leader attach y.
private struct MeaningClusterHoverHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MeaningClusterHoverBodyHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MeaningClusterHoverCard: View {
    static let width: CGFloat = 308

    let context: MeaningClusterHoverContext
    var mirrored: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            annotationMark
            popupBody
        }
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var annotationMark: some View {
        HStack(spacing: 6) {
            if mirrored {
                Spacer(minLength: 0)
                Text("Meaning")
                    .font(OhiaTypography.annotationBody)
                    .tracking(0.6)
                    .foregroundStyle(context.tintColor)
                Image(systemName: "sparkles")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(context.tintColor)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(context.tintColor)
                Text("Meaning")
                    .font(OhiaTypography.annotationBody)
                    .tracking(0.6)
                    .foregroundStyle(context.tintColor)
            }
        }
    }

    private var popupBody: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(context.tintColor)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            context.isTentativeTitle
                                ? OhiaColors.textSecondary
                                : OhiaColors.textPrimary
                        )
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if context.isTentativeTitle {
                        Text("tentative")
                            .font(OhiaTypography.caption)
                            .foregroundStyle(OhiaColors.textTertiary)
                    }
                }
                if let termsText = context.termsText {
                    Text(termsText)
                        .font(.system(size: 12, weight: .regular).italic())
                        .foregroundStyle(context.tintColor.opacity(0.92))
                        .lineLimit(2)
                }
                hairline
                HStack(spacing: 8) {
                    metric("\(context.messageCount)", "messages")
                    if let scopeShareText = context.scopeShareText {
                        metric(scopeShareText, "of scope")
                    }
                }
                if let receivedDateRangeText = context.receivedDateRangeText {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(OhiaColors.textTertiary)
                        Text(receivedDateRangeText)
                            .font(OhiaTypography.caption)
                            .foregroundStyle(OhiaColors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(width: 306, alignment: .leading)
        }
        .background(
            LinearGradient(
                colors: [
                    OhiaColors.hoverReadoutGradientTop,
                    OhiaColors.hoverReadoutGradientBottom
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MeaningClusterHoverBodyHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(context.tintColor.opacity(0.10))
                .blur(radius: 18)
                .padding(-12)
        }
        .shadow(color: context.tintColor.opacity(0.14), radius: 14, x: 0, y: 6)
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
    }

    private var hairline: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder.opacity(0.62))
            .frame(height: 1)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hover readout for the People solar system's sun — the user's aggregate
/// correspondence across the active scope. Same visual idiom as
/// `PersonHubHoverCard` (annotation mark + left-rail card) so the sun
/// reads as a first-class body with a structural readout, never as an
/// agent.
private struct PersonSunHoverCard: View {
    let sun: PersonSunInstance
    let accounts: [Account]

    private var accountCount: Int { accounts.count }

    /// The account owner's name as it identifies them, preferring the
    /// primary send-as identity's display phrase over the account's
    /// onboarding label, and never the raw email address.
    private static func identityName(for account: Account) -> String {
        if let phrase = account.primaryIdentity?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !phrase.isEmpty {
            return phrase
        }
        return account.displayName
    }

    /// Each in-scope account paired with its resolved identity name.
    private var namedAccounts: [(account: Account, name: String)] {
        accounts.map { (account: $0, name: Self.identityName(for: $0)) }
    }

    /// Combined scope line: the correspondent count, a middle dot, then the
    /// number of in-scope accounts (e.g. "2 correspondents · 1 account").
    private var scopeSummary: String {
        let correspondents = sun.correspondentCount == 1
            ? "1 correspondent"
            : "\(sun.correspondentCount) correspondents"
        let accountsPhrase = accountCount == 1
            ? "1 account"
            : "\(accountCount) accounts"
        return "\(correspondents) · \(accountsPhrase)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                Text("You")
                    .font(OhiaTypography.annotationBody)
                    .tracking(0.6)
                    .foregroundStyle(OhiaColors.chipActiveForeground)
            }
            HStack(spacing: 0) {
                Rectangle()
                    .fill(OhiaColors.chipActiveBorder)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 8) {
                    titleView
                    Text(scopeSummary)
                        .font(OhiaTypography.caption)
                        .foregroundStyle(OhiaColors.textTertiary)
                        .lineLimit(1)
                    Rectangle()
                        .fill(OhiaColors.glassBorder.opacity(0.62))
                        .frame(height: 1)
                    HStack(spacing: 8) {
                        sunMetric("\(sun.sentCount)", "sent")
                        sunMetric("\(sun.receivedCount)", "received")
                        sunMetric("\(sun.openObligationCount)", "owed")
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .frame(width: 306, alignment: .leading)
            }
            .background(
                LinearGradient(
                    colors: [
                        OhiaColors.hoverReadoutGradientTop,
                        OhiaColors.hoverReadoutGradientBottom
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
            }
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OhiaColors.chipActiveBorder.opacity(0.09))
                    .blur(radius: 18)
                    .padding(-12)
            }
            .shadow(color: OhiaColors.chipActiveBorder.opacity(0.12), radius: 14, x: 0, y: 6)
            .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Title line. When every in-scope account resolves to the same
    /// identity name the pane shows it once; when they differ, each
    /// account's name gets its own line preceded by its account glyph.
    @ViewBuilder
    private var titleView: some View {
        let named = namedAccounts
        let distinctNames = Set(named.map(\.name))
        if distinctNames.count > 1 {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(named, id: \.account.id) { entry in
                    HStack(spacing: 5) {
                        AccountGlyphImage(
                            glyph: AccountIcon.style(for: entry.account).glyph,
                            size: 12
                        )
                        .foregroundStyle(entry.account.accountColor.swiftUIColor)
                        Text(entry.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(OhiaColors.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            Text(named.first?.name ?? "Your correspondence")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary)
                .lineLimit(1)
        }
    }

    private func sunMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(OhiaColors.textPrimary)
            Text(label)
                .font(OhiaTypography.caption)
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PersonHubHoverCard: View {
    let context: PersonHubHoverContext

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            annotationMark
            popupBody
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var annotationMark: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(OhiaColors.chipActiveForeground)
            Text("Correspondent")
                .font(OhiaTypography.annotationBody)
                .tracking(0.6)
                .foregroundStyle(OhiaColors.chipActiveForeground)
        }
    }

    private var popupBody: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(OhiaColors.chipActiveBorder)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 8) {
                if let subtitle = context.subtitle {
                    Text(subtitle)
                        .font(OhiaTypography.caption)
                        .foregroundStyle(OhiaColors.textTertiary)
                        .lineLimit(1)
                }
                Text(context.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(context.dateRangeText)
                    .font(.system(size: 12, weight: .regular).italic())
                    .foregroundStyle(OhiaColors.textSecondary)
                    .lineLimit(1)
                hairline
                HStack(spacing: 8) {
                    metric("\(context.messageCount)", "messages", account: context.metricAccounts.messages)
                    metric("\(context.receivedCount)", "received", account: context.metricAccounts.received)
                    metric("\(context.replyCount)", "replies", account: context.metricAccounts.replies)
                    metric("\(context.ccdCount)", "cc'd", account: context.metricAccounts.ccd)
                }
                // Only when the scene's node caps hid some of this person's
                // in-scope emails.
                if let shownNodesText = context.shownNodesText {
                    Text(shownNodesText)
                        .font(OhiaTypography.caption)
                        .monospacedDigit()
                        .foregroundStyle(OhiaColors.textTertiary)
                        .tracking(0.1)
                        .lineLimit(1)
                }
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: context.reciprocityIcon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(OhiaColors.textTertiary)
                        Text(context.reciprocityText)
                            .font(OhiaTypography.caption)
                            .foregroundStyle(OhiaColors.textTertiary)
                            .tracking(0.1)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    // Outstanding-action signal sits between the relationship
                    // (reciprocity) and recency (freshness) readouts. Colored
                    // glyph + count so it reads as an obligation, not a neutral
                    // relationship stat; collapses to nothing when the person
                    // owes no action.
                    obligationMarks
                    // The trailing spacer rides with freshness so that when
                    // freshness is absent the obligation marks take its right
                    // slot instead of leaving a dead right third.
                    if let freshnessText = context.freshnessText,
                       let freshnessIcon = context.freshnessIcon {
                        Spacer(minLength: 12)
                        HStack(spacing: 5) {
                            Image(systemName: freshnessIcon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(OhiaColors.textTertiary)
                            Text(freshnessText)
                                .font(OhiaTypography.caption)
                                .foregroundStyle(OhiaColors.textTertiary)
                                .tracking(0.1)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(width: 306, alignment: .leading)
        }
        .background(
            LinearGradient(
                colors: [
                    OhiaColors.hoverReadoutGradientTop,
                    OhiaColors.hoverReadoutGradientBottom
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OhiaColors.chipActiveBorder.opacity(0.09))
                .blur(radius: 18)
                .padding(-12)
        }
        .shadow(color: OhiaColors.chipActiveBorder.opacity(0.12), radius: 14, x: 0, y: 6)
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
    }

    private var hairline: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder.opacity(0.62))
            .frame(height: 1)
    }

    private func metric(_ value: String, _ label: String, account: HoverAccountContext? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(account?.accountColor.swiftUIColor ?? OhiaColors.textPrimary)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Outstanding-obligation marks for the correspondent: reply and/or
    /// confirmation, each as the canonical glyph + a count, tinted to match the
    /// message hover and the Front Page / Projects lenses. Collapses to nothing
    /// when the person owes no action.
    @ViewBuilder
    private var obligationMarks: some View {
        if context.hasObligations {
            HStack(spacing: 10) {
                if context.needsReplyCount > 0 {
                    obligationMark(.pendingReply, count: context.needsReplyCount)
                }
                if context.needsConfirmationCount > 0 {
                    obligationMark(.needsConfirmation, count: context.needsConfirmationCount)
                }
            }
        }
    }

    private func obligationMark(_ action: MessageStatusActionState, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: action.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(action.tint)
            Text("\(count)")
                .font(OhiaTypography.caption)
                .monospacedDigit()
                .foregroundStyle(action.tint)
                .lineLimit(1)
        }
        .fixedSize()
        .help(obligationHelp(action, count: count))
    }

    private func obligationHelp(_ action: MessageStatusActionState, count: Int) -> String {
        let subject = count == 1 ? "message needs" : "messages need"
        let what: String
        switch action {
        case .pendingReply: what = "a reply"
        case .needsConfirmation: what = "confirmation"
        default: what = "action"
        }
        return "\(count) \(subject) \(what)"
    }
}

private enum ProjectedHoverTarget: Equatable {
    case citation(Int64)
    case searchMatch(Int64, SIMD3<Float>)

    var vectorId: Int64 {
        switch self {
        case .citation(let id), .searchMatch(let id, _):
            return id
        }
    }

    var worldPosition: SIMD3<Float>? {
        switch self {
        case .citation:
            return nil
        case .searchMatch(_, let world):
            return world
        }
    }
}

private struct SearchMatchKeyboardCatcher: NSViewRepresentable {
    let onKeyDown: @MainActor (UInt16, NSEvent.ModifierFlags) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.focusRingType = .none
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: CatcherView, coordinator: ()) {
        nsView.resignActiveCatcher()
    }

    final class CatcherView: NSView {
        var onKeyDown: (@MainActor (UInt16, NSEvent.ModifierFlags) -> Bool)?

        private static weak var activeView: CatcherView?
        private static var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                Self.activeView = self
                Self.installMonitorIfNeeded()
            } else if window == nil {
                resignActiveCatcher()
            }
        }

        deinit {
            resignActiveCatcher()
        }

        func resignActiveCatcher() {
            if Self.activeView === self {
                Self.activeView = nil
            }
        }

        private static func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard let activeView,
                      let window = activeView.window,
                      event.window === window else { return event }
                guard !Self.firstResponderIsBlockingTextInput(in: window) else { return event }
                guard activeView.onKeyDown?(event.keyCode, event.modifierFlags) == true else {
                    return event
                }
                return nil
            }
        }

        private static func firstResponderIsBlockingTextInput(in window: NSWindow) -> Bool {
            var responder: NSResponder? = window.firstResponder
            while let current = responder {
                if let textView = current as? NSTextView {
                    if let field = textView.delegate as? NSTextField,
                       field.placeholderString == Self.searchFieldPlaceholder {
                        return false
                    }
                    return true
                }
                if let field = current as? NSTextField {
                    return field.placeholderString != Self.searchFieldPlaceholder
                }
                if current is NSSearchField {
                    return true
                }
                responder = current.nextResponder
            }
            return false
        }

        private static let searchFieldPlaceholder = "Find a word, phrase, or number"
    }
}

private struct EmailSummaryInvalidationObserver: ViewModifier {
    let onInvalidate: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .ohiaEmailSummariesInvalidated)) { _ in
            onInvalidate()
        }
    }
}

private struct AccountColorInvalidationObserver: ViewModifier {
    let onInvalidate: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .ohiaAccountColorChanged)) { _ in
            onInvalidate()
        }
    }
}

private struct MessageAttentionInvalidationObserver: ViewModifier {
    let onInvalidate: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .ohiaMessageAttentionChanged)) { _ in
            onInvalidate()
        }
    }
}

/// Fires `onReenterOnboarding` when the host is pushed back into onboarding
/// (`onboardingMode` transitions false → true) — e.g. a dev reset that wipes
/// first-ingestion without tearing the view down. Lives as a `ViewModifier` so
/// the `onChange` is type-checked here rather than swelling the host's already
/// type-check-heavy body.
private struct OnboardingReentryObserver: ViewModifier {
    let onboardingMode: Bool
    let onReenterOnboarding: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: onboardingMode) { _, isOnboarding in
            if isOnboarding {
                onReenterOnboarding()
            }
        }
    }
}

private struct ContentRegenerationObserver: ViewModifier {
    let onRegenerateGeneratedText: () async -> Void
    let onRegenerateTranslation: () -> Void
    /// Coalesces rapid menu invocations: each invocation cancels the prior
    /// arbiter run before starting a new one, so two requests can't drive two
    /// concurrent regenerations of the same surface (the in-flight summary work
    /// checks `Task.isCancelled` and the on-demand summarizer restarts its own task).
    @State private var generatedTextTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ohiaRegenerateGeneratedText)) { _ in
                generatedTextTask?.cancel()
                generatedTextTask = Task { await onRegenerateGeneratedText() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaRegenerateTranslation)) { _ in
                onRegenerateTranslation()
            }
    }
}

/// Bundles the four Edit-menu locked-node notification observers into a
/// single modifier. Inlining the four `.onReceive` calls in the main
/// body chain blew past the Swift type-checker's complexity budget.
/// SwiftUI runs ViewModifier.body on the main actor by contract, so no
/// explicit `@MainActor` is needed on the struct.
private struct LockedNodeMenuObservers: ViewModifier {
    let onToggleRead: () -> Void
    let onMarkAsSpam: () -> Void
    let onDelete: (Bool) -> Void
    let onEditClassificationFacet: (Notification) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ohiaLockedNodeToggleRead)) { _ in
                onToggleRead()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaLockedNodeMarkAsSpam)) { _ in
                onMarkAsSpam()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaLockedNodeDelete)) { notification in
                // Default to confirming; ⌘-Delete posts confirm == false.
                let confirm = (notification.userInfo?["confirm"] as? Bool) ?? true
                onDelete(confirm)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaLockedNodeEditClassificationFacet)) { notification in
                onEditClassificationFacet(notification)
            }
    }
}

/// Publishes the active sent-message action to app commands without adding
/// another generic modifier to ConstellationModeView's type-check-heavy body.
private struct SendAgainFocusedValueModifier: ViewModifier {
    let target: SendAgainCommandTarget?

    func body(content: Content) -> some View {
        content.focusedSceneValue(\.sendAgainCommandTarget, target)
    }
}

/// Publishes the current lens's focused print action to File → Print without
/// adding another focused-value expression to ConstellationModeView's body.
private struct FocusedEmailPrintValueModifier: ViewModifier {
    let target: FocusedEmailPrintCommandTarget?

    func body(content: Content) -> some View {
        content.focusedSceneValue(\.focusedEmailPrintCommandTarget, target)
    }
}
