import Foundation

/// Length chooses useful prepared reply points. It never changes author
/// instructions or turns the incoming message's exposition into added detail.
struct ComposerPresentationPlan: Sendable, Equatable {
    let points: [ComposerReplyPlan.Passage]
    let supportingPassages: [ComposerBriefPassage]

    init(request: ComposerGenerationRequest, brief: ComposerContentBrief) {
        points = brief.replyPlan?.selected(length: request.presentation.lengthPoint,
            additionalSourcePassageIDs: Set(brief.rankedPassages.map(\.id))) ?? []
        let originals = Dictionary(uniqueKeysWithValues: brief.passages.map { ($0.id, $0) })
        supportingPassages = points.compactMap { originals[$0.id] }
    }
}
