import Foundation
import OhiaCore

/// One unit of content the email must honor: a verbatim fragment of an
/// original instruction. Fragments are what the publication check inspects, so
/// a qualifier such as a time zone or a duration is checked on its own instead
/// of disappearing inside a long sentence.
public struct ComposerContentAtom: Codable, Sendable, Equatable {
    /// What kind of obligation the fragment is. Only `content` is checked for
    /// presence; a prohibition is honored by silence and a direction governs
    /// how the email is written, not what it says.
    public enum Kind: String, Codable, Sendable {
        case content, prohibition, direction
    }
    public var id: String
    public var requirementID: String
    public var text: String
    public var kind: Kind
    /// The later instruction that replaced, withdrew or contradicted this
    /// unit, when the preparer found one. A superseded unit is never
    /// required content or an enforced prohibition; the check flags a draft
    /// that still asserts it as current. Nil means the unit is current.
    public var supersededBy: String?

    public init(id: String, requirementID: String, text: String, kind: Kind = .content, supersededBy: String? = nil) {
        self.id = id
        self.requirementID = requirementID
        self.text = text
        self.kind = kind
        self.supersededBy = supersededBy
    }
}

/// An exact passage of supplied evidence, with the role the application
/// assigned to its source. `rank` orders passages by relevance to the current
/// instructions; incoming-message passages always rank first.
public struct ComposerBriefPassage: Codable, Sendable, Equatable {
    public var id: String
    public var sourceID: UUID
    public var contentDigest: String
    public var role: ComposerEvidenceRole
    public var text: String
    public var rank: Int
    public var score: Int

    public init(id: String, sourceID: UUID, contentDigest: String, role: ComposerEvidenceRole,
                text: String, rank: Int, score: Int) {
        self.id = id
        self.sourceID = sourceID
        self.contentDigest = contentDigest
        self.role = role
        self.text = text
        self.rank = rank
        self.score = score
    }
}

/// Application-owned content brief. The model proposes atoms and a source
/// purpose plan: every atom is validated as a verbatim fragment of an original
/// instruction, every sentence of every instruction is covered by its atoms,
/// and a supersession mark may only point at a strictly later instruction.
/// The source plan cannot add, remove or reword an author requirement.
public struct ComposerContentBrief: Codable, Sendable, Equatable {
    /// 8: every instruction sentence is covered by its atoms and a unit may
    /// carry a supersession mark. A version-7 brief (fragments only) is
    /// completed deterministically by `completingCoverage(for:)`.
    public static let currentVersion = 8
    static let completableVersions: Set<Int> = [7, 8]
    public static let maximumAtomsPerRequirement = 12
    public static let maximumRankedPassages = 16
    public static let maximumIncomingPassages = 30

    public var contractVersion: Int
    public var contentIdentity: String
    public var atoms: [ComposerContentAtom]
    public var passages: [ComposerBriefPassage]
    public var unknowns: [String]
    /// Source-purpose decisions from preparation. Absent in older saved
    /// briefs; those may be inspected but cannot drive the current writer.
    public var replyPlan: ComposerReplyPlan?

    public init(contractVersion: Int, contentIdentity: String, atoms: [ComposerContentAtom],
                passages: [ComposerBriefPassage], unknowns: [String], replyPlan: ComposerReplyPlan? = nil) {
        self.contractVersion = contractVersion
        self.contentIdentity = contentIdentity
        self.atoms = atoms
        self.passages = passages
        self.unknowns = unknowns
        self.replyPlan = replyPlan
    }

    public var incomingPassages: [ComposerBriefPassage] { passages.filter { $0.role == .incoming } }
    public var rankedPassages: [ComposerBriefPassage] { passages.filter { $0.role != .incoming } }

    /// Compile original user instructions and attributed source passages without
    /// inference. Chronology and interpretation stay in the shared writer input;
    /// the application does not guess which natural-language decisions supersede others.
    public static func prepared(from input: ComposerContentInput) throws -> ComposerContentBrief {
        var brief = try rendering(from: input)
        brief.passages = ComposerContentPreparer.rankedPassages(input, preserveSelectedEvidence: true)
        try brief.validate(against: input)
        return brief
    }

    /// The prepared brief without its passage index. The writer prompt reads
    /// only atoms and unknowns, so this renders the same bytes as
    /// `prepared(from:)` without indexing every passage of every source; the
    /// writer window measures candidate prompts with it.
    static func rendering(from input: ComposerContentInput) throws -> ComposerContentBrief {
        try input.validate()
        return ComposerContentBrief(contractVersion: currentVersion,
            contentIdentity: try ComposerContentIdentity.value(for: input),
            atoms: ComposerContentPreparer.atoms(from: [], input: input),
            passages: [], unknowns: input.unknowns)
    }

    /// Atoms no later instruction replaced: the author's current position,
    /// the only content the check requires and the only prohibitions and
    /// directions the writer is given.
    public var currentAtoms: [ComposerContentAtom] { atoms.filter { $0.supersededBy == nil } }
    /// Atoms a later instruction replaced. Retained with their order so the
    /// check can flag a draft that still asserts one as current.
    public var supersededAtoms: [ComposerContentAtom] { atoms.filter { $0.supersededBy != nil } }

    /// This brief with every instruction sentence covered and the current
    /// version stamp. A brief a previous build stored (fragments only,
    /// version 7) is completed exactly as the preparer would complete it,
    /// with no model call: fragments and marks are kept, ids renumbered.
    /// A version this build cannot complete is refused.
    public func completingCoverage(for input: ComposerContentInput) throws -> ComposerContentBrief {
        guard Self.completableVersions.contains(contractVersion) else {
            throw ComposerContentError.invalidBrief("The content brief was written by a contract version this build cannot complete.")
        }
        var completed = self
        completed.contractVersion = Self.currentVersion
        completed.atoms = ComposerContentPreparer.atoms(from: atoms.map {
            ComposerContentPreparer.Unit(requirementID: $0.requirementID, text: $0.text, kind: $0.kind, supersededBy: $0.supersededBy)
        }, input: input)
        return completed
    }

    public func validate(against input: ComposerContentInput) throws {
        try input.validate()
        let fail = ComposerContentError.invalidBrief("The content brief does not faithfully identify the supplied instructions and evidence.")
        guard contractVersion == Self.currentVersion,
              contentIdentity == (try ComposerContentIdentity.value(for: input)) else { throw fail }
        let requirements = Dictionary(uniqueKeysWithValues: input.requirements.map { ($0.id, $0) })
        guard Set(atoms.map(\.id)).count == atoms.count else { throw fail }
        for atom in atoms {
            guard let requirement = requirements[atom.requirementID], !atom.id.isEmpty,
                  ComposerContentText.contains(requirement.originalText, fragment: atom.text) else { throw fail }
            // Only a strictly later instruction can replace a unit.
            if let later = atom.supersededBy {
                guard input.isLaterAuthorDecision(later, than: requirement.id) else { throw fail }
            }
        }
        for requirement in input.requirements {
            let own = atoms.filter { $0.requirementID == requirement.id }
            guard !own.isEmpty else {
                throw ComposerContentError.invalidBrief("The brief has no checklist item for an original instruction.")
            }
            // Fragments may isolate qualifiers, but never at the cost of the
            // rest of the sentence they came from: the check must see every
            // obligation the author wrote, not the subset a model extracted.
            guard ComposerContentPreparer.uncoveredSentences(of: requirement.originalText, atoms: own).isEmpty else {
                throw ComposerContentError.invalidBrief("The brief does not cover every part of an original instruction.")
            }
        }
        let evidence = Dictionary(uniqueKeysWithValues: input.allEvidence.map { ($0.source.id, $0) })
        guard Set(passages.map(\.id)).count == passages.count else { throw fail }
        for passage in passages {
            guard let source = evidence[passage.sourceID], source.contentDigest == passage.contentDigest,
                  source.role == passage.role, source.isSelectableEvidence,
                  !passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.passageText.contains(passage.text) else { throw fail }
        }
        try replyPlan?.validate(passages: passages)
        // Structural checks deliberately do not claim semantic relevance. The
        // publication check inspects the draft against the original atoms.
    }
}
