import Contacts
import Foundation
import SwiftData
import SwiftUI
import OhiaCore
import OhiaML
import OhiaMessagesReaderProtocol

extension EnvironmentValues {
    @Entry var messagesTranscriptBroker: MessagesTranscriptBroker?
}

struct ResolvedMessagesContact: Equatable, Sendable {
    let correspondentName: String
    let emailHandles: [String]
    let phoneHandles: [String]
}

protocol MessagesContactResolving: Sendable {
    func resolve(address: String) async -> ResolvedMessagesContact?
    func resolve(identifier: String) async -> ResolvedMessagesContact?
}

final class ContactsMessagesContactResolver: MessagesContactResolving, @unchecked Sendable {
    func resolve(address: String) async -> ResolvedMessagesContact? {
        guard Self.contactsUsable else { return nil }
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let predicate = normalized.contains("@")
            ? CNContact.predicateForContacts(matchingEmailAddress: normalized)
            : CNContact.predicateForContacts(
                matching: CNPhoneNumber(stringValue: normalized)
            )
        guard let contact = try? CNContactStore().unifiedContacts(
            matching: predicate,
            keysToFetch: Self.contactKeys
        ).first else {
            return nil
        }
        return Self.resolution(for: contact)
    }

    func resolve(identifier: String) async -> ResolvedMessagesContact? {
        guard Self.contactsUsable,
              let contact = try? CNContactStore().unifiedContact(
                withIdentifier: identifier,
                keysToFetch: Self.contactKeys
              ) else {
            return nil
        }
        return Self.resolution(for: contact)
    }

    private static var contactsUsable: Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            true
        default:
            false
        }
    }

    private static var contactKeys: [CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
    }

    private static func resolution(for contact: CNContact) -> ResolvedMessagesContact {
        let formattedName = CNContactFormatter.string(from: contact, style: .fullName)
            ?? "\(contact.givenName) \(contact.familyName)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        return ResolvedMessagesContact(
            correspondentName: formattedName.isEmpty ? "the correspondent" : formattedName,
            emailHandles: contact.emailAddresses.map {
                ($0.value as String)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            },
            phoneHandles: contact.phoneNumbers.map {
                String($0.value.stringValue.unicodeScalars.filter {
                    CharacterSet.decimalDigits.contains($0)
                })
            }
        )
    }
}

final class MessagesTranscriptBroker: MessagesTranscriptProviding, @unchecked Sendable {
    typealias ResultObserver = @Sendable (
        AutomaticMessagesResult,
        AutomaticMessagesRequest
    ) -> Void

    private let contactResolver: any MessagesContactResolving
    private let reader: any MessagesReaderClient
    private let now: @Sendable () -> Date
    private let requestAuthorizer: @MainActor @Sendable (AutomaticMessagesRequest) -> Bool
    private let observerLock = NSLock()
    private var resultObserver: ResultObserver?

    init(
        contactResolver: any MessagesContactResolving = ContactsMessagesContactResolver(),
        reader: any MessagesReaderClient = MessagesReaderXPCClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        resultObserver: ResultObserver? = nil,
        requestAuthorizer: @escaping @MainActor @Sendable (
            AutomaticMessagesRequest
        ) -> Bool = { _ in true }
    ) {
        self.contactResolver = contactResolver
        self.reader = reader
        self.now = now
        self.resultObserver = resultObserver
        self.requestAuthorizer = requestAuthorizer
    }

    @MainActor
    convenience init(
        modelContainer: ModelContainer,
        contactResolver: any MessagesContactResolving,
        reader: any MessagesReaderClient,
        now: @escaping @Sendable () -> Date = Date.init,
        resultObserver: ResultObserver? = nil
    ) {
        self.init(
            contactResolver: contactResolver,
            reader: reader,
            now: now,
            resultObserver: resultObserver
        ) { request in
            Self.isAuthorized(request, in: ModelContext(modelContainer))
        }
    }

    @MainActor
    convenience init(modelContainer: ModelContainer) {
        self.init(
            modelContainer: modelContainer,
            contactResolver: ContactsMessagesContactResolver(),
            reader: MessagesReaderXPCClient()
        )
    }

    func setResultObserver(_ observer: ResultObserver?) {
        observerLock.withLock {
            resultObserver = observer
        }
    }

    func transcript(for request: AutomaticMessagesRequest) async -> AutomaticMessagesResult {
        let result = await transcript(
            forAddress: request.correspondentAddress,
            limit: request.limit,
            maxAge: request.maxAge
        )
        let observer = observerLock.withLock { resultObserver }
        observer?(result, request)
        return result
    }

    func transcript(
        forAddress address: String,
        limit: Int,
        maxAge: TimeInterval
    ) async -> AutomaticMessagesResult {
        guard let contact = await contactResolver.resolve(address: address) else {
            return .contactNotFound
        }
        return await transcript(for: contact, limit: limit, maxAge: maxAge)
    }

    func transcript(
        forContactID identifier: String,
        limit: Int,
        maxAge: TimeInterval
    ) async -> AutomaticMessagesResult {
        guard let contact = await contactResolver.resolve(identifier: identifier) else {
            return .contactNotFound
        }
        return await transcript(for: contact, limit: limit, maxAge: maxAge)
    }

    func accessStatus() async -> Bool {
        await reader.accessStatus()
    }

    func resolveMessagesTranscript(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        Task {
            guard let request = try? JSONDecoder().decode(
                AutomaticMessagesRequest.self,
                from: requestData
            ) else {
                reply(nil, Self.error("Invalid Messages transcript request"))
                return
            }
            guard await requestAuthorizer(request) else {
                reply(nil, Self.error("Messages transcript request was denied"))
                return
            }
            let result = await transcript(for: request)
            guard let responseData = try? JSONEncoder().encode(result) else {
                reply(nil, Self.error("Unable to encode Messages transcript response"))
                return
            }
            reply(responseData, nil)
        }
    }

    private func transcript(
        for contact: ResolvedMessagesContact,
        limit: Int,
        maxAge: TimeInterval
    ) async -> AutomaticMessagesResult {
        guard !contact.emailHandles.isEmpty || !contact.phoneHandles.isEmpty else {
            return .noMatchingChat
        }
        let response = await reader.recentTranscript(MessagesReaderRequest(
            emailHandles: contact.emailHandles,
            phoneHandles: contact.phoneHandles,
            limit: limit,
            cutoff: now().addingTimeInterval(-maxAge)
        ))
        switch response.status {
        case .found:
            return .found(AutomaticMessagesTranscript(
                correspondentName: contact.correspondentName,
                lines: response.lines.map {
                    AutomaticMessagesTranscript.Line(
                        date: $0.date,
                        isFromMe: $0.isFromMe,
                        text: $0.text
                    )
                }
            ))
        case .noMatchingChat:
            return .noMatchingChat
        case .databaseUnavailable:
            return .contactResolvedDatabaseUnavailable
        case .serviceUnavailable:
            return .unavailable
        }
    }

    @MainActor
    private static func isAuthorized(
        _ request: AutomaticMessagesRequest,
        in context: ModelContext
    ) -> Bool {
        switch request.context {
        case .compose(let draftID):
            let descriptor = FetchDescriptor<Draft>(
                predicate: #Predicate<Draft> { $0.id == draftID }
            )
            guard let draft = try? context.fetch(descriptor).first,
                  draft.kind == .userCompose,
                  let currentAddress = ComposeAddressEncoding.decode(
                    draft.composeToJSON
                  ).first else {
                return false
            }
            return normalizedAddress(currentAddress) == request.correspondentAddress

        case .reply(let messageID, let draftID):
            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == messageID }
            )
            guard let message = try? context.fetch(descriptor).first,
                  !message.isSentByUser,
                  normalizedAddress(message.fromAddress) == request.correspondentAddress else {
                return false
            }
            guard let draftID else { return true }
            let draftDescriptor = FetchDescriptor<Draft>(
                predicate: #Predicate<Draft> { $0.id == draftID }
            )
            guard let draft = try? context.fetch(draftDescriptor).first else {
                return false
            }
            return draft.kind != .userCompose && draft.message?.id == messageID
        }
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "org.jgkarlin.Ohia.MessagesTranscriptBroker",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
