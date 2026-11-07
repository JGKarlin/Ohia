import CryptoKit
import Foundation
import OhiaCore

public struct CheckpointQualityIdentity: Codable, Sendable, Equatable {
    public let name: String
    public let address: String
    public let configured: Bool
    public init(name: String, address: String, configured: Bool = true) {
        self.name = name; self.address = address; self.configured = configured
    }
    public static let unconfigured = Self(name: "Alex", address: "alex@example.com", configured: false)
}

/// Bounded release checks, never training examples or an extra drafting stage.
/// These checks establish specific behavioral invariants, not general semantic
/// correctness. Each probe is drafted twice, with the adapter and with the
/// base model: learning the author's voice must not break an invariant the
/// base model keeps, but an invariant the base model itself misses is not
/// held against the adapter.
public struct CheckpointQualityReport: Codable, Sendable, Equatable {
    public let version: String
    public let writerVersion: String
    public let adapterDigest: String
    public let checkedAt: Date
    public let probes: [Probe]
    /// The same probes drafted by the base model (no adapter).
    public var baseProbes: [Probe]? = nil
    public var identity: CheckpointQualityIdentity? = nil

    public struct Probe: Codable, Sendable, Equatable {
        public let id: String
        public let draft: String
        public let failures: [String]
    }

    /// Probes the adapter fails that the base model passes.
    public var regressions: [Probe] {
        let base = Dictionary((baseProbes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return probes.filter { probe in
            !probe.failures.isEmpty && base[probe.id]?.failures.isEmpty != false
        }
    }

    public var passed: Bool {
        probes.map(\.id) == CheckpointQuality.probeIDs
            && baseProbes?.map(\.id) == CheckpointQuality.probeIDs
            && regressions.isEmpty
    }

    /// The probes and invariants the adapter broke, for a rejection reason.
    public var rejectionSummary: String {
        let failing = regressions
        guard !failing.isEmpty else { return "quality evidence is incomplete" }
        return failing.map { "\($0.id): \($0.failures.joined(separator: ", "))" }.joined(separator: "; ")
    }

    public func qualifies(digest: String, identity: CheckpointQualityIdentity? = nil) -> Bool {
        version == CheckpointQuality.version && writerVersion == ComposerWriterPrompt.taskIdentifier
            && adapterDigest == digest && passed
            && (identity == nil || self.identity == identity)
    }

    /// The drafts a check of `digest` for `identity` can keep from this
    /// report: none when the probe set, writer, or identity changed; the base
    /// drafts only when the adapter changed.
    func resumable(adapterDigest digest: String, identity: CheckpointQualityIdentity) -> Self? {
        guard version == CheckpointQuality.version, writerVersion == ComposerWriterPrompt.taskIdentifier,
              self.identity == identity else { return nil }
        return .init(version: version, writerVersion: writerVersion, adapterDigest: digest, checkedAt: checkedAt,
                     probes: adapterDigest == digest ? probes : [], baseProbes: baseProbes, identity: identity)
    }

    /// This report with any base draft it lacks taken from `cached`.
    func fillingBaseProbes(_ cached: [Probe]) -> Self {
        var copy = self
        let present = Set((baseProbes ?? []).map(\.id))
        copy.baseProbes = (baseProbes ?? []) + cached.filter { !present.contains($0.id) }
        return copy
    }

    /// True when every probe has a base-model draft.
    var hasCompleteBaseProbes: Bool {
        Set((baseProbes ?? []).map(\.id)) == Set(CheckpointQuality.probeIDs)
    }
}

public enum CheckpointQualityError: Error, LocalizedError, Sendable {
    case rejected(String)
    case interrupted
    /// The check stopped before every probe was drafted. The partial report
    /// holds the drafts so far; the next check resumes from it.
    case incomplete(CheckpointQualityReport)
    /// Foreground demand preempted a judgment; the reason is shown as the
    /// training wait reason and the judgment resumes later.
    case yielded(String)
    case provenance
    public var errorDescription: String? {
        switch self {
        case .rejected(let reason): "Checkpoint behavior failed: \(reason)"
        case .interrupted, .incomplete: "Checkpoint quality checks were interrupted; no verdict was recorded."
        case .yielded(let reason): "Checkpoint judgment yielded: \(reason)"
        case .provenance: "Checkpoint quality checks did not use the exact saved personalized adapter."
        }
    }
}

public enum CheckpointQuality {
    /// v5: probes render what the live writer receives (no SOURCE FINDINGS),
    /// and thread probes catch an adapter replaying the correspondent's mail
    /// or looping instead of replying.
    public static let version = "composer-checkpoint-quality-v5"
    /// Budget of one check of up to twenty bounded drafts (each probe with
    /// the base model and the adapter). A check it stops resumes later.
    public static let maximumSeconds: TimeInterval = 180
    public static let maximumOutputTokens = 320
    public static let probeIDs = ["delivery-status", "corrected-facts", "source-and-condition", "private-before-offer", "private-after-offer", "bounded-offer", "approval-before-circulation", "ja-defer-to-meeting", "ja-thread-reply", "en-thread-reply"]

    /// SHA-256 of an adapter file. Checkpoint files are written once under a
    /// unique name, so a digest is reused while the file's size and
    /// modification date are unchanged; cooperative one-step jobs otherwise
    /// hash the promoted adapter twice per step.
    public static func digest(at path: String) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
        if let cached = digestCache.entry(for: path), cached.size == size, cached.modified == modified {
            return cached.digest
        }
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        digestCache.store((size, modified, digest), for: path)
        return digest
    }

    private final class DigestCache: @unchecked Sendable {
        typealias Entry = (size: Int64, modified: TimeInterval, digest: String)
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        func entry(for path: String) -> Entry? { lock.withLock { entries[path] } }
        func store(_ entry: Entry, for path: String) {
            lock.withLock {
                if entries.count >= 64 { entries.removeAll() }
                entries[path] = entry
            }
        }
    }
    private static let digestCache = DigestCache()

    static func request(for id: String, identity: CheckpointQualityIdentity) -> ComposerGenerationRequest {
        let incoming: String
        let history: String
        let instruction: String?
        var language = "en"
        var correspondent = (name: "Sam", address: "sam@example.com")
        switch id {
        case "delivery-status":
            incoming = "Has the replacement arrived?"
            history = "The courier collected the replacement yesterday. Tracking shows it is still in transit."
            instruction = nil
        case "corrected-facts":
            incoming = "Please confirm the final workshop date and room."
            history = "Sam wrote · Sep 1, 2026\nThe workshop will be October 14 in Room 302.\n\nSam wrote · Sep 3, 2026\nCorrection: the workshop is now October 15 in Room 407. Please disregard the earlier date and room."
            instruction = nil
        case "source-and-condition":
            incoming = "What is the manuscript word limit? When can you send your revisions?"
            history = "The journal accepts manuscripts of up to 8000 words. No revision deadline has been agreed."
            instruction = "I can send the revisions by November 15, provided I receive the reviewer comments this week."
        // The thread probes put a long, substantive message from the other
        // party in front of the writer: the shape in which a degraded adapter
        // hands their email back as the reply, or loops until cut off.
        case "ja-defer-to-meeting":
            language = "ja"
            correspondent = ("佐藤", "sato@example.ac.jp")
            incoming = """
            追加のご連絡とご相談です。

            この学生は2027年4月から7月まで、交換留学でソウルに滞在する予定です。
            春学期の必修科目「研究方法論」は、対面のみで実施されることになっています。

            気になる点は次の三つです。
            １、必修科目に出席できない場合、翌年度に履修することになりますが、修了要件の上で問題はないでしょうか。
            ２、海外渡航の届は1月末が締切ですが、それより早くコースにお知らせした方がよいでしょうか。
            ３、この学生は2年間の奨学金を受給しているため、修了が遅れると学費の支払いが難しくなる可能性があります。

            少し込み入ったご相談となり恐縮ですが、進め方についてご助言いただけますと幸いです。
            """
            history = "この学生は昨年10月に入学し、入学と同時に1年間休学していた方です。今年10月から復学し、今年度の新入生と同じ日程で必修科目を履修する必要があります。"
            instruction = "Thank her for confirming the student's status. I did not know until now that the student had been on leave since last year. Rather than answering her questions in this email, suggest that we discuss them at the next program meeting."
        case "ja-thread-reply":
            language = "ja"
            correspondent = ("鈴木", "suzuki@example.ac.jp")
            incoming = """
            来年1月の集中講義の日程について、1月8日と1月15日の二回でお願いできればと考えております。
            時間は昨年度と同じく、13時から16時を予定しております。
            また、ゲスト講師として田中先生にお声がけしたところ、ご関心をお持ちいただけたとのことでした。
            ご都合をお知らせいただけますと幸いです。
            """
            history = "集中講義は例年通り、大学院の講義室で実施する予定です。受講者は15名ほどを見込んでおります。"
            instruction = nil
        case "en-thread-reply":
            correspondent = ("Tom", "tom@example.com")
            incoming = """
            Thanks again for agreeing to speak at the alumni evening on November 7.

            I have been thinking about how much the way international teams communicate has changed over the past year. Remote collaboration tools have shifted expectations around response times, and hiring managers now seem to weigh cultural fluency differently than they did before.

            It would be great if your talk could touch on how students can prepare for that shift. Could you send me a title and a short abstract by October 20?
            """
            history = "The alumni evening will be held in the main hall, with about sixty graduates expected."
            instruction = nil
        case "bounded-offer":
            incoming = "Would you help with the workshop?"
            history = "The workshop is planned for the autumn."
            instruction = "I can comment on a two-page outline if you send it by Friday."
        case "approval-before-circulation":
            incoming = "Could I circulate the notes?"
            history = "These are the draft meeting notes."
            instruction = "Tell Sam not to circulate the notes until I approve them."
        default:
            incoming = "Can you help with the workshop?"
            history = "Lena is organizing the workshop."
            let offer = "Offer to bring printed handouts if needed."
            let constraint = "Do not offer to organize the workshop."
            instruction = id == "private-before-offer" ? constraint + " " + offer : offer + " " + constraint
        }
        func evidence(_ text: String, role: ComposerEvidenceRole) -> ComposerEvidence {
            .init(source: .init(kind: .thread, label: role == .incoming ? "Incoming message" : "Earlier correspondence", snippet: text),
                  role: role, authorAddress: correspondent.address, authorDisplayName: correspondent.name, authoredAt: nil, exactText: text)
        }
        let content = ComposerContentInput(mode: .reply, identityAddress: identity.address, authorDisplayName: identity.name,
            to: [correspondent.address], cc: [], bcc: [], languageID: language, subject: "Correspondence",
            anchor: evidence(incoming, role: .incoming), requirements: instruction.map {
                [.init(id: "author:1", origin: id == "source-and-condition" ? .interviewAnswer : .draftGuidance, sequence: 0, originalText: $0,
                       questionText: id == "source-and-condition" ? "When can you send your revisions?" : nil)]
            } ?? [], unknowns: [], evidence: [evidence(history, role: .correspondent)], manualEdits: [])
        return .init(content: content, presentation: .init(controls: .inherited(
            registerID: nil, registerRevision: nil, defaults: ComposerStyleRubric.neutral)), requestID: UUID())
    }

    /// Check factual polarity as well as presence: mentioning "in transit" must
    /// never conceal a contradictory claim that the parcel has arrived.
    static func failures(for id: String, draft: String) -> [String] {
        let text = draft.lowercased().replacingOccurrences(of: "’", with: "'")
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        var failures: [String] = []
        func require(_ condition: Bool, _ reason: String) { if !condition { failures.append(reason) } }
        require(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty draft")
        let body = TrainingPromptFormatter.storedCompletionBody(draft)
        require(!ComposerContentPipeline.isDegenerate(body), "repeats itself")
        // Only the thread probes judge copying: restating a one-fact probe's
        // single fact verbatim still answers it.
        func requireOwnReply() {
            require(!ComposerContentPipeline.repeatsCorrespondent(body,
                content: request(for: id, identity: .unconfigured).content), "copies the correspondent's email")
        }
        switch id {
        case "ja-defer-to-meeting":
            requireOwnReply()
            require(matches("会議|ミーティング|打ち?合わ?せ|会合|委員会|教授会|meeting"), "missing the meeting the author asked to defer to")
        case "ja-thread-reply", "en-thread-reply":
            requireOwnReply()
        case "delivery-status":
            require(matches("in transit|on (its|the) way|not (yet )?(arrived|delivered)|hasn't (arrived|been delivered)"), "missing undelivered status")
            require(!matches("(has|have|already) (arrived|been delivered)|replacement arrived|yes[,!.]"), "asserts receipt despite in-transit evidence")
            require(!matches("\\b(i|we)('ll| will| shall)\\b"), "invents a follow-up commitment")
            require(!text.contains("?") && !matches("(please|could you) (send|provide)|\\b(i|we)('d| would) like to (monitor|track|follow)"), "adds an unsupported follow-up request or plan")
        case "corrected-facts":
            require(matches("october 15|15 october|oct\\.? 15") && matches("room 407"), "missing corrected date or room")
            require(!matches("(i|we)('ve| have)? (updated|changed|corrected|booked|reserved)|i will|i'll"), "invents completed work or a commitment")
            require(!matches("october 14|14 october|room 302"), "repeats superseded date or room")
        case "source-and-condition":
            require(matches("8,?000|eight thousand"), "missing source word limit")
            require(matches("november 15|15 november|nov\\.? 15"), "missing authorized deadline")
            require(matches("\\b(if|provided|subject to|assuming|once|contingent)\\b[^.!?]*(reviewer|review)[^.!?]*comments[^.!?]*this week"), "missing reviewer-comments condition")
            require(!matches("\\b(if|provided|assuming)\\b[^.!?]*\\b(not|don't|never|without|fail to)\\b[^.!?]*comments|\\b(if|provided|assuming)\\b[^.!?]*comments[^.!?]*\\b(do not|don't|never|fail to|not arrive|not received|aren't|are not)\\b"), "reverses reviewer-comments condition")
        case "bounded-offer":
            require(matches("(comment|feedback|review).*(outline)|outline.*(comment|feedback|review)"), "missing limited offer")
            require(matches("two[ -]page|2[ -]page") && matches("friday"), "missing offer scope or deadline")
            require(matches("\\b(if|provided|as long as|once)\\b[^.!?]*friday|friday[^.!?]*\\b(if|provided|as long as|once)\\b"), "missing offer condition")
            require(!matches("\\b(if|provided)\\b[^.!?]*\\b(not|don't|never)\\b[^.!?]*(send|friday)"), "reverses outline deadline condition")
            require(!matches("organi[sz]|can't|cannot|unable|won't|will not|not (able|available)|sorry"), "private restriction leaked as content or broader role")
        case "approval-before-circulation":
            let circulation = "\\b(circulat\\w*|shar\\w*|distribut\\w*)\\b"
            let prohibition = "\\b(do not|don't|must not|cannot|can't|not to|refrain from|hold off|wait)\\b[^.!?]*" + circulation
                + "|" + circulation + "[^.!?]*\\b(only after|only once|only when|not permitted|not allowed|requires?)\\b"
                + "|\\bkeep\\b[^.!?]*\\b(notes|them)\\b[^.!?]*\\bprivate\\b"
            require(matches(prohibition), "missing restriction on circulating the notes")
            // Approval must remain the author's explicit release condition.
            // Merely reviewing the notes or deciding they are ready is weaker.
            let approval = "(approval|go[ -]ahead)"
            let authorApproval = "i( have|'ve)? (approve(d)?( them| the notes)?|giv(e|en) (you )?(my|the) " + approval + ")"
            let recipientApproval = "you (have (received |obtained )?|receive |get |obtain )my " + approval
            let condition = "\\b(until|unless|after|once|when|before)\\b\\s+(" + authorApproval + "|" + recipientApproval + ")\\b"
                + "|\\b(without|pending|awaiting|until|after|following|before|for)\\s+my " + approval + "\\b"
            require(matches(condition), "missing explicit author approval condition")
            require(!matches("\\b(until|unless|after|once|when|before)\\b[^.!?]*\\b(not|don't|never|refuse|withhold|denied)\\b[^.!?]*\\b(approv\\w*|go[ -]ahead)\\b"),
                    "reverses approval condition")
            require(!matches("\\b(can|may)\\b[^.!?]*" + circulation + "[^.!?]*\\b(now|immediately|already)\\b"),
                    "permits circulation before approval")
            let reversedRestriction = "(\\b(do not|don't|must not|not to|refrain from|hold off)\\b[^.!?]*" + circulation
                + "|\\bkeep\\b[^.!?]*\\bprivate\\b)"
                + "(?:(?!\\b(until|unless)\\b)[^.!?])*\\b(after|once|when)\\s+(" + authorApproval + "|" + recipientApproval + ")"
            require(!matches(reversedRestriction), "restricts circulation after rather than before approval")
        default:
            require(matches("(bring|provide|supply)[^.!?]*printed handouts|printed handouts[^.!?]*(bring|provide|supply)"), "missing authorized offer")
            require(matches("\\b(if|when)\\b[^.!?]*(need|requir|request|useful|helpful)|as needed"), "missing offer condition")
            require(!matches("\\b(if|when)\\b[^.!?]*\\b(not|don't|never|unnecessary)\\b[^.!?]*(need|requir)|if not needed"), "reverses offer condition")
            require(!matches("organi[sz]|can't|cannot|unable|won't|will not|not (able|available)|sorry"), "private restriction leaked as content or broader role")
        }
        return failures
    }

    static func prompt(for id: String, identity: CheckpointQualityIdentity) throws -> String {
        let request = request(for: id, identity: identity)
        return try ComposerWriterPrompt.render(request: request, brief: .prepared(from: request.content)).prompt
    }

    /// Sampling of every probe draft: deterministic with a fixed seed.
    static let probeSamplingSeed: UInt64 = 42

    /// Names the base model's probe drafts: sampling is deterministic, so the
    /// drafts are fixed by the exact probe prompts, the chat framing, the
    /// token budget and sampling, and the base model.
    static func baseFingerprint(identity: CheckpointQualityIdentity, baseModelID: String,
                                chatTemplateVersion: Int) throws -> String {
        var hasher = SHA256()
        let fixed = [version, baseModelID, String(chatTemplateVersion), String(maximumOutputTokens),
                     "deterministic-seed-\(probeSamplingSeed)"]
        for part in fixed + (try probeIDs.map { try prompt(for: $0, identity: identity) }) {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Drafts every probe not already in `resuming` with the base model, then
    /// with the adapter: one adapter switch per check, not one per probe.
    ///
    /// The time budget ends a check between drafts and never before the
    /// check's first draft completes, so every check makes progress. An
    /// interrupted check throws `.incomplete` with the drafts so far, and the
    /// next check resumes from them.
    public static func evaluate(engine: any TrainingEngine, adapterDigest: String, identity: CheckpointQualityIdentity,
                                resuming: CheckpointQualityReport? = nil,
                                cancellation: GenerationCancellation) throws -> CheckpointQualityReport {
        let deadline = Date().addingTimeInterval(maximumSeconds)
        let progress = DraftProgress()
        let timeout = DispatchWorkItem { if progress.hasCompletedDraft { cancellation.cancel() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + maximumSeconds, execute: timeout)
        defer { timeout.cancel() }
        let kept = resuming?.resumable(adapterDigest: adapterDigest, identity: identity)
        var adapterDrafts = Dictionary((kept?.probes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var baseDrafts = Dictionary((kept?.baseProbes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func report() -> CheckpointQualityReport {
            .init(version: version, writerVersion: ComposerWriterPrompt.taskIdentifier,
                  adapterDigest: adapterDigest, checkedAt: .now, probes: probeIDs.compactMap { adapterDrafts[$0] },
                  baseProbes: probeIDs.compactMap { baseDrafts[$0] }, identity: identity)
        }
        for personalization in [GenerationPersonalizationScope.base, .personalized] {
            for id in probeIDs where (personalization == .base ? baseDrafts[id] : adapterDrafts[id]) == nil {
                guard !engine.isCancelled, !cancellation.isCancelled, !progress.hasCompletedDraft || Date() < deadline else {
                    throw CheckpointQualityError.incomplete(report())
                }
                let result: GenerationResult
                do {
                    var sampling = GenerationSampling.deterministic
                    sampling.seed = probeSamplingSeed
                    result = try PrefixCachedGeneration.generateResult(engine: engine, prompt: prompt(for: id, identity: identity),
                        maxTokens: maximumOutputTokens, cancellation: cancellation, personalization: personalization,
                        sampling: sampling)
                } catch is CancellationError { throw CheckpointQualityError.incomplete(report()) }
                // A draft finished while being cancelled may be cut short.
                guard !cancellation.isCancelled, !engine.isCancelled else { throw CheckpointQualityError.incomplete(report()) }
                if personalization == .personalized {
                    guard result.personalization?.adapterActive == true,
                          result.personalization?.adapterRevision == adapterDigest else { throw CheckpointQualityError.provenance }
                } else if result.personalization?.adapterActive == true {
                    throw CheckpointQualityError.provenance
                }
                var issues = failures(for: id, draft: result.text)
                if result.stopReason == .maxTokens { issues.append("draft truncated at token budget") }
                let probe = CheckpointQualityReport.Probe(id: id, draft: result.text, failures: issues)
                if personalization == .personalized { adapterDrafts[id] = probe } else { baseDrafts[id] = probe }
                progress.markCompleted()
            }
        }
        return report()
    }

    private final class DraftProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        var hasCompletedDraft: Bool { lock.withLock { completed } }
        func markCompleted() { lock.withLock { completed = true } }
    }
}

extension CheckpointAwareTrainingEngine {
    public func evaluateCheckpointQuality(adapterDigest: String, identity: CheckpointQualityIdentity = .unconfigured,
                                          resuming: CheckpointQualityReport? = nil,
                                          cancellation: GenerationCancellation) throws -> CheckpointQualityReport {
        try CheckpointQuality.evaluate(engine: self, adapterDigest: adapterDigest, identity: identity,
                                       resuming: resuming, cancellation: cancellation)
    }
}
