import NIOIMAPCore

/// Walks a `NIOIMAPCore.BodyStructure` and determines whether the message
/// has at least one attachment part, honoring the repo's inline-image-disposition
/// rule: many MUAs omit `Content-Disposition` on inline images, so
/// "image + Content-ID, no `attachment` disposition" is treated as inline,
/// not an attachment.
enum BodyStructureInspector {

    /// Returns `true` when at least one singlepart leaf in `structure` qualifies
    /// as an attachment. Returns `false` for an invalid or text-only body.
    static func hasAttachment(in structure: NIOIMAPCore.BodyStructure) -> Bool {
        var found = false
        structure.enumerateParts { _, part in
            guard case .singlepart(let sp) = part else { return }
            // Skip multipart containers — they only appear as .multipart,
            // and the guard above handles that. Only inspect leaf singleparts.
            if isAttachment(sp) {
                found = true
            }
        }
        return found
    }

    // MARK: - Private helpers

    private static func isAttachment(_ sp: BodyStructure.Singlepart) -> Bool {
        let disposition = sp.`extension`?.dispositionAndLanguage?.disposition

        // Rule 1: explicit attachment disposition → always an attachment.
        if disposition?.kind == .attachment {
            return true
        }

        // Rule 2: named part that is not an inline image.
        guard let filename = disposition?.filename, !filename.isEmpty else {
            return false
        }

        // A part with a filename is NOT an attachment when it is an inline image:
        // media top-level == image AND (disposition is inline OR Content-ID is set).
        // Only `.basic` needs to be checked here: NIOIMAPCore's `.text` kind carries
        // the text/* family and `.message` carries message/rfc822 — neither can have
        // an image top-level, so checking `.basic` alone is complete.
        if case .basic(let mediaType) = sp.kind, mediaType.topLevel == .image {
            let isInlineDisposition = disposition?.kind == .inline
            let hasContentID = sp.fields.id.map { !$0.isEmpty } ?? false
            if isInlineDisposition || hasContentID {
                return false
            }
        }

        return true
    }
}
