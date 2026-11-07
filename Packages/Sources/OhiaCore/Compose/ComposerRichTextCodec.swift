import AppKit
import Foundation

/// Converts the Composer's AppKit editing model to and from the HTML body
/// persisted beside each draft's authoritative plain-text alternative.
public enum ComposerRichTextCodec {
    private static let defaultEditorFontSize: CGFloat = 15

    public static func content(
        plainText: String,
        html: String?,
        format: ComposerMessageFormat
    ) -> NSAttributedString {
        guard format == .richText,
              let html,
              let data = html.data(using: .utf8),
              let imported = try? NSMutableAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              ) else {
            return NSAttributedString(
                string: plainText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: defaultEditorFontSize)
                ]
            )
        }
        // Cocoa's HTML importer appends one document-terminating newline even
        // when the exported body did not contain it. `replyText` is the
        // authoritative plain alternative, so remove only that exact
        // synthetic suffix instead of making a reopened draft appear edited.
        if imported.string == plainText + "\n", imported.length > 0 {
            imported.deleteCharacters(in: NSRange(location: imported.length - 1, length: 1))
        }
        return imported
    }

    public static func exportHTML(
        _ content: NSAttributedString,
        format: ComposerMessageFormat
    ) -> String? {
        guard format == .richText else { return nil }

        let export = NSMutableAttributedString(attributedString: content)
        let fullRange = NSRange(location: 0, length: export.length)
        if export.length > 0 {
            var missingFontRanges: [NSRange] = []
            export.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                if value == nil { missingFontRanges.append(range) }
            }
            for range in missingFontRanges {
                export.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: defaultEditorFontSize),
                    range: range
                )
            }
        }

        guard let data = try? export.data(
            from: fullRange,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Projects editor content to the draft's plain-text body.
    /// `NSTextAttachment` runs render as U+FFFC in `.string`; image
    /// placeholders have no plain-text equivalent and must never reach the
    /// text/plain MIME alternative. One adjacent space is absorbed with
    /// each placeholder so inline images (headshot before the name) leave
    /// no stray indentation behind.
    public static func plainBodyProjection(of content: NSAttributedString) -> String {
        content.string
            .replacingOccurrences(of: "\u{fffc} ", with: "")
            .replacingOccurrences(of: " \u{fffc}", with: "")
            .replacingOccurrences(of: "\u{fffc}", with: "")
    }

    /// Replaces only the RFC 3676 signature tail with an attributed
    /// signature (rich slots: formatting and image attachments survive),
    /// preserving every attribute on the message body that precedes it.
    public static func swappingSignature(
        in content: NSAttributedString,
        newAttributedSignature: NSAttributedString?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        let markerRange = (result.string as NSString).range(
            of: SignatureSwapper.marker,
            options: .backwards
        )

        if markerRange.location != NSNotFound {
            result.deleteCharacters(in: NSRange(
                location: markerRange.location,
                length: result.length - markerRange.location
            ))
            if let newAttributedSignature {
                result.append(NSAttributedString(string: SignatureSwapper.marker))
                result.append(newAttributedSignature)
            }
        } else if let newAttributedSignature {
            result.append(NSAttributedString(string: "\n" + SignatureSwapper.marker))
            result.append(newAttributedSignature)
        }

        return result
    }

    /// Replaces only the RFC 3676 signature tail, preserving every attribute
    /// on the message body that precedes it.
    public static func swappingSignature(
        in content: NSAttributedString,
        newSignature: String?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        let markerRange = (result.string as NSString).range(
            of: SignatureSwapper.marker,
            options: .backwards
        )

        if markerRange.location != NSNotFound {
            result.deleteCharacters(in: NSRange(
                location: markerRange.location,
                length: result.length - markerRange.location
            ))
            if let newSignature {
                result.append(NSAttributedString(
                    string: SignatureSwapper.marker + newSignature
                ))
            }
        } else if let newSignature {
            result.append(NSAttributedString(
                string: "\n" + SignatureSwapper.marker + newSignature
            ))
        }

        return result
    }
}
