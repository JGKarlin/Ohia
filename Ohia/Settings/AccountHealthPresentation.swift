import SwiftUI
import OhiaCore
import OhiaMail

struct AccountHealthPresentation {
    enum Severity {
        case ready
        case warning
        case attention

        var tint: Color {
            switch self {
            case .ready:
                return OhiaColors.accentGreen
            case .warning:
                return OhiaColors.accentOrange
            case .attention:
                return OhiaColors.ohiaRed
            }
        }
    }

    enum CredentialAction {
        case outgoing(requiresFreshOAuth: Bool)
        case imap
    }

    let severity: Severity
    let badge: String
    let title: String
    let detail: String?
    let systemImage: String
    let actionTitle: String?
    let action: CredentialAction?

    var requiresAttention: Bool {
        severity != .ready
    }

    static func make(for account: Account) -> AccountHealthPresentation {
        let smtpConfigured = hasValue(account.smtpHost) && hasValue(account.smtpKeychainRef)
        let imapConfigured = hasValue(account.imapHost) && hasValue(account.imapKeychainRef)
        let providerKnown = MailProviderRegistry.lookup(
            email: account.emailAddress,
            smtpHost: account.smtpHost,
            imapHost: account.imapHost
        ) != nil

        if account.needsReauth && account.needsImapReauth {
            return AccountHealthPresentation(
                severity: .attention,
                badge: "Needs reauth",
                title: "Account credentials need attention",
                detail: "Sign in again to restore sending and live sync for this account.",
                systemImage: "exclamationmark.triangle.fill",
                actionTitle: "Reauthorize…",
                action: .outgoing(requiresFreshOAuth: true)
            )
        }

        if account.needsReauth {
            return AccountHealthPresentation(
                severity: .attention,
                badge: "Sending paused",
                title: "Sending needs reauthorization",
                detail: "Outgoing mail is paused until this account signs in again.",
                systemImage: "paperplane.fill",
                actionTitle: "Reauthorize sending…",
                action: .outgoing(requiresFreshOAuth: true)
            )
        }

        if account.needsImapReauth {
            return AccountHealthPresentation(
                severity: .attention,
                badge: "Sync paused",
                title: "Live sync needs reauthorization",
                detail: "Incoming mail sync is paused until IMAP access is restored.",
                systemImage: "tray.full.fill",
                actionTitle: "Reauthorize live sync…",
                action: .imap
            )
        }

        if !smtpConfigured && !imapConfigured {
            return AccountHealthPresentation(
                severity: .warning,
                badge: "Setup needed",
                title: "Mail access is not fully configured",
                detail: "Configure account credentials to enable sending and live sync.",
                systemImage: "envelope.fill",
                actionTitle: "Configure account…",
                action: .outgoing(requiresFreshOAuth: false)
            )
        }

        if !smtpConfigured {
            return AccountHealthPresentation(
                severity: .warning,
                badge: "Sending setup",
                title: "Sending is not configured",
                detail: "Configure outgoing mail to send confirmed drafts from this account.",
                systemImage: "paperplane",
                actionTitle: "Configure outgoing…",
                action: .outgoing(requiresFreshOAuth: false)
            )
        }

        if !imapConfigured {
            if providerKnown {
                return AccountHealthPresentation(
                    severity: .warning,
                    badge: "Live sync setup",
                    title: "Live sync is not set up",
                    detail: "Enable IMAP live sync so Ohia can keep receiving new mail.",
                    systemImage: "tray",
                    actionTitle: "Set up IMAP…",
                    action: .imap
                )
            }
            return AccountHealthPresentation(
                severity: .warning,
                badge: "Manual setup",
                title: "Manual live sync setup needed",
                detail: "This provider needs manual IMAP settings before live sync can run.",
                systemImage: "tray",
                actionTitle: nil,
                action: nil
            )
        }

        return AccountHealthPresentation(
            severity: .ready,
            badge: "Ready",
            title: "Account ready",
            detail: nil,
            systemImage: "checkmark.circle.fill",
            actionTitle: nil,
            action: nil
        )
    }

    private static func hasValue(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct AccountHealthBadge: View {
    let presentation: AccountHealthPresentation

    var body: some View {
        Label(presentation.badge, systemImage: presentation.systemImage)
            .font(.system(size: 10, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(presentation.severity.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(presentation.severity.tint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(presentation.severity.tint.opacity(0.25), lineWidth: 1)
            )
            .accessibilityLabel(presentation.badge)
    }
}

struct AccountHealthCallout: View {
    let presentation: AccountHealthPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(presentation.severity.tint)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(presentation.severity.tint.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(presentation.severity.tint.opacity(0.20), lineWidth: 1)
        )
    }
}
