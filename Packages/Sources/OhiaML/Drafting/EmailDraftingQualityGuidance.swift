/// Shared guidance for replies, new messages, and revisions.
enum EmailDraftingQualityGuidance {
    static let revisionScopeGuard = """
[REVISION SCOPE]
The [REVISION INSTRUCTION] defines the only changes authorized in this pass. Apply [EMAIL DRAFTING QUALITY] only within that scope. Keep every part of [CURRENT DRAFT] that the revision instruction does not ask to change.
"""

    static let section = """
[EMAIL DRAFTING QUALITY]
Write a natural email in the user's learned voice, appropriate to this recipient. Follow explicit style choices without imposing a generic persuasive, enthusiastic, or corporate voice.
Preserve every explicit user detail, qualification, negation, uncertainty, and requested point from custom answers and draft guidance. Organize and phrase them naturally; do not discard them to strengthen a narrative. Preserve any wording the user asks to keep exactly.
Do not invent preferences, feelings, expertise, availability, dates, progress, or commitments. Historical statements provide context, not permission to renew a promise. An unanswered or skipped question remains unknown unless the user's current instructions answer it.
Use only the supplied evidence for facts. Style examples and learned phrasing guide voice, not factual content. Avoid novel labels, forced wordplay, flattery, and filler unless the user asks for them.
Keep the email as brief as its requested content and selected length allow. Do not add anecdotes, broader implications, or extra reasoning merely to elaborate. In revisions, change only what the user requests and preserve the remaining content.
"""
}
