// Ohia/Settings/Signatures/SignatureEditingPane.swift
// Stage 3 of the studio: hand-edit the chosen design in the composer's
// rich-text editor, side by side with a send-fidelity preview, then name
// and save the slot.

import OhiaCore
import SwiftUI

struct SignatureEditingStage: View {
    @Bindable var model: SignatureStudioModel
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                previewColumn
                    .frame(width: 250)
                    .frame(maxHeight: .infinity)
            }
            .padding(16)

            Rectangle().fill(OhiaColors.glassBorder).frame(height: 1)
            footer
        }
        .onChange(of: model.editorContent) {
            model.scheduleEditingPreviewRefresh()
        }
    }

    @ViewBuilder
    private var editor: some View {
        if model.editorFormat == .richText {
            // Format is settled on the studio's first step, so the editor's
            // own format switch is suppressed here — it would write to a
            // constant binding and silently do nothing.
            ComposerRichTextEditor(
                content: $model.editorContent,
                format: .constant(.richText),
                isEnabled: true,
                showsFormatPicker: false
            )
        } else {
            SignaturePlainTextEditor(content: $model.editorContent)
        }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Send preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if let html = model.editingPreviewHTML {
                    SignatureHTMLPreviewView(html: html)
                } else {
                    ScrollView {
                        Text(model.editorContent.string)
                            .font(.callout)
                            .foregroundStyle(OhiaColors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(OhiaColors.surface(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(OhiaColors.ohiaRed)
            }
            HStack(spacing: 12) {
                if model.editingSlot == nil {
                    Button {
                        model.backToCards()
                    } label: {
                        Label("Back to Designs", systemImage: "arrow.left")
                    }
                    .buttonStyle(.emblem)
                }

                TextField("Signature name", text: $model.slotName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(maxWidth: 220)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(OhiaColors.surface(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Toggle("Default for this account", isOn: $model.makeDefault)
                    .font(.caption)

                Spacer()

                Button {
                    onSave()
                } label: {
                    Label("Save Signature", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.emblem)
            }
        }
        .padding(12)
    }
}

/// Minimal bordered plain-text editor for plain-format signatures — the
/// rich formatting bar would be noise on content that ships as text/plain.
private struct SignaturePlainTextEditor: View {
    @Binding var content: NSAttributedString

    var body: some View {
        TextEditor(text: Binding(
            get: { content.string },
            set: { content = NSAttributedString(string: $0) }
        ))
        .font(.body)
        .foregroundStyle(OhiaColors.textPrimary)
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(OhiaColors.surface(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
