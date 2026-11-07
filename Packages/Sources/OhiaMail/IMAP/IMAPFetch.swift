import Foundation

public enum IMAPFetch {
    public struct Envelope: Sendable, Equatable {
        public let date: String?
        public let subject: String?
        public let from: [String]       // raw "Name <addr>" entries
        public let sender: [String]
        public let replyTo: [String]
        public let to: [String]
        public let cc: [String]
        public let bcc: [String]
        public let inReplyTo: String?
        public let messageID: String?
    }

    public struct Message: Sendable {
        public let uid: UInt32
        public let flags: Set<String>
        public let internalDate: Date?
        public let envelope: Envelope?
        public let rfc822Bytes: Data      // full raw message (from BODY.PEEK[]) or header block (from BODY.PEEK[HEADER.FIELDS ...])
        public let rfc822Size: Int?
        /// `true` when `BODYSTRUCTURE` was fetched and at least one non-inline part
        /// qualifies as an attachment under the repo's inline-image-disposition rule.
        /// `false` when `BODYSTRUCTURE` was not requested or the structure was invalid.
        public let hasAttachments: Bool

        public init(
            uid: UInt32,
            flags: Set<String>,
            internalDate: Date?,
            envelope: Envelope?,
            rfc822Bytes: Data,
            rfc822Size: Int?,
            hasAttachments: Bool
        ) {
            self.uid = uid
            self.flags = flags
            self.internalDate = internalDate
            self.envelope = envelope
            self.rfc822Bytes = rfc822Bytes
            self.rfc822Size = rfc822Size
            self.hasAttachments = hasAttachments
        }
    }
}
