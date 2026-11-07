// Ohia/Compose/ComposeSignaturePicker.swift
// Per-draft signature selector, mounted beside the From picker in both
// composer header rows. Lists the From account's saved slots plus
// "No Signature"; selection re-stamps the draft and swaps the RFC 3676
// tail in place (the host owns that mutation).

import OhiaCore
import SwiftUI

struct ComposeSignaturePicker: View {
    let slots: [SignatureSlot]
    /// The draft's stamped slot id; nil means "No Signature".
    @Binding var selectedSlotID: UUID?

    var body: some View {
        if !slots.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("SIGNATURE")
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .textCase(.uppercase)
                Picker("", selection: $selectedSlotID) {
                    Text("No Signature").tag(UUID?.none)
                    ForEach(slots, id: \.id) { slot in
                        Text(slot.name).tag(Optional(slot.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }
}
