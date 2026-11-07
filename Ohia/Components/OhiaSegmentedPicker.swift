// Ohia/Components/OhiaSegmentedPicker.swift
// A mutually-exclusive segmented selector styled as Constellation toolbar
// chips rather than the native macOS segmented control.
//
// The native `.pickerStyle(.segmented)` renders its selected segment as a
// SOLID accent fill with contrasting (black) label text. Under Ohia's
// active-filter accent that reads as a yellow block with black text — out
// of register with §18, where the active accent is the *text* color on a
// faint tinted fill. This control instead composes `FilterChipLabel` (the
// exact toolbar chip), so the selected option reads as yellow-on-faint
// (dark) / deepened-green-on-faint (light) with a 1pt accent border —
// identical to the toolbar's status / frame chips.

import SwiftUI

struct OhiaSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { value in
                Button {
                    selection = value
                } label: {
                    FilterChipLabel(text: title(value), isOn: value == selection)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(value))
                .accessibilityAddTraits(value == selection ? [.isSelected] : [])
            }
        }
    }
}
