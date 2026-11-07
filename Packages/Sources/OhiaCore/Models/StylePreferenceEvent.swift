import Foundation
import SwiftData

/// One SMTP-accepted style decision: explicit slider changes, or a saved
/// style's unchanged sliders. Preference events are separate from
/// `TrainingPair`: accepting a model-written body says which style the author
/// wanted for a correspondent even when it is not human-authored text that
/// should train the generative model. Resolution reuses the latest choice
/// for a correspondent, and saved styles count accepted sends toward learned
/// status.
@Model
public final class StylePreferenceEvent {
    public var id: UUID
    /// Stable post-send idempotency key.
    public var eventKey: String
    public var sourceOutboxID: UUID
    public var accountID: UUID
    public var correspondentAddress: String?
    public var languageID: String
    /// Accepted authored portion of the sent body. It is a discovery exemplar,
    /// not automatically an optimizer completion.
    public var acceptedBodyText: String
    public var styleControlSnapshotJSON: String
    public var generatedTextWasEdited: Bool
    public var createdAt: Date

    /// The style worker stamps every event it has counted toward a saved
    /// style's learned status.
    public var evaluatedAt: Date?

    public init(
        id: UUID = UUID(),
        eventKey: String,
        sourceOutboxID: UUID,
        accountID: UUID,
        correspondentAddress: String?,
        languageID: String,
        acceptedBodyText: String,
        styleControlSnapshot: StyleControlSnapshot,
        generatedTextWasEdited: Bool,
        createdAt: Date = .now
    ) {
        self.id = id
        self.eventKey = eventKey
        self.sourceOutboxID = sourceOutboxID
        self.accountID = accountID
        self.correspondentAddress = correspondentAddress
        self.languageID = languageID
        self.acceptedBodyText = acceptedBodyText
        self.styleControlSnapshotJSON = styleControlSnapshot.jsonString ?? "{}"
        self.generatedTextWasEdited = generatedTextWasEdited
        self.createdAt = createdAt
    }

    public var styleControlSnapshot: StyleControlSnapshot? {
        StyleControlSnapshot.decodeJSON(styleControlSnapshotJSON)
    }
}
