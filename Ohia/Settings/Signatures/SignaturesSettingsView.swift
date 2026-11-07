// Ohia/Settings/Signatures/SignaturesSettingsView.swift
// Settings → Signatures: per-account saved signature slots plus the
// design studio (generate with the local model from the user's own
// contact card, iterate, hand-edit, save).

import OhiaCore
import OhiaML
import SwiftData
import SwiftUI

struct SignaturesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var appServices: AppServices?
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    @State private var selectedAccountID: UUID?
    @State private var studioModel: SignatureStudioModel?
    @State private var actionNotice: String?

    private var selectedAccount: Account? {
        accounts.first(where: { $0.id == selectedAccountID }) ?? accounts.first
    }

    var body: some View {
        // Card stack over the night sky, matching General/Sources: the header
        // sits on the sky, the picker + slot roster share one black card, and
        // the New Signature footer sits on the sky below it — the same shape
        // as Accounts' card + "Add another account" button.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if accounts.isEmpty {
                    Text("Add an email account first — signatures are saved per account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let account = selectedAccount {
                    OhiaSettingsCard {
                        SettingsBlock { accountPicker }
                        SettingsRowDivider()
                        SettingsBlock { slotList(for: account) }
                    }
                    footer(for: account)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .sheet(item: $studioModel) { model in
            SignatureStudioSheet(model: model) {
                studioModel = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Signatures")
                .font(.title2)
            Text("Design email signatures with the local model from your own contact card, then save them per account. New drafts start with the account's selected default, including No Signature; the composer can swap per email.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountPicker: some View {
        Picker("Account", selection: Binding(
            get: { selectedAccount?.id },
            set: { selectedAccountID = $0 }
        )) {
            ForEach(accounts, id: \.id) { account in
                Text(account.emailAddress).tag(Optional(account.id))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 340, alignment: .leading)
    }

    @ViewBuilder
    private func slotList(for account: Account) -> some View {
        // No inner ScrollView — the pane's outer scroll owns scrolling, and
        // the card grows to fit the roster.
        let slots = account.orderedSignatureSlots
        VStack(spacing: 6) {
            noSignatureRow(for: account)
            if slots.isEmpty {
                Text("No saved signatures for this account yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(slots, id: \.id) { slot in
                    slotRow(slot, account: account)
                }
            }
        }
    }

    private func noSignatureRow(for account: Account) -> some View {
        let isSelected = account.defaultSignatureSlot == nil
        return HStack(spacing: 10) {
            Button {
                setDefaultSignature(nil, for: account)
            } label: {
                Image(systemName: isSelected ? "circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected ? OhiaColors.chipActiveForeground : Color.secondary
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("No Signature")
            .accessibilityValue(isSelected ? "Default for new drafts" : "Not the default")
            .help(isSelected ? "New drafts start unsigned" : "Make No Signature the default")

            VStack(alignment: .leading, spacing: 2) {
                Text("No Signature")
                    .font(.callout)
                    .foregroundStyle(OhiaColors.textPrimary)
                Text("New drafts start unsigned")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OhiaColors.surface(0.04))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: 8))
    }

    private func slotRow(_ slot: SignatureSlot, account: Account) -> some View {
        HStack(spacing: 10) {
            Button {
                setDefaultSignature(slot, for: account)
            } label: {
                Image(systemName: account.defaultSignatureSlotID == slot.id ? "circle.fill" : "circle")
                    .foregroundStyle(
                        account.defaultSignatureSlotID == slot.id
                            ? OhiaColors.chipActiveForeground
                            : Color.secondary
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(slot.name)
            .accessibilityValue(account.defaultSignatureSlotID == slot.id
                ? "Default for new drafts"
                : "Not the default")
            .help(account.defaultSignatureSlotID == slot.id
                ? "Default signature for new drafts"
                : "Make default")

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.name)
                    .font(.callout)
                    .foregroundStyle(OhiaColors.textPrimary)
                HStack(spacing: 6) {
                    badge(slot.format.displayName)
                    if let tier = slot.tier {
                        badge(tier.displayName)
                    }
                    Text(previewLine(for: slot))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button("Edit") { openEditor(for: slot, account: account) }
                .buttonStyle(.emblem)
                .font(.caption)
            Button("Duplicate") { duplicate(slot, account: account) }
                .buttonStyle(.emblem)
                .font(.caption)
            Button("Delete") { delete(slot, account: account) }
                .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OhiaColors.surface(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Edit") { openEditor(for: slot, account: account) }
            Button("Duplicate") { duplicate(slot, account: account) }
            if account.defaultSignatureSlotID != slot.id {
                Button("Make Default") {
                    setDefaultSignature(slot, for: account)
                }
            }
            Button("Delete", role: .destructive) { delete(slot, account: account) }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(OhiaColors.surface(0.06))
            .overlay(
                Capsule().strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
            )
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
    }

    private func footer(for account: Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let actionNotice {
                Text(actionNotice)
                    .font(.caption)
                    .foregroundStyle(OhiaColors.ohiaRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    studioModel = SignatureStudioModel(account: account, services: appServices)
                } label: {
                    Label("New Signature", systemImage: "signature")
                }
                .buttonStyle(.emblem)
                .font(OhiaTypography.button)

                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func setDefaultSignature(_ slot: SignatureSlot?, for account: Account) {
        let previousSlotID = account.defaultSignatureSlotID
        account.defaultSignatureSlotID = slot?.id
        do {
            try modelContext.save()
            actionNotice = nil
        } catch {
            account.defaultSignatureSlotID = previousSlotID
            actionNotice = "Could not update the default signature: \(error.localizedDescription)"
        }
    }

    private func openEditor(for slot: SignatureSlot, account: Account) {
        studioModel = SignatureStudioModel(editing: slot, account: account, services: appServices)
    }

    private func duplicate(_ slot: SignatureSlot, account: Account) {
        let copy = SignatureSlot(
            name: "\(slot.name) copy",
            format: slot.format,
            plainText: slot.plainText,
            tier: slot.tier,
            sortOrder: (account.signatureSlots.map(\.sortOrder).max() ?? -1) + 1
        )
        copy.account = account
        let store = SignatureAssetStore()
        do {
            try store.duplicateAssets(from: slot.id, to: copy.id)
        } catch {
            print("[Ohia] Signature duplicate: asset copy failed: \(String(reflecting: type(of: error)))")
        }
        copy.images = slot.images
        // Rewrite the HTML's tokens to the copy's owner id so the copy
        // never references the original's files.
        if let html = slot.html {
            var rewritten = html
            for asset in slot.images {
                rewritten = rewritten.replacingOccurrences(
                    of: SignatureImageToken.url(ownerID: slot.id, assetID: asset.id),
                    with: SignatureImageToken.url(ownerID: copy.id, assetID: asset.id)
                )
            }
            copy.html = rewritten
        }
        modelContext.insert(copy)
        try? modelContext.save()
    }

    private func delete(_ slot: SignatureSlot, account: Account) {
        do {
            switch try SignatureSlotRetirement.retire(
                slot: slot, account: account, context: modelContext
            ) {
            case .deleted:
                actionNotice = nil
            case .blockedByQueuedMail(let count):
                let mail = count == 1 ? "a queued email" : "\(count) queued emails"
                actionNotice = "\(slot.name) is embedded in \(mail). Deliver or cancel that mail in the Outbox, then delete the signature."
            }
        } catch {
            actionNotice = "Could not delete \(slot.name): \(error.localizedDescription)"
        }
    }

    private func previewLine(for slot: SignatureSlot) -> String {
        slot.plainText
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
}

extension SignatureStudioModel: Identifiable {
    var id: UUID { sessionID }
}
