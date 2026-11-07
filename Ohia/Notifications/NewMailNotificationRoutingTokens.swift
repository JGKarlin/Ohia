import Foundation

@MainActor
final class NewMailNotificationRoutingTokens {
    static let shared = NewMailNotificationRoutingTokens()

    private var threadTokens: [LiveInboundNotificationGroup: String] = [:]

    func threadIdentifier(for group: LiveInboundNotificationGroup) -> String {
        if let token = threadTokens[group] {
            return token
        }
        let token = "ohia-thread-\(UUID().uuidString)"
        threadTokens[group] = token
        return token
    }
}
