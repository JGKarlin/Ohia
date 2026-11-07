// Ohia/Settings/IdentitySheet.swift
// Create/edit modal for an Identity row. Address is validated with
// MailAddressParser.parseOne and lowercased on save. In edit mode, if any
// past OutboxItem references the current address, the Address field is
// disabled — historical sent mail must not be retroactively rewritten.

import SwiftUI
import SwiftData
import OhiaCore
import OhiaMail
import OhiaScheduler

struct IdentitySheet: View {
    enum Mode: Identifiable {
        case create(Account)    // new identity on this account
        case edit(Identity)     // existing identity

        var id: UUID {
            switch self {
            case .create(let account): return account.id
            case .edit(let identity):  return identity.id
            }
        }
    }

    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var address: String = ""
    @State private var displayName: String = ""
    @State private var replyTo: String = ""
    @State private var addressError: String? = nil
    @State private var replyToError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.headline)
                Text("An address you send mail from, plus the name shown to recipients. Signatures are managed per account in Settings → Signatures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    IdentityFormSection(
                        title: addressTitle,
                        error: addressError,
                        footnote: shouldDisableAddress
                            ? "Editing this address is disabled because past sent mail already references it. Create a new identity instead."
                            : nil
                    ) {
                        IdentityTextInput(
                            label: addressTitle,
                            text: $address,
                            isDisabled: shouldDisableAddress
                        )
                        .onChange(of: address) { _, new in
                            let lowered = new.lowercased()
                            if lowered != new { address = lowered }
                        }
                    }

                    IdentityFormSection(
                        title: "Your name (From)",
                        footnote: "Shown to recipients in the From line. Leave blank to send as just the address."
                    ) {
                        IdentityTextInput(label: "Your name (From)", text: $displayName)
                    }

                    IdentityFormSection(
                        title: "Reply-To (optional)",
                        error: replyToError,
                        footnote: "Where replies are directed, if different from the address above."
                    ) {
                        IdentityTextInput(label: "Reply-To", text: $replyTo)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .frame(minWidth: 480, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { load() }
    }

    private var titleText: String {
        switch mode {
        case .create: return "Add alias or identity"
        case .edit:   return "Edit identity"
        }
    }

    private var addressTitle: String {
        switch mode {
        case .create: return "Address or alias"
        case .edit: return "Address"
        }
    }

    private var shouldDisableAddress: Bool {
        guard case .edit(let ident) = mode else { return false }
        let descriptor = FetchDescriptor<OutboxItem>()
        guard let items = try? modelContext.fetch(descriptor) else { return false }
        return items.contains { $0.fromAddress == ident.address }
    }

    private func load() {
        switch mode {
        case .create:
            break
        case .edit(let ident):
            address = ident.address
            displayName = ident.displayName ?? ""
            replyTo = ident.replyTo ?? ""
        }
    }

    private func save() {
        addressError = nil
        replyToError = nil

        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try MailAddressParser.parseOne(trimmedAddress)
        } catch {
            addressError = "Invalid email address"
            return
        }

        let trimmedReplyTo = replyTo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReplyTo.isEmpty {
            do {
                _ = try MailAddressParser.parseOne(trimmedReplyTo)
            } catch {
                replyToError = "Invalid email address"
                return
            }
        }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .create(let account):
            let ident = Identity(
                address: trimmedAddress,
                displayName: trimmedDisplayName.isEmpty ? nil : trimmedDisplayName,
                replyTo: trimmedReplyTo.isEmpty ? nil : trimmedReplyTo,
                isPrimary: false
            )
            ident.account = account
            modelContext.insert(ident)

        case .edit(let ident):
            ident.address = trimmedAddress.lowercased()
            ident.displayName = trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
            ident.replyTo = trimmedReplyTo.isEmpty ? nil : trimmedReplyTo
        }

        do {
            try modelContext.save()
            let repaired = try AliasSentDirectionRepairApplier(modelContext: modelContext).run()
            if repaired > 0 {
                print("[Ohia] Alias sent-direction repair: updated \(repaired) message row(s)")
            }
            NotificationCenter.default.post(name: .ohiaAccountIdentityChanged, object: nil)
        } catch {
            print("[Ohia] Identity save failed: \(String(reflecting: type(of: error)))")
        }
        dismiss()
    }
}

extension Notification.Name {
    static let ohiaAccountIdentityChanged = Notification.Name("ohia.account.identity-changed")
}

private struct IdentityFormSection<Content: View>: View {
    let title: String
    let error: String?
    let footnote: String?
    let content: Content

    init(
        title: String,
        error: String? = nil,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.error = error
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            content

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(OhiaColors.ohiaRed)
            }

            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IdentityTextInput: View {
    let label: String
    @Binding var text: String
    var isDisabled = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(OhiaColors.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(fieldBackground)
            .overlay(fieldBorder)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.72 : 1)
            .accessibilityLabel(label)
    }

    private var fieldBackground: some ShapeStyle {
        OhiaColors.surface(0.05)
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
    }
}

