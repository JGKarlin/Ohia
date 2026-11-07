import Foundation
import OhiaCore

protocol GmailMessageTrashing: Sendable {
    func moveMessagesToTrash(matchingMessageID messageID: String, accessToken: String) async throws
    func restoreMessagesFromTrash(matchingMessageID messageID: String, accessToken: String) async throws
}

struct GmailMessageAPIResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol GmailMessageAPITransport: Sendable {
    func send(_ request: URLRequest) async throws -> GmailMessageAPIResponse
}

struct URLSessionGmailMessageAPITransport: GmailMessageAPITransport {
    func send(_ request: URLRequest) async throws -> GmailMessageAPIResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GmailMessageAPIError.invalidResponse
        }
        return GmailMessageAPIResponse(data: data, statusCode: http.statusCode)
    }
}

/// Provider-authoritative Gmail Trash operation.
///
/// Gmail exposes the same logical message through several IMAP label folders,
/// so a stale folder UID can legally yield IMAP `OK` without moving anything.
/// Resolve the immutable Gmail message resource by RFC Message-ID, trash every
/// matching resource, and require Gmail's response to prove `TRASH` is present
/// and `INBOX` is absent before returning success.
struct GmailMessageAPIClient: GmailMessageTrashing {
    private struct MessageListResponse: Decodable {
        struct MessageReference: Decodable {
            let id: String
        }

        let messages: [MessageReference]?
        let nextPageToken: String?
    }

    private struct MessageResponse: Decodable {
        let id: String
        let labelIds: [String]?
    }

    private struct ModifyLabelsRequest: Encodable {
        let addLabelIds: [String]
        let removeLabelIds: [String]
    }

    private let transport: any GmailMessageAPITransport

    init(transport: any GmailMessageAPITransport = URLSessionGmailMessageAPITransport()) {
        self.transport = transport
    }

    func moveMessagesToTrash(matchingMessageID messageID: String, accessToken: String) async throws {
        let normalizedMessageID = try Self.validatedMessageID(messageID)
        let messageIDs = try await matchingMessageIDs(
            messageID: normalizedMessageID,
            accessToken: accessToken
        )

        guard messageIDs.isEmpty == false else {
            throw GmailMessageAPIError.messageIdentityNotFound(messageID: normalizedMessageID)
        }
        for messageID in messageIDs.sorted() {
            try await moveMessageToTrash(id: messageID, accessToken: accessToken)
        }
    }

    func restoreMessagesFromTrash(matchingMessageID messageID: String, accessToken: String) async throws {
        let normalizedMessageID = try Self.validatedMessageID(messageID)
        let messageIDs = try await matchingMessageIDs(
            messageID: normalizedMessageID,
            accessToken: accessToken
        )

        guard messageIDs.isEmpty == false else {
            throw GmailMessageAPIError.messageIdentityNotFound(messageID: normalizedMessageID)
        }
        for messageID in messageIDs.sorted() {
            try await restoreMessageFromTrash(id: messageID, accessToken: accessToken)
        }
    }

    private func matchingMessageIDs(messageID: String, accessToken: String) async throws -> Set<String> {
        var pageToken: String?
        var messageIDs = Set<String>()

        repeat {
            var components = URLComponents(
                string: "https://gmail.googleapis.com/gmail/v1/users/me/messages"
            )!
            var queryItems = [
                URLQueryItem(name: "q", value: "rfc822msgid:\(messageID)"),
                URLQueryItem(name: "maxResults", value: "500"),
                URLQueryItem(name: "includeSpamTrash", value: "true"),
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems
            // Gmail query decoding treats a bare '+' as a space. Preserve
            // literal plus signs in Message-IDs and pagination tokens.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            guard let url = components.url else {
                throw GmailMessageAPIError.invalidRequest
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let response = try await transport.send(request)
            try Self.requireSuccess(response)
            let list: MessageListResponse
            do {
                list = try JSONDecoder().decode(MessageListResponse.self, from: response.data)
            } catch {
                throw GmailMessageAPIError.invalidResponse
            }
            messageIDs.formUnion((list.messages ?? []).map(\.id))
            pageToken = list.nextPageToken
        } while pageToken != nil

        return messageIDs
    }

    private func moveMessageToTrash(id: String, accessToken: String) async throws {
        let allowedPathCharacters = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowedPathCharacters),
              let url = URL(
                string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(encodedID)/trash"
              ) else {
            throw GmailMessageAPIError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.send(request)
        // Another client may permanently remove the message between lookup and
        // mutation. A 404 then proves it cannot remain in Inbox.
        if response.statusCode == 404 { return }
        try Self.requireSuccess(response)

        let message: MessageResponse
        do {
            message = try JSONDecoder().decode(MessageResponse.self, from: response.data)
        } catch {
            throw GmailMessageAPIError.invalidResponse
        }
        let labels = Set(message.labelIds ?? [])
        guard message.id == id,
              labels.contains("TRASH"),
              labels.contains("INBOX") == false else {
            throw GmailMessageAPIError.trashStateNotConfirmed(messageID: id)
        }
    }

    private func restoreMessageFromTrash(id: String, accessToken: String) async throws {
        let allowedPathCharacters = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowedPathCharacters),
              let url = URL(
                string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(encodedID)/modify"
              ) else {
            throw GmailMessageAPIError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(
                ModifyLabelsRequest(
                    addLabelIds: ["INBOX"],
                    removeLabelIds: ["TRASH"]
                )
            )
        } catch {
            throw GmailMessageAPIError.invalidRequest
        }

        let response = try await transport.send(request)
        try Self.requireSuccess(response)

        let message: MessageResponse
        do {
            message = try JSONDecoder().decode(MessageResponse.self, from: response.data)
        } catch {
            throw GmailMessageAPIError.invalidResponse
        }
        let labels = Set(message.labelIds ?? [])
        guard message.id == id,
              labels.contains("INBOX"),
              labels.contains("TRASH") == false else {
            throw GmailMessageAPIError.restoreStateNotConfirmed(messageID: id)
        }
    }

    private static func validatedMessageID(_ value: String) throws -> String {
        guard let canonical = canonicalProviderMessageID(value) else {
            throw GmailMessageAPIError.invalidMessageID
        }
        return canonical
    }

    private static func requireSuccess(_ response: GmailMessageAPIResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw GmailMessageAPIError.requestFailed(statusCode: response.statusCode)
        }
    }
}

enum GmailMessageAPIError: Error, Equatable, LocalizedError {
    case invalidMessageID
    case invalidRequest
    case invalidResponse
    case requestFailed(statusCode: Int)
    case messageIdentityNotFound(messageID: String)
    case trashStateNotConfirmed(messageID: String)
    case restoreStateNotConfirmed(messageID: String)

    var errorDescription: String? {
        switch self {
        case .invalidMessageID:
            "Gmail Trash requires a valid Message-ID."
        case .invalidRequest:
            "Gmail Trash could not construct a valid request."
        case .invalidResponse:
            "Gmail Trash received an invalid response."
        case .requestFailed(let statusCode):
            "Gmail Trash failed with HTTP \(statusCode)."
        case .messageIdentityNotFound(let messageID):
            "Gmail could not prove the provider identity for \(messageID)."
        case .trashStateNotConfirmed(let messageID):
            "Gmail did not confirm that message \(messageID) left Inbox and reached Trash."
        case .restoreStateNotConfirmed(let messageID):
            "Gmail did not confirm that message \(messageID) left Trash and reached Inbox."
        }
    }
}
