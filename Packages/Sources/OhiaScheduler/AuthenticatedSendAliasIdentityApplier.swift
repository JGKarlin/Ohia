import Foundation
import SwiftData
import OhiaCore
import OhiaIngest

/// Infers missing send-as aliases from already-ingested raw messages when the
/// transport evidence shows the message was sent through this account's
/// authenticated SMTP path.
///
/// This is intentionally stricter than the Settings "Suggested aliases" scan:
/// a visible `From:` alias is promoted only when an owned envelope sender
/// (`Return-Path` / `Sender`) appears alongside an authenticated SMTP
/// `Received` hop. That catches Gmail/Apple Mail send-as copies while avoiding
/// ordinary inbound mail where a correspondent merely mentions one of the
/// user's addresses.
@MainActor
public final class AuthenticatedSendAliasIdentityApplier {
    private static let sampleLimitPerAlias = 12
    private static let maxHeaderBytes = 128 * 1024

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    public func run() throws -> Int {
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        var inserted = 0

        for account in accounts {
            inserted += try inferAliases(for: account)
        }

        return inserted
    }

    private func inferAliases(for account: Account) throws -> Int {
        let accountID = account.id
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.isSentByUser == false
                    && (message.accountID == accountID || message.account?.id == accountID)
            },
            sortBy: [SortDescriptor(\.ingestedAt, order: .reverse)]
        )
        let messages = try modelContext.fetch(descriptor)

        var buckets: [String: [Message]] = [:]
        for message in messages {
            let address = Self.normalize(message.fromAddress)
            guard !address.isEmpty, !account.ownsEmailAddress(address) else { continue }
            buckets[address, default: []].append(message)
        }

        var inserted = 0
        for (aliasAddress, aliasMessages) in buckets {
            let evidence = aliasMessages
                .prefix(Self.sampleLimitPerAlias)
                .filter { hasAuthenticatedSendEvidence($0, aliasAddress: aliasAddress, account: account) }
            guard !evidence.isEmpty else { continue }

            let displayName = mostFrequentFromName(in: Array(evidence))
            inserted += try DiscoveredAccountIdentityApplier.apply(
                identityEmailAddresses: [account.emailAddress, aliasAddress],
                displayName: displayName,
                to: account,
                in: modelContext,
                replaceBlankDisplayNames: false
            )
        }
        return inserted
    }

    private func hasAuthenticatedSendEvidence(
        _ message: Message,
        aliasAddress: String,
        account: Account
    ) -> Bool {
        guard let headers = Self.headerFields(for: message) else { return false }
        guard Self.headerAddress(named: "From", in: headers) == aliasAddress else {
            return false
        }
        guard Self.hasOwnedEnvelopeSender(in: headers, account: account) else {
            return false
        }
        return Self.hasAuthenticatedSMTPHop(in: headers)
    }

    private func mostFrequentFromName(in messages: [Message]) -> String? {
        var counts: [String: Int] = [:]
        for message in messages {
            let name = message.fromName
                .flatMap(Self.normalizedDisplayName)
                ?? Self.headerFields(for: message)
                    .flatMap { Self.headerDisplayName(named: "From", in: $0) }
            guard let name else {
                continue
            }
            counts[name, default: 0] += 1
        }
        return counts
            .max {
                if $0.value != $1.value { return $0.value < $1.value }
                return $0.key > $1.key
            }?
            .key
    }

    private static func headerFields(for message: Message) -> [Header]? {
        guard let rawPath = message.rawPath else { return nil }
        let url = URL(fileURLWithPath: rawPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxHeaderBytes), !data.isEmpty else {
            return nil
        }
        return MIMEParser.parseHeaderFields(data: data)
    }

    private static func hasOwnedEnvelopeSender(in headers: [Header], account: Account) -> Bool {
        for name in ["Return-Path", "Sender"] {
            guard let address = headerAddress(named: name, in: headers) else { continue }
            if account.ownsEmailAddress(address) {
                return true
            }
        }
        return false
    }

    private static func hasAuthenticatedSMTPHop(in headers: [Header]) -> Bool {
        headerValues(named: "Received", in: headers).contains { value in
            let lowered = value.lowercased()
            return lowered.contains(" with esmtpsa")
                || lowered.contains(" with esmtpa")
                || lowered.contains(" with smtp auth")
        }
    }

    private static func headerAddress(named name: String, in headers: [Header]) -> String? {
        headerValues(named: name, in: headers)
            .lazy
            .compactMap(normalizedAddress(from:))
            .first
    }

    private static func headerDisplayName(named name: String, in headers: [Header]) -> String? {
        headerValues(named: name, in: headers)
            .lazy
            .compactMap { ParticipantNormalizer.parse($0).first?.name }
            .compactMap(normalizedDisplayName)
            .first
    }

    private static func headerValues(named name: String, in headers: [Header]) -> [String] {
        let lowered = name.lowercased()
        return headers
            .filter { $0.name.lowercased() == lowered }
            .map(\.value)
    }

    private static func normalizedAddress(from headerValue: String) -> String? {
        if let parsed = ParticipantNormalizer.parse(headerValue).first?.email {
            return parsed
        }

        let stripped = headerValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
        guard stripped.contains("@") else { return nil }
        return stripped
    }

    private static func normalizedDisplayName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalize(_ address: String) -> String {
        address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
