import Foundation
import LocalAuthentication
import Security

public enum KeychainHelpers {
    public enum Error: Swift.Error { case unexpected(OSStatus) }

    public static func isUserDeniedAccess(_ error: Swift.Error) -> Bool {
        guard case Error.unexpected(let status) = error else { return false }
        return status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
    }

    public static var allowsUserInteractionByDefault: Bool {
        !isWorkerProcess
    }

    /// True for Ohia XPC worker helpers, which must not trigger Keychain UI
    /// and should receive injectable secrets from the parent app instead.
    public static var isWorkerProcess: Bool {
        let processInfo = ProcessInfo.processInfo
        if processInfo.environment["OHIA_WORKER_ROLE"] != nil {
            return true
        }
        switch processInfo.processName {
        case "OhiaRetrievalWorker", "OhiaGenerativeWorker":
            return true
        default:
            return false
        }
    }

    public static func set(
        data: Data,
        service: String,
        account: String,
        allowUserInteraction: Bool = allowsUserInteractionByDefault
    ) throws {
        let query = authenticatedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ], allowUserInteraction: allowUserInteraction)

        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw Error.unexpected(updateStatus)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let retryStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if retryStatus != errSecSuccess { throw Error.unexpected(retryStatus) }
        default:
            throw Error.unexpected(status)
        }
    }

    public static func get(
        service: String,
        account: String,
        allowUserInteraction: Bool = allowsUserInteractionByDefault
    ) throws -> Data? {
        let query = authenticatedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ], allowUserInteraction: allowUserInteraction)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw Error.unexpected(status) }
        return item as? Data
    }

    public static func delete(
        service: String,
        account: String,
        allowUserInteraction: Bool = allowsUserInteractionByDefault
    ) throws {
        let query = authenticatedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ], allowUserInteraction: allowUserInteraction)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.unexpected(status)
        }
    }

    /// The outcome of removing every item for one service.
    public struct SweepResult: Equatable, Sendable {
        /// Items the keychain refused to delete.
        public let remaining: Int
        /// The status of the last refused deletion, for diagnostics.
        public let lastFailureStatus: OSStatus?

        public init(remaining: Int, lastFailureStatus: OSStatus?) {
            self.remaining = remaining
            self.lastFailureStatus = lastFailureStatus
        }
    }

    /// Removes every generic-password item for `service`, one item at a time.
    /// A bulk `SecItemDelete` on the macOS file-based keychain removes only
    /// the first match, so each item is enumerated and deleted by reference.
    /// An item the keychain will not release (for example one whose access
    /// control trusts a different build) no longer blocks the removal of the
    /// others; the result reports how many items are left instead of throwing.
    public static func sweep(
        service: String,
        allowUserInteraction: Bool = allowsUserInteractionByDefault
    ) -> SweepResult {
        var matches: CFTypeRef?
        let listing = SecItemCopyMatching(authenticatedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ], allowUserInteraction: allowUserInteraction) as CFDictionary, &matches)
        switch listing {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return SweepResult(remaining: 0, lastFailureStatus: nil)
        default:
            return SweepResult(remaining: remainingCount(service: service), lastFailureStatus: listing)
        }

        let items: [AnyObject]
        if let array = matches as? [AnyObject] {
            items = array
        } else if let single = matches {
            items = [single]
        } else {
            items = []
        }

        var remaining = 0
        var lastFailure: OSStatus?
        for item in items {
            let status = SecItemDelete(authenticatedQuery([
                kSecClass as String: kSecClassGenericPassword,
                kSecMatchItemList as String: [item],
            ], allowUserInteraction: allowUserInteraction) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                remaining += 1
                lastFailure = status
            }
        }
        return SweepResult(remaining: remaining, lastFailureStatus: lastFailure)
    }

    /// Counts the items left for `service` without prompting. An unreadable
    /// keychain counts as one item left, since none can be shown to be gone.
    private static func remainingCount(service: String) -> Int {
        let context = LAContext()
        context.interactionNotAllowed = true
        var matches: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
        ] as CFDictionary, &matches)
        switch status {
        case errSecSuccess:
            return max((matches as? [Any])?.count ?? 1, 1)
        case errSecItemNotFound:
            return 0
        default:
            return 1
        }
    }

    private static func authenticatedQuery(
        _ query: [String: Any],
        allowUserInteraction: Bool
    ) -> [String: Any] {
        guard !allowUserInteraction else { return query }
        let context = LAContext()
        context.interactionNotAllowed = true
        var copy = query
        copy[kSecUseAuthenticationContext as String] = context
        return copy
    }
}
