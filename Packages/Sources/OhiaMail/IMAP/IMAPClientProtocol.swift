import Foundation
import OhiaCore

typealias IMAPClientFactory = @Sendable () -> any IMAPClienting

protocol IMAPClienting: Sendable {
    func connect(host: String, port: Int, security: IMAPSecurity, pinnedCertSHA256: String?) async throws
    func capability() async throws -> IMAPCapability
    func authenticatePlain(username: String, password: String) async throws
    func authenticateXOAuth2(username: String, accessToken: String) async throws
    func enableQresync() async throws
    func list() async throws -> [IMAPFolder]
    func selectWithMetadata(mailbox: String) async throws -> IMAPSelectQRESYNCResult
    func examineWithMetadata(mailbox: String) async throws -> IMAPSelectQRESYNCResult
    func selectWithQresync(
        mailbox: String,
        uidValidity: UInt32,
        highestModSeq: UInt64
    ) async throws -> IMAPSelectQRESYNCResult
    func uidSearchAll() async throws -> [UInt32]
    func uidSearch(range: ClosedRange<UInt32>) async throws -> [UInt32]
    func uidSearch(range: ClosedRange<UInt32>, since: Date) async throws -> [UInt32]
    func uidSearch(range: ClosedRange<UInt32>, since: Date?, gmailLabel: String) async throws -> [UInt32]
    func uidSearch(before: Date) async throws -> [UInt32]
    func uidSearchHeader(_ header: String, value: String) async throws -> [UInt32]
    func append(mailbox: String, flags: [String], date: Date?, payload: Data) async throws -> IMAPAppendResult
    func uidFetchStream(
        range: ClosedRange<UInt32>,
        attrs: IMAPFetchAttributes
    ) async -> AsyncThrowingStream<IMAPFetch.Message, Error>
    func uidFetchStream(
        uids: [UInt32],
        attrs: IMAPFetchAttributes
    ) async -> AsyncThrowingStream<IMAPFetch.Message, Error>
    func uidStore(uid: UInt32, op: IMAPStoreFlagOperation, flags: [String]) async throws
    func uidMove(uid: UInt32, mailbox: String) async throws
    func uidCopy(uid: UInt32, mailbox: String) async throws
    func uidExpunge(uid: UInt32) async throws
    func expunge() async throws
    func createMailbox(_ mailbox: String) async throws
    func beginIdle() async throws
    func readIdleEvent(timeout: TimeInterval) async throws -> IMAPUntaggedResponse?
    func endIdle() async throws
    func logout() async
    func close() async
}

extension IMAPClienting {
    func examineWithMetadata(mailbox: String) async throws -> IMAPSelectQRESYNCResult {
        throw IMAPError.protocolViolation("EXAMINE unsupported by test client")
    }

    func uidSearch(range: ClosedRange<UInt32>, since: Date?, gmailLabel: String) async throws -> [UInt32] {
        throw IMAPError.protocolViolation("X-GM-LABELS search unsupported by test client")
    }

    func uidSearch(before: Date) async throws -> [UInt32] {
        throw IMAPError.protocolViolation("UID SEARCH BEFORE unsupported by test client")
    }

    func uidSearchHeader(_ header: String, value: String) async throws -> [UInt32] {
        throw IMAPError.protocolViolation("UID SEARCH HEADER unsupported by test client")
    }

    func append(mailbox: String, flags: [String], date: Date?, payload: Data) async throws -> IMAPAppendResult {
        throw IMAPError.protocolViolation("APPEND unsupported by test client")
    }

    func uidMove(uid: UInt32, mailbox: String) async throws {
        throw IMAPError.protocolViolation("UID MOVE unsupported by test client")
    }

    func uidCopy(uid: UInt32, mailbox: String) async throws {
        throw IMAPError.protocolViolation("UID COPY unsupported by test client")
    }

    func createMailbox(_ mailbox: String) async throws {
        throw IMAPError.protocolViolation("CREATE unsupported by test client")
    }
}

extension IMAPClient: IMAPClienting {
    func uidFetchStream(
        range: ClosedRange<UInt32>,
        attrs: IMAPFetchAttributes
    ) async -> AsyncThrowingStream<IMAPFetch.Message, Error> {
        uidFetch(range: range, attrs: attrs)
    }

    func uidFetchStream(
        uids: [UInt32],
        attrs: IMAPFetchAttributes
    ) async -> AsyncThrowingStream<IMAPFetch.Message, Error> {
        let uidSet = uids.map(String.init).joined(separator: ",")
        return uidFetch(uidSet: uidSet, attrs: attrs)
    }
}
