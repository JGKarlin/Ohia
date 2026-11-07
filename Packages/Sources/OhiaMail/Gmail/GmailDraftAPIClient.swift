import Foundation

protocol GmailDraftDeleting: Sendable {
    func deleteDrafts(matchingMessageID messageID: String, accessToken: String) async throws
}

struct GmailDraftAPIResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol GmailDraftAPITransport: Sendable {
    func send(_ request: URLRequest) async throws -> GmailDraftAPIResponse
}

struct URLSessionGmailDraftAPITransport: GmailDraftAPITransport {
    func send(_ request: URLRequest) async throws -> GmailDraftAPIResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GmailDraftAPIError.invalidResponse
        }
        return GmailDraftAPIResponse(data: data, statusCode: http.statusCode)
    }
}

struct GmailDraftAPIClient: GmailDraftDeleting {
    private struct DraftListResponse: Decodable {
        struct DraftReference: Decodable {
            let id: String
        }

        let drafts: [DraftReference]?
        let nextPageToken: String?
    }

    private let transport: any GmailDraftAPITransport

    init(transport: any GmailDraftAPITransport = URLSessionGmailDraftAPITransport()) {
        self.transport = transport
    }

    func deleteDrafts(matchingMessageID messageID: String, accessToken: String) async throws {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty else {
            throw GmailDraftAPIError.missingMessageID
        }

        let draftIDs = try await matchingDraftIDs(
            messageID: normalizedMessageID,
            accessToken: accessToken
        )
        for draftID in draftIDs {
            try await deleteDraft(id: draftID, accessToken: accessToken)
        }
        guard draftIDs.isEmpty == false else { return }
        let remainingDraftIDs = try await matchingDraftIDs(
            messageID: normalizedMessageID,
            accessToken: accessToken
        )
        guard remainingDraftIDs.isEmpty else {
            throw GmailDraftAPIError.deletionNotConfirmed
        }
    }

    private func matchingDraftIDs(messageID: String, accessToken: String) async throws -> Set<String> {
        var pageToken: String?
        var draftIDs = Set<String>()

        repeat {
            var components = URLComponents(
                string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts"
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
            guard let url = components.url else {
                throw GmailDraftAPIError.invalidRequest
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let response = try await transport.send(request)
            try Self.requireSuccess(response)
            let list: DraftListResponse
            do {
                list = try JSONDecoder().decode(DraftListResponse.self, from: response.data)
            } catch {
                throw GmailDraftAPIError.invalidResponse
            }
            draftIDs.formUnion((list.drafts ?? []).map(\.id))
            pageToken = list.nextPageToken
        } while pageToken != nil

        return draftIDs
    }

    private func deleteDraft(id: String, accessToken: String) async throws {
        let allowedPathCharacters = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowedPathCharacters),
              let url = URL(
                string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts/\(encodedID)"
              ) else {
            throw GmailDraftAPIError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.send(request)
        // A concurrent client may have already removed the draft after the list
        // request. Either a successful DELETE or a 404 proves it is now absent.
        guard response.statusCode == 404 || (200..<300).contains(response.statusCode) else {
            throw GmailDraftAPIError.requestFailed(statusCode: response.statusCode)
        }
    }

    private static func requireSuccess(_ response: GmailDraftAPIResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw GmailDraftAPIError.requestFailed(statusCode: response.statusCode)
        }
    }
}

public enum GmailDraftAPIError: Error, Equatable, LocalizedError {
    case missingMessageID
    case invalidRequest
    case invalidResponse
    case requestFailed(statusCode: Int)
    case deletionNotConfirmed

    public var errorDescription: String? {
        switch self {
        case .missingMessageID:
            "Gmail draft cleanup requires a Message-ID."
        case .invalidRequest:
            "Gmail draft cleanup could not construct a valid request."
        case .invalidResponse:
            "Gmail draft cleanup received an invalid response."
        case .requestFailed(let statusCode):
            "Gmail draft cleanup failed with HTTP \(statusCode)."
        case .deletionNotConfirmed:
            "Gmail still returned the discarded draft after deletion."
        }
    }
}
