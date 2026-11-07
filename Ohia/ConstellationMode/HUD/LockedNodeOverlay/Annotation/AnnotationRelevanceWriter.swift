import Foundation

struct AnnotationRelevanceWriter {
    func write(kind: AnnotationKind, title: String, centerSubject: String) -> String {
        let subject = centerSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .mainEmail:
            // The main email is its own kind in the tab loop but never an
            // AnnotationItem, so this writer is never invoked with it. The
            // case exists purely to satisfy the exhaustiveness check.
            return subject.isEmpty ? "The locked email." : subject
        case .correspondent:
            return "Focused correspondent in the People-layer slice."
        case .bodyChunk:
            return subject.isEmpty ? "Body evidence attached to the locked email." : "Supports the locked email body for \(subject)."
        case .attachment:
            return "Attachment vector linked to the locked email."
        case .entity:
            return "Entity vector connected to this message context."
        case .thread:
            return "Sibling message in the same conversation."
        case .reply:
            return "Reply you sent in the same thread."
        case .peopleInbound:
            return "Message sent by the focused correspondent."
        case .peopleReply:
            return "Reply sent to the focused correspondent."
        case .peopleShared:
            return "Third-party message including the focused correspondent."
        case .peopleReplyShared:
            return "Message you sent that included the focused correspondent alongside someone else."
        case .threadRelative:
            return "Same correspondent · semantically similar."
        case .topicRelative:
            return "Different correspondent · same topic."
        }
    }
}
