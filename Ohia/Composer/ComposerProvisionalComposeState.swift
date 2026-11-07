import Foundation
import SwiftData
import SwiftUI
import OhiaCore
import OhiaML

/// The values entered in the Composer's new-message header before a persisted
/// Draft exists. A valid subject or recipient commit promotes this snapshot to
/// a real queued compose draft.
struct ComposerProvisionalComposeRequest: Equatable {
    let subject: String
    let to: [ComposeAddressEncoding.ParsedAddress]
    let cc: [ComposeAddressEncoding.ParsedAddress]
    let bcc: [ComposeAddressEncoding.ParsedAddress]
    let identityID: UUID?
    let signatureSlotID: UUID?
}

/// Transient host for the full new-message header. Typing stays local; only a
/// committed subject or recipient publishes `promotionRequest`.
@Observable
@MainActor
final class ComposerProvisionalComposeState: ComposerRecipientHost {
    var id = UUID()
    var subject = ""
    private(set) var recipientSuggestions: [ComposeRecipientSuggestion] = []
    private(set) var toChips: [ComposeAddressEncoding.ParsedAddress] = []
    private(set) var ccChips: [ComposeAddressEncoding.ParsedAddress] = []
    private(set) var bccChips: [ComposeAddressEncoding.ParsedAddress] = []
    private(set) var availableAccounts: [Account] = []
    var selectedIdentity: Identity?
    var selectedSignatureSlotID: UUID?
    private(set) var promotionRequest: ComposerProvisionalComposeRequest?

    var availableIdentities: [Identity] {
        availableAccounts.flatMap(\.identities)
    }

    var availableSignatureSlots: [SignatureSlot] {
        selectedIdentity?.account?.orderedSignatureSlots ?? []
    }

    var hasDraftRow: Bool { false }
    var recipientMutationsEnabled: Bool { true }

    func reset(context: ModelContext, defaults: UserDefaults = .standard) {
        id = UUID()
        subject = ""
        toChips = []
        ccChips = []
        bccChips = []
        promotionRequest = nil

        availableAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        recipientSuggestions = ComposerSession.recipientSuggestionCatalog(context: context)
        let initialAccountID = ComposeAddressEncoding.resolveInitialFromAccount(
            availableAccountIDs: availableAccounts.map(\.id),
            defaults: defaults
        )
        let initialAccount = availableAccounts.first(where: { $0.id == initialAccountID })
        selectedIdentity = initialAccount?.primaryIdentity
        selectedSignatureSlotID = initialAccount?.defaultSignatureSlot?.id
    }

    func setIdentity(_ identity: Identity?) {
        let previousAccountID = selectedIdentity?.account?.id
        selectedIdentity = identity
        if identity?.account?.id != previousAccountID {
            selectedSignatureSlotID = identity?.account?.defaultSignatureSlot?.id
        }
    }

    func commitSubject() {
        guard subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        publishPromotionRequest()
    }

    func addRecipient(
        _ suggestion: ComposeRecipientSuggestion,
        to field: ComposeRecipientField.Kind,
        context _: ModelContext
    ) {
        let parsed = ComposeAddressEncoding.ParsedAddress(
            displayName: suggestion.name.isEmpty ? nil : suggestion.name,
            asciiAddress: suggestion.address
        )
        let normalized = normalizedAddress(parsed.asciiAddress)
        guard (toChips + ccChips + bccChips).contains(where: {
            normalizedAddress($0.asciiAddress) == normalized
        }) == false else {
            return
        }

        switch field {
        case .to:
            toChips.append(parsed)
        case .cc:
            ccChips.append(parsed)
        case .bcc:
            bccChips.append(parsed)
        }
        publishPromotionRequest()
    }

    func removeToChip(at index: Int, context _: ModelContext) {
        guard toChips.indices.contains(index) else { return }
        toChips.remove(at: index)
    }

    func removeCcChip(at index: Int, context _: ModelContext) {
        guard ccChips.indices.contains(index) else { return }
        ccChips.remove(at: index)
    }

    func removeBccChip(at index: Int, context _: ModelContext) {
        guard bccChips.indices.contains(index) else { return }
        bccChips.remove(at: index)
    }

    private func publishPromotionRequest() {
        promotionRequest = ComposerProvisionalComposeRequest(
            subject: subject,
            to: toChips,
            cc: ccChips,
            bcc: bccChips,
            identityID: selectedIdentity?.id,
            signatureSlotID: selectedSignatureSlotID
        )
    }

    private func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
