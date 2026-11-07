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

    public static func deleteAll(
        service: String,
        allowUserInteraction: Bool = allowsUserInteractionByDefault
    ) throws {
        let query = authenticatedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ], allowUserInteraction: allowUserInteraction)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.unexpected(status)
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
