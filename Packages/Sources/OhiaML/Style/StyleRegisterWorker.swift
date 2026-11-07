// StyleRegisterWorker.swift
// Drains the `.distillStyleRegisters` job: measures any trained sent email
// whose six style axes are missing, clusters each language's measured sent
// email across every account into the distinct styles the author
// consistently writes in, keeps each style's identity across passes by
// centroid, names new styles from their distinguishing sliders, and has the
// generative model describe them for hover help.
//
// Discovery never changes what the adapter trains on: every pair is
// conditioned on its own measured axes, so membership stamps are bookkeeping
// for the pulldown, default resolution, and training counts.
//
// The pass is incremental and self-healing: measurements and descriptions
// are budgeted per tick, and `BackgroundScheduler.ensurePipelineJobsExist`
// reseeds the job while `hasPendingWork` reports unmeasured or unvisited
// pairs, stale membership, or undescribed styles.

import Foundation
import SwiftData
import OhiaCore

public final class StyleRegisterWorker: @unchecked Sendable {

    public struct Outcome: Sendable, Equatable {
        public let stylesCreated: Int
        public let stylesUpdated: Int
        public let stylesRetired: Int
        public let pairsStamped: Int
        public let descriptionsWritten: Int

        public init(stylesCreated: Int, stylesUpdated: Int, stylesRetired: Int,
                    pairsStamped: Int, descriptionsWritten: Int) {
            self.stylesCreated = stylesCreated
            self.stylesUpdated = stylesUpdated
            self.stylesRetired = stylesRetired
            self.pairsStamped = pairsStamped
            self.descriptionsWritten = descriptionsWritten
        }
    }

    /// Key prefix of a discovered style. Rows without it were written by the
    /// retired topic-strata discovery and are retired on the next pass.
    public static let discoveredKeyPrefix = "style|"

    private let engine: any TrainingEngine
    /// Model descriptions per tick. Styles beyond the budget keep their
    /// provisional summary until a later tick.
    private let maxDescriptionsPerTick: Int
    private let maxTokens: Int
    private let displayLanguageGuard: DisplayLanguageGuard?
    private let readingLanguage: SummarizationTargetLanguage

    public init(
        engine: any TrainingEngine,
        maxDescriptionsPerTick: Int = 4,
        maxTokens: Int = 200,
        displayLanguageGuard: DisplayLanguageGuard? = nil,
        readingLanguage: SummarizationTargetLanguage = .ohiaPreferred()
    ) {
        self.engine = engine
        self.maxDescriptionsPerTick = maxDescriptionsPerTick
        self.maxTokens = maxTokens
        self.displayLanguageGuard = displayLanguageGuard
        self.readingLanguage = readingLanguage
    }

    /// A pair whose current revision is trained evidence: the corpus styles
    /// are discovered from.
    static func isDiscoveryEligible(_ pair: TrainingPair) -> Bool {
        guard let evidence = pair.evidence else { return false }
        return evidence.dispositionRaw == SentTrainingEvidenceDisposition.loraEligible.rawValue
            && evidence.revision == pair.evidenceRevision
    }

    /// The completion's language family, never the undetermined "und".
    static func language(of pair: TrainingPair, score: SentMessageStyleScore?) -> String? {
        [pair.languageID, score?.languageID].lazy
            .compactMap { DraftLanguage.familyID(for: $0) }
            .first { $0 != "und" }
            ?? DraftLanguage.detectedFamilyID(ofText: TrainingPromptFormatter.storedCompletionBody(pair.completionText))
                .flatMap { $0 == "und" ? nil : $0 }
    }

    static func measuredText(of pair: TrainingPair) -> String {
        TrainingPromptFormatter.storedCompletionBody(pair.completionText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the pair has no current-rubric measurement of its exact
    /// completion text.
    static func needsMeasurement(_ pair: TrainingPair) -> Bool {
        let language = language(of: pair, score: nil) ?? "und"
        return SentMessageStyleScore.decode(pair.measuredStyleScoreJSON)?
            .matches(text: measuredText(of: pair), languageID: language) != true
    }

    @MainActor
    public func run(context: ModelContext, now: Date = .now) async throws -> Outcome {
        let pairs = try context.fetch(FetchDescriptor<TrainingPair>())
        let incompletelyMeasured = try await measureMissingScores(pairs, context: context, now: now)

        var pointsByLanguage: [String: [StylePoint]] = [:]
        var pairsByID: [UUID: TrainingPair] = [:]
        for pair in pairs where Self.isDiscoveryEligible(pair) && !Self.needsMeasurement(pair) {
            guard let score = SentMessageStyleScore.decode(pair.measuredStyleScoreJSON),
                  let language = Self.language(of: pair, score: score) else { continue }
            pairsByID[pair.id] = pair
            let correspondent = (pair.styleEvidenceCorrespondentAddress ?? pair.evidence?.correspondentAddress)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            pointsByLanguage[language, default: []].append(StylePoint(
                id: pair.id, axes: score.axes, correspondentAddress: correspondent,
                sampleText: TrainingPromptFormatter.storedCompletionBody(pair.completionText)))
        }

        let registers = try context.fetch(FetchDescriptor<StyleRegister>())
        var created = 0, updated = 0, retired = 0, stamped = 0
        var membership: [UUID: StyleRegister?] = [:]
        var toDescribe: [(register: StyleRegister, language: String, members: [StylePoint])] = []

        func retire(_ register: StyleRegister) {
            guard register.isActive else { return }
            register.isActive = false
            register.updatedAt = now
            retired += 1
        }

        // Rows written by the retired topic-strata discovery carry no slider
        // cluster; their voices are rediscovered from the six axes.
        for register in registers where !register.isUserSavedStyle
            && !register.registerKey.hasPrefix(Self.discoveredKeyPrefix) {
            retire(register)
        }

        let discovered = registers.filter {
            !$0.isUserSavedStyle && $0.registerKey.hasPrefix(Self.discoveredKeyPrefix)
        }
        let languages = Set(pointsByLanguage.keys)
            .union(discovered.filter(\.isActive).flatMap(\.languages))
            .sorted()

        // Lloyd restarts over every measured sent email of a language are
        // seconds of work at mailbox scale: cluster off the main actor.
        let clusteringInputs = languages.compactMap { language -> (String, [StylePoint], Int?)? in
            let points = pointsByLanguage[language] ?? []
            guard points.count >= StyleRegisterLifecycle.minimumCorpusPairs else { return nil }
            let activeCount = discovered.count { $0.isActive && $0.languages.contains(language) }
            return (language, points, activeCount == 0 ? nil : activeCount)
        }
        let clusterings = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: clusteringInputs.map { language, points, previousStyleCount in
                (language, StyleAxisClusterer.cluster(points, previousStyleCount: previousStyleCount))
            })
        }.value

        for language in languages {
            let points = pointsByLanguage[language] ?? []
            let inLanguage = discovered.filter { $0.languages.contains(language) }
            let activeInLanguage = inLanguage.filter(\.isActive)
            guard let clustering = clusterings[language] else {
                // Too little measured mail to split. A language whose
                // measurements are still due keeps its styles and their
                // current members until the measurements land; otherwise its
                // styles retire.
                if incompletelyMeasured.contains(language) {
                    let activeByID = Dictionary(uniqueKeysWithValues: activeInLanguage.map { ($0.id, $0) })
                    var members: [UUID: [StylePoint]] = [:]
                    for point in points {
                        let register = pairsByID[point.id]?.styleRegisterID.flatMap { activeByID[$0] }
                        membership[point.id] = .some(register)
                        if let register { members[register.id, default: []].append(point) }
                    }
                    for register in activeInLanguage {
                        let kept = members[register.id] ?? []
                        if register.exemplarCount != kept.count {
                            register.exemplarCount = kept.count
                            register.updatedAt = now
                        }
                        // A kept style still owed a description gets one now,
                        // so the reseed signal clears while measurements wait.
                        if register.lastDistilledAt == nil { toDescribe.append((register, language, kept)) }
                    }
                } else {
                    activeInLanguage.forEach(retire)
                    for point in points { membership[point.id] = .some(nil) }
                }
                continue
            }

            let reference = clustering.clusters.count > 1 ? clustering.languageMean : ComposerStyleRubric.neutral
            let pointByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })

            // Identity by centroid: closest (cluster, style) pairs within the
            // identity radius claim each other first. A deleted style is a
            // tombstone that consumes its cluster instead of recreating it.
            let claimable = inLanguage.filter { $0.isActive || $0.isUserDeletedStyle }
            var candidates: [(cluster: Int, register: Int, distance: Double)] = []
            for (clusterIndex, cluster) in clustering.clusters.enumerated() {
                for (registerIndex, register) in claimable.enumerated() {
                    guard let axes = register.styleAxes else { continue }
                    let distance = cluster.centroid.rmsDistance(to: axes)
                    if distance <= StyleRegisterLifecycle.identityRadius {
                        candidates.append((clusterIndex, registerIndex, distance))
                    }
                }
            }
            candidates.sort { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                let lhsActive = claimable[lhs.register].isActive, rhsActive = claimable[rhs.register].isActive
                if lhsActive != rhsActive { return lhsActive }
                return (lhs.cluster, lhs.register) < (rhs.cluster, rhs.register)
            }
            var matchedRegister: [Int: StyleRegister] = [:]
            var claimed = Set<Int>()
            for candidate in candidates where matchedRegister[candidate.cluster] == nil
                && !claimed.contains(candidate.register) {
                matchedRegister[candidate.cluster] = claimable[candidate.register]
                claimed.insert(candidate.register)
            }

            // A cluster a deleted style's tombstone consumes is not a style,
            // so a deletion alone never renames the survivors.
            let keptStyleCount = clustering.clusters.indices.count {
                matchedRegister[$0]?.isUserDeletedStyle != true
            }
            let styleCountChanged = activeInLanguage.count != keptStyleCount
            // Names in use: the language's saved styles and the styles this
            // pass keeps. Unclaimed styles retire below, freeing theirs.
            let savedNames = registers.filter {
                $0.isUserSavedStyle && $0.isActive && $0.languages.contains(language)
            }.map(\.name)
            var takenNames = Set(savedNames + claimed.map { claimable[$0] }.filter(\.isActive).map(\.name))
            var kept = Set<ObjectIdentifier>()
            for (clusterIndex, cluster) in clustering.clusters.enumerated() {
                let members = cluster.memberIDs.compactMap { pointByID[$0] }
                if let register = matchedRegister[clusterIndex], register.isUserDeletedStyle {
                    for member in members { membership[member.id] = .some(nil) }
                    continue
                }
                let register: StyleRegister
                var describe = false
                if let matched = matchedRegister[clusterIndex] {
                    register = matched
                    let previousAxes = register.styleAxes
                    let shift = previousAxes.map { cluster.centroid.rmsDistance(to: $0) } ?? 1
                    let membershipDelta = Double(abs(members.count - register.exemplarCount))
                        / Double(max(members.count, 1))
                    let drifted = shift > StyleRegisterLifecycle.redescribeCentroidShift
                        || membershipDelta >= StyleRegisterLifecycle.redescribeMembershipDelta
                    if !register.userRenamed, drifted || styleCountChanged {
                        takenNames.remove(register.name)
                        let name = StyleRegisterNamer.name(for: cluster.centroid, reference: reference, taken: takenNames)
                        if name != register.name {
                            register.name = name
                            register.revision += 1
                        }
                        takenNames.insert(register.name)
                    }
                    if shift > 0.005 {
                        register.styleAxes = cluster.centroid
                        register.revision += 1
                    }
                    describe = drifted || register.lastDistilledAt == nil
                    updated += 1
                } else {
                    let id = UUID()
                    let name = StyleRegisterNamer.name(for: cluster.centroid, reference: reference, taken: takenNames)
                    takenNames.insert(name)
                    register = StyleRegister(
                        id: id,
                        registerKey: "\(Self.discoveredKeyPrefix)\(language)|\(id.uuidString.lowercased())",
                        name: name,
                        summary: StyleRegisterNamer.provisionalSummary(for: cluster.centroid, reference: reference,
                            isOnlyStyle: clustering.clusters.count == 1, memberCount: members.count),
                        styleAxes: cluster.centroid,
                        languages: [language],
                        createdAt: now,
                        updatedAt: now
                    )
                    context.insert(register)
                    created += 1
                    describe = true
                }
                register.isActive = true
                register.languages = [language]
                register.exemplarCount = members.count
                register.correspondents = Array(StyleRegisterDistiller
                    .frequencyOrdered(members.compactMap(\.correspondentAddress))
                    .prefix(StyleRegisterLifecycle.maxStoredCorrespondents))
                register.updatedAt = now
                kept.insert(ObjectIdentifier(register))
                for member in members { membership[member.id] = .some(register) }
                if describe { toDescribe.append((register, language, members)) }
            }
            for register in activeInLanguage where !kept.contains(ObjectIdentifier(register)) {
                retire(register)
            }
        }

        updateSavedStyles(registers, context: context, now: now)

        var described = 0
        for item in toDescribe.prefix(maxDescriptionsPerTick) {
            let others = registers.filter {
                $0.isActive && $0 !== item.register && $0.languages.contains(item.language)
            }.compactMap { other in other.styleAxes.map { (name: other.name, centroid: $0) } }
            if let summary = await describe(item.register, members: item.members, otherStyles: others),
               summary != item.register.summary {
                item.register.summary = summary
                item.register.revision += 1
                described += 1
            }
            // A failed description keeps the provisional summary; drift
            // requests another later.
            item.register.lastDistilledAt = now
        }

        // Stamp membership on every pair. Members point at their style; a
        // measured outsider (a tombstoned cluster, a thin or undetectable
        // language) is visited with no style; a trained pair still awaiting
        // measurement stays unvisited; a pair no longer trained loses any
        // stale stamp.
        for pair in pairs {
            let targetID: UUID?
            let revision: Int?
            if let assigned = membership[pair.id] {
                targetID = assigned?.id
                revision = assigned?.revision ?? 0
            } else if Self.isDiscoveryEligible(pair), Self.needsMeasurement(pair) {
                targetID = nil
                revision = nil
            } else {
                targetID = nil
                revision = 0
            }
            if pair.styleRegisterID != targetID || pair.styleRegisterRevision != revision {
                pair.styleRegisterID = targetID
                pair.styleRegisterRevision = revision
                stamped += 1
            }
        }

        let lineage = try CheckpointManager.voiceLineage(
            compatibility: (engine as? any CheckpointAwareTrainingEngine)?.checkpointCompatibility,
            context: context)
        _ = try TrainingCorpusPlanner.refreshRegisterTrainingCounts(
            context: context, hasPromotedLineage: lineage != nil, learnedRevisions: lineage?.revisions)
        if context.hasChanges { try context.save() }
        return Outcome(stylesCreated: created, stylesUpdated: updated, stylesRetired: retired,
                       pairsStamped: stamped, descriptionsWritten: described)
    }

    // MARK: - Measurement

    /// Scores trained pairs whose six axes are missing, within the per-job
    /// model budget. Returns the languages that still have measurements due,
    /// whose styles must not be retired on partial evidence. A pair that
    /// failed measurement for good is outside the corpus, not due.
    @MainActor
    private func measureMissingScores(_ pairs: [TrainingPair], context: ModelContext, now: Date) async throws -> Set<String> {
        var budget = TrainingPairBuilder.reconstructionsPerJob
        let session = TrainingPairBuilder.Session(engine: engine)
        var incomplete = Set<String>()
        for pair in pairs where Self.isDiscoveryEligible(pair) && Self.needsMeasurement(pair) {
            let text = Self.measuredText(of: pair)
            let language = Self.language(of: pair, score: nil) ?? "und"
            let retryAfter = pair.styleScoringRetryAfter ?? .distantPast
            guard retryAfter != .distantFuture else { continue }
            guard retryAfter <= now, budget > 0,
                  let generate = session.takeReconstruction() else {
                incomplete.insert(language)
                continue
            }
            budget -= 1
            let revision = pair.evidenceRevision
            do {
                let score = try await SentMessageStyleScorer.measure(text: text, languageID: language, generate: generate)
                guard pair.evidenceRevision == revision else { continue }
                pair.measuredStyleScoreJSON = score.json
                pair.styleScoringFailureCount = nil
                pair.styleScoringRetryAfter = nil
                pair.evidence?.measuredStyleScoreJSON = score.json
                // New axes may move the pair to another style.
                pair.styleRegisterRevision = nil
            } catch is CancellationError {
                try context.save()
                throw CancellationError()
            } catch {
                guard pair.evidenceRevision == revision else { continue }
                let failures = min((pair.styleScoringFailureCount ?? 0) + 1, 3)
                pair.measuredStyleScoreJSON = nil
                pair.styleScoringFailureCount = failures
                pair.styleScoringRetryAfter = failures >= 3 ? .distantFuture
                    : now.addingTimeInterval(3_600 * Double(failures))
                if failures < 3 { incomplete.insert(language) }
            }
        }
        try context.save()
        return incomplete
    }

    // MARK: - Saved custom styles

    /// A saved slider profile becomes learned after enough accepted sends
    /// used its unchanged sliders. Progress is recounted each pass.
    @MainActor
    private func updateSavedStyles(_ registers: [StyleRegister], context: ModelContext, now: Date) {
        let events = (try? context.fetch(FetchDescriptor<StylePreferenceEvent>())) ?? []
        for register in registers where register.isUserSavedStyle && register.isActive {
            let matching = events.filter { event in
                guard let snapshot = event.styleControlSnapshot,
                      snapshot.registerID == register.id,
                      let defaults = register.styleAxes,
                      let effective = snapshot.effectiveAxes else { return false }
                return !effective.differs(from: defaults, tolerance: 0.0001)
                    && StyleRegisterResolver.covers(register, language: event.languageID)
            }
            let latest = matching.map(\.createdAt).max()
            if register.resolvedPreferenceEventCount != matching.count || register.latestPreferenceAt != latest {
                register.preferenceEventCount = matching.count
                register.latestPreferenceAt = latest
                register.updatedAt = now
            }
            if matching.count >= StyleRegisterLifecycle.savedStylePromotionSends, !register.resolvedIsLearned {
                register.isLearned = true
                register.updatedAt = now
            }
        }
        for event in events where event.evaluatedAt == nil {
            event.evaluatedAt = now
        }
    }

    // MARK: - Reseed signal

    /// Reseed signal for `BackgroundScheduler.ensurePipelineJobsExist`.
    /// Runs on every scheduler tick, so it must stay cheap: count and
    /// limit-1 probes only, never a full `TrainingPair` fetch (each row
    /// carries multi-KB prompt/completion text). Each condition matches only
    /// what `run` discovers from (current-revision pairs of trained evidence)
    /// and is cleared by a `run`, or advanced by it within the measurement
    /// budget, so the job cannot spin.
    @MainActor
    public static func hasPendingWork(context: ModelContext, now: Date = .now) -> Bool {
        let eligibleRaw = SentTrainingEvidenceDisposition.loraEligible.rawValue
        let earliest = Date.distantPast
        let unmeasured = #Predicate<TrainingPair> {
            $0.measuredStyleScoreJSON == nil
                && $0.evidence?.dispositionRaw == eligibleRaw
                && ($0.styleScoringRetryAfter ?? earliest) <= now
        }
        if containsCurrentRevisionPair(matching: unmeasured, context: context) { return true }

        let unvisited = #Predicate<TrainingPair> {
            $0.styleRegisterRevision == nil && $0.measuredStyleScoreJSON != nil
                && $0.evidence?.dispositionRaw == eligibleRaw
        }
        if containsCurrentRevisionPair(matching: unvisited, context: context) { return true }

        var unevaluatedEvents = FetchDescriptor<StylePreferenceEvent>(predicate: #Predicate<StylePreferenceEvent> {
            $0.evaluatedAt == nil
        })
        unevaluatedEvents.fetchLimit = 1
        if ((try? context.fetchCount(unevaluatedEvents)) ?? 0) > 0 { return true }

        // Styles are few; probe each one's membership.
        let registers = (try? context.fetch(FetchDescriptor<StyleRegister>())) ?? []
        for register in registers where !register.isUserSavedStyle {
            if register.isActive, !register.registerKey.hasPrefix(discoveredKeyPrefix) { return true }
            if register.isActive, register.lastDistilledAt == nil { return true }
            let registerID = register.id
            let members = (try? context.fetchCount(FetchDescriptor<TrainingPair>(predicate: #Predicate<TrainingPair> {
                $0.styleRegisterID == registerID && $0.evidence?.dispositionRaw == eligibleRaw
            }))) ?? 0
            // Pairs removed, trashed, or excluded since the last pass change
            // the corpus the style stands on.
            if register.isActive ? members != register.exemplarCount : members > 0 { return true }
        }
        return false
    }

    /// Whether a pair matching `predicate` is at its evidence's current
    /// revision (only those are discovered from). A limit-1 count answers the
    /// common no-work case; otherwise pages are scanned only until the first
    /// current pair, since older-revision rows are rare leftovers.
    @MainActor
    private static func containsCurrentRevisionPair(matching predicate: Predicate<TrainingPair>,
                                                    context: ModelContext) -> Bool {
        var probe = FetchDescriptor<TrainingPair>(predicate: predicate)
        probe.fetchLimit = 1
        guard ((try? context.fetchCount(probe)) ?? 0) > 0 else { return false }
        var page = FetchDescriptor<TrainingPair>(predicate: predicate, sortBy: [SortDescriptor(\.createdAt)])
        page.propertiesToFetch = [\.evidenceRevision]
        page.relationshipKeyPathsForPrefetching = [\.evidence]
        page.fetchLimit = 64
        var offset = 0
        while true {
            page.fetchOffset = offset
            guard let rows = try? context.fetch(page) else { return false }
            if rows.contains(where: { $0.evidence?.revision == $0.evidenceRevision }) { return true }
            guard rows.count == page.fetchLimit else { return false }
            offset += rows.count
        }
    }

    // MARK: - Description

    @MainActor
    private func describe(_ register: StyleRegister, members: [StylePoint],
                          otherStyles: [(name: String, centroid: StyleAxisValues)]) async -> String? {
        guard engine.isModelLoaded, let centroid = register.styleAxes else { return nil }
        let samples = StyleRegisterDistiller.sampleExcerpts(from: members.map(\.sampleText))
        guard !samples.isEmpty else { return nil }
        let prompt = StyleRegisterDistiller.buildPrompt(name: register.name, centroid: centroid,
            memberCount: members.count, otherStyles: otherStyles, sampleReplies: samples,
            outputLanguage: displayLanguageGuard == nil ? nil : readingLanguage)
        do {
            let engineRef = engine
            let tokenCap = maxTokens
            let raw = try await Task.detached(priority: .utility) { [engineRef, prompt, tokenCap] in
                try PrefixCachedGeneration.generate(engine: engineRef, prompt: prompt, maxTokens: tokenCap)
            }.value
            guard let summary = StyleRegisterDistiller.parseSummary(raw) else { return nil }
            guard let displayLanguageGuard else { return summary }
            // A description whose source-language passage could not be
            // translated keeps its generated wording, never a romanization.
            return await displayLanguageGuard.resolve(
                paragraph: summary,
                targetLanguage: readingLanguage,
                source: DisplayLanguageGuard.Source(
                    languageHint: nil,
                    context: String(samples.joined(separator: "\n").prefix(1_200)),
                    messageID: nil,
                    accountID: nil
                )
            ) ?? summary
        } catch {
            print("[Ohia] ⚠ Style description failed for \(register.registerKey): \(String(reflecting: type(of: error)))")
            return nil
        }
    }
}
