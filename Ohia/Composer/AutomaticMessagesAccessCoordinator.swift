import Foundation
import Observation
import SwiftData
import SwiftUI
import OhiaCore
import OhiaML

@MainActor
@Observable
final class AutomaticMessagesAccessCoordinator {
    private enum RequestKey: Hashable {
        case reply(UUID)
        case compose(UUID, String)
    }

    typealias RetryHandler = @MainActor @Sendable (
        AutomaticMessagesRequest
    ) async -> AutomaticMessagesResult

    static let didMergeSourceNotification = Notification.Name(
        "org.jgkarlin.Ohia.automaticMessagesSourceDidMerge"
    )

    private(set) var pendingRequest: AutomaticMessagesRequest?
    private var hasPresentedExplanation = false
    private var deniedRequests: [RequestKey: AutomaticMessagesRequest] = [:]
    private var activeKey: RequestKey?
    private var activeDraftID: UUID?
    private let retryHandler: RetryHandler

    init(retryHandler: @escaping RetryHandler) {
        self.retryHandler = retryHandler
    }

    var shouldPresentExplanation: Bool {
        pendingRequest != nil && !hasPresentedExplanation
    }

    func record(
        _ result: AutomaticMessagesResult,
        for request: AutomaticMessagesRequest
    ) {
        let key = Self.key(for: request)
        if result == .contactResolvedDatabaseUnavailable {
            deniedRequests[key] = request
            promotePendingRequestIfActive(key: key)
        } else {
            deniedRequests[key] = nil
            if pendingRequest.map(Self.key(for:)) == key {
                pendingRequest = nil
            }
        }
    }

    func activateReply(messageID: UUID, draftID: UUID?) {
        activeKey = .reply(messageID)
        activeDraftID = draftID
        promotePendingRequestIfActive(key: .reply(messageID))
    }

    func activateCompose(draftID: UUID, correspondentAddress: String) {
        let key = RequestKey.compose(
            draftID,
            Self.normalizedAddress(correspondentAddress)
        )
        activeKey = key
        activeDraftID = draftID
        promotePendingRequestIfActive(key: key)
    }

    func deactivate() {
        activeKey = nil
        activeDraftID = nil
        pendingRequest = nil
    }

    func markExplanationPresented() {
        hasPresentedExplanation = true
    }

    func retryPendingDraftAfterApplicationActivation() async {
        guard let request = pendingRequest else { return }
        let result = await retryHandler(request)
        if result != .contactResolvedDatabaseUnavailable {
            pendingRequest = nil
        }
    }

    private func promotePendingRequestIfActive(key: RequestKey) {
        guard activeKey == key,
              let activeDraftID,
              let denied = deniedRequests[key] else {
            if activeKey != key {
                pendingRequest = nil
            }
            return
        }
        pendingRequest = denied.withDraftID(activeDraftID)
    }

    private static func key(for request: AutomaticMessagesRequest) -> RequestKey {
        switch request.context {
        case .reply(let messageID, _): return .reply(messageID)
        case .compose(let draftID):
            return .compose(draftID, normalizedAddress(request.correspondentAddress))
        }
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func retryAndMerge(
        request: AutomaticMessagesRequest,
        broker: MessagesTranscriptBroker,
        container: ModelContainer
    ) async -> AutomaticMessagesResult {
        let result = await broker.transcript(for: request)
        guard let draftID = request.draftID,
              let source = result.composerSource(messageID: request.messageID) else {
            return result
        }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { $0.id == draftID }
        )
        guard let draft = try? context.fetch(descriptor).first,
              requestStillMatches(draft: draft, request: request) else {
            return result
        }

        let original = ComposerSourceCoding.decode(draft.sourcesJSON)
        var merged = original.filter { $0.kind != .messages || $0.isUserAdded }
        merged.append(source)
        guard ComposerSourceMutationPersistence.prepareForPersistence(
            draft: draft,
            original: original,
            mutated: merged
        ) else { return result }

        draft.sourcesJSON = ComposerSourceCoding.encode(merged)
        do {
            try ComposerSourceContextMeasurementScheduler.stageMeasurement(
                draft: draft,
                context: context
            )
            try context.save()
            NotificationCenter.default.post(
                name: didMergeSourceNotification,
                object: nil,
                userInfo: ["draftID": draftID]
            )
        } catch {
            context.rollback()
        }
        return result
    }

    private static func requestStillMatches(
        draft: Draft,
        request: AutomaticMessagesRequest
    ) -> Bool {
        switch request.context {
        case .reply(let messageID, _):
            return draft.message?.id == messageID
        case .compose:
            guard let currentAddress = ComposeAddressEncoding.decode(
                draft.composeToJSON
            ).first else {
                return false
            }
            return normalizedAddress(currentAddress) == request.correspondentAddress
        }
    }
}

struct AutomaticMessagesAccessPresentation: ViewModifier {
    @Environment(AutomaticMessagesAccessCoordinator.self)
    private var coordinator: AutomaticMessagesAccessCoordinator?

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                Task {
                    await coordinator?.retryPendingDraftAfterApplicationActivation()
                }
            }
            .alert(
                "Messages Access",
                isPresented: Binding(
                    get: { coordinator?.shouldPresentExplanation ?? false },
                    set: { isPresented in
                        if !isPresented {
                            coordinator?.markExplanationPresented()
                        }
                    }
                )
            ) {
                Button("Open System Settings") {
                    coordinator?.markExplanationPresented()
                    PrivacySettings.open("Privacy_AllFiles")
                }
                Button("Not Now", role: .cancel) {
                    coordinator?.markExplanationPresented()
                }
            } message: {
                Text("Ohia can automatically include recent Messages with this correspondent. Allow Ohia in System Settings › Privacy & Security › Full Disk Access. Drafting will continue without Messages.")
            }
    }
}

private extension AutomaticMessagesRequest {
    var messageID: UUID? {
        guard case .reply(let messageID, _) = context else { return nil }
        return messageID
    }

    func withDraftID(_ draftID: UUID?) -> AutomaticMessagesRequest {
        let updatedContext: Context
        switch context {
        case .reply(let messageID, _):
            updatedContext = .reply(messageID: messageID, draftID: draftID)
        case .compose(let existingDraftID):
            updatedContext = .compose(draftID: draftID ?? existingDraftID)
        }
        return AutomaticMessagesRequest(
            context: updatedContext,
            correspondentAddress: correspondentAddress,
            limit: limit,
            maxAge: maxAge
        )
    }
}
