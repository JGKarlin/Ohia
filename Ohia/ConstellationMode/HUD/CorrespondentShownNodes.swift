import Foundation
import OhiaCore

/// The Correspondent hover card's trimmed-nodes caption: how many of a
/// person's in-scope emails the scene draws on their ring, shown only when
/// the scene's node caps hid some of the emails placed for them.
enum CorrespondentShownNodes {
    /// The person's emails drawn as visible nodes on their own ring, or nil
    /// when the caption should not appear. Only the person's own trim
    /// counts: `placedMessageIds` are the emails the People layout placed
    /// for them before the caps, so mail that has no position yet never
    /// triggers the caption, and trimming elsewhere in the scene does not
    /// either.
    static func shownCount(
        placedMessageIds: Set<String>,
        drawnMessageIds: Set<String>,
        messageCount: Int
    ) -> Int? {
        guard messageCount > 0, placedMessageIds.isEmpty == false else { return nil }
        let shown = placedMessageIds.reduce(0) { count, messageId in
            drawnMessageIds.contains(messageId) ? count + 1 : count
        }
        guard shown < placedMessageIds.count, shown < messageCount else { return nil }
        return shown
    }

    /// Message ids drawn as visible nodes on `hubEmail`'s ring. A shared
    /// email appears once per ring it sits on, so only this person's
    /// placements count, and faded background satellites in a correspondent
    /// lock are not visible nodes.
    static func drawnMessageIds(
        onRingOf hubEmail: String,
        stars: [MessageStarInstance]
    ) -> Set<String> {
        let hub = normalizedEmail(hubEmail)
        var drawn = Set<String>()
        for star in stars where !star.fadesWithPeopleContext {
            guard let owner = star.peopleHubEmail, normalizedEmail(owner) == hub else { continue }
            drawn.insert(star.messageId)
        }
        return drawn
    }

    static func caption(shown: Int, messageCount: Int) -> String {
        "\(shown.formatted(.number)) of \(messageCount.formatted(.number)) shown as nodes"
    }

    private static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
