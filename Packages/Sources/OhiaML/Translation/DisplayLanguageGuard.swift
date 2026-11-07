import Foundation
import os
import SwiftData
import OhiaCore

private let displayLanguageGuardLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "display-language-guard"
)

/// Keeps model-generated, reader-facing text in the reader's language.
/// Generation sometimes copies source-language names and terms verbatim
/// (総務チーム in an English summary), and sometimes writes a clause or a whole
/// field in the source language. Each residue span is resolved in order of
/// authority:
/// 1. a deterministic date, time, or currency rendering ("3月15日");
/// 2. an active translation-glossary pair for that exact term;
/// 3. one bounded rendering pass by the local model. A line that still
///    carries a passage (`DisplayLanguageResidue.isPassage`: a clause or
///    sentence, not a name or term) is translated whole as one item, with
///    established glossary renderings applied; a name or term the
///    translation keeps in the source script goes through authorities 1, 2,
///    and 4, while a kept clause rejects it. Term-sized renderings by the
///    model found new provisional glossary pairs; whole-line translations,
///    and the kept terms resolved inside them, never do;
/// 4. deterministic romanization, for names and terms only; a mark with no
///    reading (a lone 々) is dropped.
/// A passage is never romanized, rendered piecewise, or partly fixed. When it
/// cannot be translated (no loaded model, a failed or cancelled generation,
/// a rejected or missing answer) its whole field is returned exactly as
/// written and listed in `Resolution.untranslated`, so the caller can
/// withhold it, or keep its wording, until it is generated again.
/// Text without residue returns unchanged without any store or model access.
public struct DisplayLanguageGuard: Sendable {
    /// The material the displayed text was generated from.
    public struct Source: Sendable, Equatable {
        /// Detected language of the source message, when known.
        public let languageHint: String?
        /// Source subject and body excerpt; used for meaning only.
        public let context: String
        public let messageID: UUID?
        public let accountID: UUID?
        /// Keep spans inside quotation marks or corner brackets: on Ask and
        /// Composer surfaces quoted source wording is the content itself.
        public let preservesQuotedText: Bool
        /// Text the reader wrote; a span that appears in it verbatim is the
        /// reader's own wording and is kept ("What does 総務チーム mean?").
        public let readerText: String?

        public init(
            languageHint: String?,
            context: String,
            messageID: UUID?,
            accountID: UUID?,
            preservesQuotedText: Bool = false,
            readerText: String? = nil
        ) {
            self.languageHint = languageHint
            self.context = context
            self.messageID = messageID
            self.accountID = accountID
            self.preservesQuotedText = preservesQuotedText
            self.readerText = readerText
        }
    }

    /// The displayed form of a set of fields.
    public struct Resolution: Sendable, Equatable {
        /// One display string per input field, in order. A field listed in
        /// `untranslated` is exactly the text that was passed in.
        public let fields: [String]
        /// Indexes of fields carrying a source-language passage that could
        /// not be translated.
        public let untranslated: Set<Int>
        /// Whether the untranslated fields are a transient miss: the
        /// translation pass never reached an answer because no model was
        /// loaded or generation was cancelled. False when the model answered
        /// and its translation was missing or rejected, when generation
        /// failed, or when a passage could not be listed at all.
        public let isTransient: Bool

        public var isComplete: Bool { untranslated.isEmpty }
    }

    private let container: ModelContainer?
    private let engine: (any TrainingEngine)?
    private let priority: TaskPriority

    public init(
        container: ModelContainer?,
        engine: (any TrainingEngine)?,
        priority: TaskPriority = .utility
    ) {
        self.container = container
        self.engine = engine
        self.priority = priority
    }

    /// A guard that never generates and never writes: glossary lookups (when
    /// a container is supplied) and romanization of names and terms only.
    public func withoutModel() -> DisplayLanguageGuard {
        DisplayLanguageGuard(container: container, engine: nil, priority: priority)
    }

    /// The same glossary, rendered by a caller's own engine.
    public func with(engine: any TrainingEngine) -> DisplayLanguageGuard {
        DisplayLanguageGuard(container: container, engine: engine, priority: priority)
    }

    /// Whether cached display text may be shown as-is. Without a guard the
    /// caller has opted out of the residue pass and its cache stands.
    public static func isDisplayable(
        _ text: String,
        targetLanguage: SummarizationTargetLanguage,
        guardrail: DisplayLanguageGuard?
    ) -> Bool {
        guardrail == nil || needsResolution([text], targetLanguage: targetLanguage) == false
    }

    /// Single-paragraph convenience for the reader-facing generation services.
    /// Nil when the paragraph carries a passage that could not be translated:
    /// the caller shows and caches nothing in its place.
    public func resolve(
        paragraph: String,
        targetLanguage: SummarizationTargetLanguage,
        source: Source
    ) async -> String? {
        guard Self.needsResolution([paragraph], targetLanguage: targetLanguage) else { return paragraph }
        let resolution = await resolve([paragraph], targetLanguage: targetLanguage, source: source)
        return resolution.isComplete ? resolution.fields.first : nil
    }

    public static func needsResolution(_ fields: [String], targetLanguage: SummarizationTargetLanguage) -> Bool {
        fields.contains {
            DisplayLanguageResidue.containsResidue($0, targetLanguage: targetLanguage.identifier)
                || DisplayLanguageResidue.normalizedTypography($0, targetLanguage: targetLanguage.identifier) != $0
        }
    }

    public func resolve(
        _ fields: [String],
        targetLanguage: SummarizationTargetLanguage,
        source: Source
    ) async -> Resolution {
        guard var pass = prepare(fields, targetLanguage: targetLanguage, source: source) else {
            return Self.typographyOnly(fields, targetLanguage: targetLanguage)
        }
        guard let prompt = pass.renderingPrompt() else { return pass.finished(transient: false) }
        guard let engine, engine.isModelLoaded else { return pass.finished(transient: true) }
        let raw: String
        do {
            raw = try await Self.generate(engine: engine, prompt: prompt, priority: priority)
        } catch is CancellationError {
            return pass.finished(transient: true)
        } catch {
            Self.logRenderingFailure(error)
            return pass.finished(transient: false)
        }
        let generated = pass.accept(raw)
        if let observations = pass.mintableObservations(generated), let container {
            await MainActor.run { Self.mint(observations, into: container) }
        }
        return pass.finished(transient: false)
    }

    /// Synchronous counterpart for generation surfaces whose own generation
    /// is a blocking call (the Composer interview planner and repairer, which
    /// may run on the main actor). Generation honors `cancellation`; glossary
    /// pairs are founded in a separate main-actor task because the result
    /// does not depend on them.
    public func resolveSynchronously(
        _ fields: [String],
        targetLanguage: SummarizationTargetLanguage,
        source: Source,
        cancellation: GenerationCancellation
    ) -> Resolution {
        guard var pass = prepare(fields, targetLanguage: targetLanguage, source: source) else {
            return Self.typographyOnly(fields, targetLanguage: targetLanguage)
        }
        guard let prompt = pass.renderingPrompt() else { return pass.finished(transient: false) }
        guard let engine, engine.isModelLoaded else { return pass.finished(transient: true) }
        let raw: String
        do {
            raw = try PrefixCachedGeneration.generate(
                engine: engine,
                prompt: prompt.prompt,
                maxTokens: prompt.maxTokens,
                cancellation: cancellation
            )
        } catch is CancellationError {
            return pass.finished(transient: true)
        } catch {
            Self.logRenderingFailure(error)
            return pass.finished(transient: false)
        }
        let generated = pass.accept(raw)
        if let observations = pass.mintableObservations(generated), let container {
            Task { @MainActor in Self.mint(observations, into: container) }
        }
        return pass.finished(transient: false)
    }

    private static func typographyOnly(
        _ fields: [String],
        targetLanguage: SummarizationTargetLanguage
    ) -> Resolution {
        Resolution(
            fields: fields.map { DisplayLanguageResidue.normalizedTypography($0, targetLanguage: targetLanguage.identifier) },
            untranslated: [],
            isTransient: false
        )
    }

    // MARK: - Pass

    /// One resolution over a set of fields: residue spans, their languages,
    /// the lines translated whole, and the renderings gathered so far from
    /// each authority.
    private struct Pass {
        /// A line of a field that still carries a passage once the
        /// deterministic and glossary authorities have run.
        struct PassageLine {
            let field: Int
            let range: Range<String.Index>
            let text: String
            let language: String?
            /// Text the translation must carry unchanged: links, addresses,
            /// file names, and wording the surface keeps as written.
            let verbatim: [String]
        }

        /// One numbered entry of the rendering prompt.
        enum Item {
            case passage(Int)
            case term(String)
        }

        let fields: [String]
        let spansByField: [[DisplayLanguageResidue.Span]]
        let passageLines: [PassageLine]
        /// Distinct spans outside every passage line, in order of appearance.
        let termSpans: [String]
        let languages: [String: String?]
        let glossary: DisplayGlossarySnapshot
        let targetLanguage: SummarizationTargetLanguage
        let targetCode: String
        let source: Source
        /// The reader's own source-script words, kept verbatim wherever they
        /// occur.
        let readerWords: [String]
        var renderings: [String: String]
        var translations: [Int: String] = [:]

        /// Untranslated passage lines first, since nothing else may stand in
        /// for them, each distinct line once, then unrendered terms; bounded
        /// to one prompt. A line too long to translate whole, or one holding
        /// the answer format's own arrow, is never listed, and its field
        /// stays untranslated.
        var items: [Item] {
            var listedLines = Set<String>()
            let passages = passageLines.indices.filter {
                let line = passageLines[$0]
                return translations[$0] == nil
                    && line.text.count <= DisplayTermRenderingPrompt.maximumPassageCharacters
                    && line.text.contains("=>") == false
                    && listedLines.insert(line.text).inserted
            }.map(Item.passage)
            let terms = termSpans.filter { renderings[$0] == nil }.map(Item.term)
            return Array((passages + terms).prefix(DisplayTermRenderingPrompt.maximumSpans))
        }

        func renderingPrompt() -> (prompt: PrefixCachedPrompt, maxTokens: Int)? {
            let listed = items
            let promptSpans = listed.map(promptSpan)
            guard promptSpans.isEmpty == false else { return nil }
            var itemLanguages = languages
            for span in promptSpans { itemLanguages.updateValue(span.language, forKey: span.text) }
            var verbatim: [String] = []
            var seen = Set<String>()
            for case .passage(let index) in listed {
                for text in passageLines[index].verbatim where seen.insert(text).inserted {
                    verbatim.append(text)
                }
            }
            let prompt = DisplayTermRenderingPrompt.build(
                spans: promptSpans,
                targetLanguage: targetLanguage,
                displayedText: fields.filter { $0.isEmpty == false }.joined(separator: "\n"),
                sourceContext: source.context,
                established: glossary.established(within: promptSpans.map(\.text), languages: itemLanguages),
                verbatim: verbatim
            )
            return (prompt, DisplayTermRenderingPrompt.maxTokens(for: promptSpans))
        }

        private func promptSpan(_ item: Item) -> DisplayTermRenderingPrompt.Span {
            switch item {
            case .passage(let index):
                let line = passageLines[index]
                return .init(text: line.text, language: line.language, isPassage: true)
            case .term(let span):
                return .init(text: span, language: languages[span] ?? nil)
            }
        }

        /// Parses and validates the model's answer for the items the prompt
        /// listed. Term answers are taken first, so a line translation that
        /// keeps one of those terms renders it the same way; then each
        /// accepted line translation is recorded. Returns the accepted term
        /// renderings.
        mutating func accept(_ raw: String) -> [String: String] {
            let listed = items
            let answers = DisplayTermRenderingPrompt.parseAnswers(raw, spanCount: listed.count)
            let cleaned = answers.renderings.mapValues {
                DisplayLanguageResidue.normalizedTypography($0, targetLanguage: targetLanguage.identifier)
            }
            var accepted: [String: String] = [:]
            for index in cleaned.keys.sorted() {
                guard case .term(let span) = listed[index], let answer = cleaned[index],
                      DisplayTermRenderingPrompt.isAcceptable(answer, for: span, targetLanguage: targetLanguage.identifier),
                      glossary.isRejected(span: span, rendering: answer, sourceLanguage: languages[span] ?? nil) == false else {
                    continue
                }
                accepted[span] = answer
            }
            for (span, rendering) in accepted { renderings[span] = rendering }

            var translated = 0
            for index in cleaned.keys.sorted() {
                guard case .passage(let line) = listed[index],
                      let answer = cleaned[index], let written = answers.renderings[index] else { continue }
                let passage = passageLines[line]
                // Kept spans are resolved on the answer as written, so they
                // match the field's spans and glossary terms character for
                // character (総務・人事 before ・ becomes ·); the result is
                // normalized afterwards.
                guard answers.continued.contains(index) == false,
                      DisplayTermRenderingPrompt.isAcceptableTranslation(answer, of: passage.text),
                      let resolved = resolvingKeptTerms(in: written, of: passage.text, modelRenderings: accepted),
                      resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      DisplayTermRenderingPrompt.isAcceptableTranslation(resolved, of: passage.text),
                      passage.verbatim.allSatisfy({ resolved.contains($0) }),
                      isResidueFree(resolved) else {
                    continue
                }
                // Every occurrence of the same line takes the translation.
                for other in passageLines.indices where passageLines[other].text == passage.text {
                    translations[other] = resolved
                }
                translated += 1
            }
            displayLanguageGuardLogger.debug(
                "Display term rendering items=\(listed.count, privacy: .public) accepted=\(accepted.count, privacy: .public) linesTranslated=\(translated, privacy: .public)"
            )
            return accepted
        }

        /// A line translation with every span it kept in the source script
        /// resolved without another model call, or nil when the translation is
        /// unfit. Each kept span goes to the first authority that renders it:
        /// a date, time, currency, or parenthesized weekday rendering, an
        /// active glossary pair, then the model's own rendering of that term
        /// in this answer. A kept passage rejects the translation, judged on
        /// the run as written before the reader's own words are carved out of
        /// it; a mark with no reading is dropped, while a word without a
        /// reading rejects it. Anything else is romanized only when it, and the
        /// run it was carved from, read as a name
        /// (`DisplayLanguageResidue.isNameLike`) and it occurs verbatim in the
        /// line being translated, so a clause the passage rule misses and text
        /// the model made up are refused; when two or more spans are
        /// romanized they may make up at most a quarter of the line, so a list
        /// of kept source terms is not taken for a translation. Outside the
        /// kept spans the translation must still say something: its own words
        /// must be at least a third of the width of the rest of the line, so a
        /// bare kept name ("From 総務チーム.") never replaces a sentence. Quoted wording where quotes are
        /// content, and the reader's own words, stay as they are. None of these
        /// renderings is minted.
        private func resolvingKeptTerms(
            in translation: String,
            of line: String,
            modelRenderings: [String: String]
        ) -> String? {
            let readerText = source.readerText ?? ""
            let notReaderOwn = { (span: DisplayLanguageResidue.Span) in
                readerText.isEmpty || readerText.contains(span.text) == false
            }
            let kept = DisplayLanguageResidue.spans(
                in: translation,
                targetLanguage: targetLanguage.identifier,
                preservingQuoted: source.preservesQuotedText,
                keeping: readerWords
            ).filter(notReaderOwn)
            guard kept.isEmpty == false else { return translation }
            let wholeRuns = readerWords.isEmpty
                ? kept
                : DisplayLanguageResidue.spans(
                    in: translation,
                    targetLanguage: targetLanguage.identifier,
                    preservingQuoted: source.preservesQuotedText
                ).filter(notReaderOwn)
            func readings(of text: String) -> [String?] {
                let language = DisplayLanguageResidue.sourceLanguage(
                    ofSpan: text,
                    sourceLanguageHint: source.languageHint,
                    sourceContext: source.context
                )
                // A Han-only run is read under both the Japanese and the
                // Chinese rules: either finding a clause rejects it.
                return DisplayScriptFamily.families(in: text) == [.han] ? [language, "ja", "zh"] : [language]
            }
            func authority(of span: DisplayLanguageResidue.Span, among spans: [DisplayLanguageResidue.Span]) -> String? {
                let weekdayEverywhere = spans
                    .filter { $0.text == span.text }
                    .allSatisfy {
                        DisplayLanguageGuard.isWeekdayAfterDate($0.range, in: translation, targetLanguage: targetCode)
                    }
                return DisplayLanguageGuard.authorityRendering(
                    of: span.text,
                    language: readings(of: span.text).first ?? nil,
                    targetCode: targetCode,
                    glossary: glossary,
                    weekdayEverywhere: weekdayEverywhere
                )
            }
            // A run the authorities or this answer's term renderings resolve
            // is a name, however long; only an unresolved run can be a clause.
            for run in wholeRuns where (authority(of: run, among: wholeRuns) ?? modelRenderings[run.text]) == nil {
                guard readings(of: run.text).contains(where: { DisplayLanguageResidue.isPassage(run.text, language: $0) }) == false else {
                    return nil
                }
            }

            var keptRenderings: [String: String] = [:]
            var romanized = Set<String>()
            for span in kept where keptRenderings[span.text] == nil {
                if let rendering = authority(of: span, among: kept) ?? modelRenderings[span.text] {
                    keptRenderings[span.text] = rendering
                    continue
                }
                let spanReadings = readings(of: span.text)
                guard spanReadings.contains(where: { DisplayLanguageResidue.isPassage(span.text, language: $0) }) == false else {
                    return nil
                }
                let language = spanReadings.first ?? nil
                guard let romanization = language.flatMap({ SourceScriptRomanizer.romanize(span.text, language: $0) }) else {
                    // A mark with no reading is dropped; a word the reader
                    // has no reading for cannot be shown, so the translation
                    // is refused rather than losing it.
                    guard SourceScriptRomanizer.isReadinglessMark(span.text) else { return nil }
                    keptRenderings[span.text] = ""
                    continue
                }
                let enclosing = wholeRuns.first { $0.range.contains(span.range.lowerBound) }?.text ?? span.text
                guard spanReadings.allSatisfy({ DisplayLanguageResidue.isNameLike(span.text, language: $0) }),
                      readings(of: enclosing).allSatisfy({ DisplayLanguageResidue.isNameLike(enclosing, language: $0) }),
                      line.contains(span.text) else {
                    return nil
                }
                keptRenderings[span.text] = romanization
                romanized.insert(span.text)
            }
            // One kept name is always allowed; several must stay a clear
            // minority of the line, or the "translation" is a list of terms.
            let romanizedCharacters = kept.filter { romanized.contains($0.text) }.reduce(0) { $0 + $1.text.count }
            guard romanized.count < 2 || romanizedCharacters * 4 <= line.count else { return nil }
            // The translation's own words, without the kept spans, must
            // stand for the rest of the line.
            let ownWords = DisplayLanguageGuard.replacing(
                kept,
                in: translation,
                with: Dictionary(kept.map { ($0.text, "") }, uniquingKeysWith: { first, _ in first }),
                targetLanguage: targetCode
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let restOfLine = Set(kept.map(\.text)).sorted { $0.count > $1.count }
                .reduce(line) { $0.replacingOccurrences(of: $1, with: "") }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard DisplayTermRenderingPrompt.width(of: ownWords)
                    >= max(1, DisplayTermRenderingPrompt.width(of: restOfLine) / 3) else {
                return nil
            }
            displayLanguageGuardLogger.debug(
                "Display line translation kept terms resolved=\(keptRenderings.count, privacy: .public) romanized=\(romanized.count, privacy: .public)"
            )
            return DisplayLanguageResidue.normalizedTypography(
                DisplayLanguageGuard.replacing(kept, in: translation, with: keptRenderings, targetLanguage: targetCode),
                targetLanguage: targetLanguage.identifier
            )
        }

        /// No residue beyond what the surface keeps verbatim: quoted wording
        /// where quotes are content, and the reader's own words.
        private func isResidueFree(_ text: String) -> Bool {
            let readerText = source.readerText ?? ""
            return DisplayLanguageResidue.spans(
                in: text,
                targetLanguage: targetLanguage.identifier,
                preservingQuoted: source.preservesQuotedText,
                keeping: readerWords
            ).allSatisfy { readerText.isEmpty == false && readerText.contains($0.text) }
        }

        /// Term-sized renderings no live pair already claims on either side.
        /// Whole-line translations never reach here.
        func mintableObservations(_ generated: [String: String]) -> [TranslationGlossaryObservation]? {
            let observedAt = Date()
            let observations = generated.keys.sorted().compactMap { span -> TranslationGlossaryObservation? in
                guard let rendering = generated[span],
                      let language = languages[span] ?? nil,
                      language != targetCode,
                      DisplayLanguageResidue.isTermLike(span, language: language),
                      DisplayTermRenderingPrompt.isMintable(rendering),
                      glossary.claims(term: span, language: language) == false,
                      glossary.claims(term: rendering, language: targetCode) == false else {
                    return nil
                }
                return TranslationGlossaryObservation(
                    evidenceKey: "modelRendering",
                    kind: .modelRendering,
                    language1: language,
                    term1: span,
                    language2: targetCode,
                    term2: rendering,
                    authoredSurfaces: ["\(span) => \(rendering)"],
                    sourceMessageID: source.messageID,
                    sourceDraftID: nil,
                    sourceAccountID: source.accountID,
                    sourceAuthorAddress: nil,
                    excerpt: String(source.context.prefix(240)),
                    observedAt: observedAt,
                    strength: TranslationGlossaryPolicy.modelRenderingStrength
                )
            }
            return observations.isEmpty ? nil : observations
        }

        /// Romanizes the terms no authority rendered, drops marks that have
        /// no reading, and replaces each passage line with its translation.
        /// A field with any untranslated passage line, or with a term nothing
        /// can read (a kanji the Japanese reader lacks), is returned exactly as
        /// written and reported rather than losing that word; `transient` says
        /// why the pass ended.
        func finished(transient: Bool) -> Resolution {
            var complete = renderings
            var unreadable = Set<String>()
            for span in termSpans where complete[span] == nil {
                if let romanization = (languages[span] ?? nil).flatMap({ SourceScriptRomanizer.romanize(span, language: $0) }) {
                    complete[span] = romanization
                } else if SourceScriptRomanizer.isReadinglessMark(span) {
                    complete[span] = ""
                } else {
                    unreadable.insert(span)
                }
            }
            var untranslated = Set<Int>()
            let displayed = fields.indices.map { index -> String in
                let field = fields[index]
                let lines = passageLines.indices.filter { passageLines[$0].field == index }
                var spans = spansByField[index]
                var replacements = complete
                if lines.isEmpty == false {
                    guard lines.allSatisfy({ translations[$0] != nil }) else {
                        untranslated.insert(index)
                        return field
                    }
                    spans.removeAll { span in
                        lines.contains { passageLines[$0].range.contains(span.range.lowerBound) }
                    }
                    for line in lines {
                        spans.append(DisplayLanguageResidue.Span(range: passageLines[line].range, text: passageLines[line].text))
                        replacements[passageLines[line].text] = translations[line]
                    }
                    spans.sort { $0.range.lowerBound < $1.range.lowerBound }
                }
                guard spans.contains(where: { unreadable.contains($0.text) }) == false else {
                    untranslated.insert(index)
                    return field
                }
                let replaced = DisplayLanguageGuard.replacing(
                    spans,
                    in: field,
                    with: replacements,
                    targetLanguage: targetCode
                )
                return DisplayLanguageResidue.normalizedTypography(replaced, targetLanguage: targetLanguage.identifier)
            }
            if untranslated.isEmpty == false {
                displayLanguageGuardLogger.notice(
                    "Display passages left untranslated fields=\(untranslated.count, privacy: .public) of=\(fields.count, privacy: .public)"
                )
            }
            return Resolution(
                fields: displayed,
                untranslated: untranslated,
                isTransient: transient && untranslated.isEmpty == false
            )
        }
    }

    /// Nil when no field carries residue, so callers return without any
    /// store access.
    private func prepare(
        _ fields: [String],
        targetLanguage: SummarizationTargetLanguage,
        source: Source
    ) -> Pass? {
        let target = targetLanguage.identifier
        guard let targetCode = LocalModelLanguageSupport.canonicalLanguageID(for: target) else { return nil }
        let readerText = source.readerText ?? ""
        let readerWords = DisplayLanguageResidue.readerWords(in: source.readerText, targetLanguage: target)
        let allSpansByField = fields.map { field in
            DisplayLanguageResidue.spans(
                in: field,
                targetLanguage: target,
                preservingQuoted: source.preservesQuotedText,
                keeping: readerWords
            )
        }
        let isReaderOwn = { (span: DisplayLanguageResidue.Span) in
            readerText.isEmpty == false && readerText.contains(span.text)
        }
        let spansByField = allSpansByField.map { $0.filter { isReaderOwn($0) == false } }
        var uniqueSpans: [String] = []
        var seen = Set<String>()
        for span in spansByField.flatMap({ $0 }) where seen.insert(span.text).inserted {
            uniqueSpans.append(span.text)
        }
        guard uniqueSpans.isEmpty == false else { return nil }

        let languages = Dictionary(uniqueKeysWithValues: uniqueSpans.map { span in
            (span, DisplayLanguageResidue.sourceLanguage(
                ofSpan: span,
                sourceLanguageHint: source.languageHint,
                sourceContext: source.context
            ))
        })
        let glossary = container.map { DisplayGlossarySnapshot.load(from: $0, targetLanguage: targetCode) }
            ?? .empty
        var renderings: [String: String] = [:]
        // A weekday character in parentheses after a date everywhere it
        // occurs needs no other authority; `replacing` renders each such
        // occurrence.
        var weekdayEverywhere: [String: Bool] = [:]
        for (field, spans) in zip(fields, spansByField) {
            for span in spans {
                let afterDate = Self.isWeekdayAfterDate(span.range, in: field, targetLanguage: targetCode)
                weekdayEverywhere[span.text] = (weekdayEverywhere[span.text] ?? true) && afterDate
            }
        }
        for span in uniqueSpans {
            renderings[span] = Self.authorityRendering(
                of: span,
                language: languages[span] ?? nil,
                targetCode: targetCode,
                glossary: glossary,
                weekdayEverywhere: weekdayEverywhere[span] == true
            )
        }

        // A line holding any passage the authorities above left unrendered
        // is translated whole; every other span is a term. Passage status is
        // read on the runs as written: carving the reader's own words out of
        // a clause (総務チームの資料を確認 around 資料) must not leave pieces that
        // pass for terms. The reader's words only stay unreplaced.
        let passages = Set(uniqueSpans.filter {
            renderings[$0] == nil && DisplayLanguageResidue.isPassage($0, language: languages[$0] ?? nil)
        })
        let wholeRunsByField = readerWords.isEmpty
            ? spansByField
            : fields.map { field in
                DisplayLanguageResidue.spans(
                    in: field,
                    targetLanguage: target,
                    preservingQuoted: source.preservesQuotedText
                ).filter { isReaderOwn($0) == false }
            }
        var passageLines: [Pass.PassageLine] = []
        for (index, field) in fields.enumerated() {
            let fieldPassages: [(range: Range<String.Index>, language: String?)] = spansByField[index]
                .filter { passages.contains($0.text) }
                .map { ($0.range, languages[$0.text] ?? nil) }
                + wholeRunsByField[index].compactMap { run in
                    let language = DisplayLanguageResidue.sourceLanguage(
                        ofSpan: run.text,
                        sourceLanguageHint: source.languageHint,
                        sourceContext: source.context
                    )
                    guard Self.authorityRendering(
                        of: run.text,
                        language: language,
                        targetCode: targetCode,
                        glossary: glossary,
                        weekdayEverywhere: Self.isWeekdayAfterDate(run.range, in: field, targetLanguage: targetCode)
                    ) == nil,
                        DisplayLanguageResidue.isPassage(run.text, language: language) else { return nil }
                    return (run.range, language)
                }
            guard fieldPassages.isEmpty == false else { continue }
            for line in Self.lineRanges(in: field) {
                guard let first = fieldPassages.first(where: { line.contains($0.range.lowerBound) }) else { continue }
                let text = String(field[line])
                let readerOwn = readerWords.filter { text.contains($0) }
                    + allSpansByField[index]
                        .filter { line.contains($0.range.lowerBound) && isReaderOwn($0) }
                        .map(\.text)
                let quoted = source.preservesQuotedText
                    ? DisplayLanguageResidue.quotedResidue(in: text, targetLanguage: target)
                    : []
                let protected = DisplayLanguageResidue.protectedTexts(
                    in: DisplayLanguageResidue.normalizedTypography(text, targetLanguage: target)
                )
                passageLines.append(Pass.PassageLine(
                    field: index,
                    range: line,
                    text: text,
                    language: first.language,
                    verbatim: Self.distinct(protected + quoted + readerOwn)
                ))
            }
        }
        var termSpans: [String] = []
        var seenTerms = Set<String>()
        for (index, spans) in spansByField.enumerated() {
            let lines = passageLines.filter { $0.field == index }.map(\.range)
            for span in spans where lines.contains(where: { $0.contains(span.range.lowerBound) }) == false {
                if seenTerms.insert(span.text).inserted { termSpans.append(span.text) }
            }
        }
        return Pass(
            fields: fields,
            spansByField: spansByField,
            passageLines: passageLines,
            termSpans: termSpans,
            languages: languages,
            glossary: glossary,
            targetLanguage: targetLanguage,
            targetCode: targetCode,
            source: source,
            readerWords: readerWords,
            renderings: renderings
        )
    }

    /// A span's rendering by the authorities ahead of the model, in order: a
    /// weekday character read in parentheses after a date wherever it occurs,
    /// a date, time, currency, or placeholder rendering, then an active
    /// glossary pair.
    private static func authorityRendering(
        of span: String,
        language: String?,
        targetCode: String,
        glossary: DisplayGlossarySnapshot,
        weekdayEverywhere: Bool
    ) -> String? {
        if weekdayEverywhere,
           let weekday = DisplayNumericExpressions.parenthesizedWeekdayRendering(span, targetLanguage: targetCode) {
            return weekday
        }
        if let numeric = DisplayNumericExpressions.rendering(of: span, sourceLanguage: language, targetLanguage: targetCode) {
            return numeric
        }
        // Marks with no reading are dropped, never the digits beside them
        // ("6/17〆" → "6/17").
        if let unmarked = SourceScriptRomanizer.withoutReadinglessMarks(span) {
            return unmarked
        }
        guard let language else { return nil }
        return glossary.rendering(of: span, sourceLanguage: language)
    }

    private static func distinct(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        return texts.filter { $0.isEmpty == false && seen.insert($0).inserted }
    }

    /// Each line's content without its indentation or trailing whitespace, so
    /// a translated line keeps its list or paragraph layout.
    static func lineRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var lineStart = text.startIndex
        while true {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            var lower = lineStart
            var upper = lineEnd
            while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
            while upper > lower, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
            if lower < upper { ranges.append(lower..<upper) }
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        return ranges
    }

    private static func generate(
        engine: any TrainingEngine,
        prompt: (prompt: PrefixCachedPrompt, maxTokens: Int),
        priority: TaskPriority
    ) async throws -> String {
        let cancellation = GenerationCancellation()
        let task = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try PrefixCachedGeneration.generate(
                engine: engine,
                prompt: prompt.prompt,
                maxTokens: prompt.maxTokens,
                cancellation: cancellation
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
    }

    private static func logRenderingFailure(_ error: Error) {
        displayLanguageGuardLogger.error(
            "Display term rendering failed errorKind=\(String(reflecting: type(of: error)), privacy: .public)"
        )
    }

    // MARK: - Glossary minting

    @MainActor
    private static func mint(_ observations: [TranslationGlossaryObservation], into container: ModelContainer) {
        do {
            let inserted = try TranslationGlossaryRepository(modelContext: ModelContext(container))
                .insertModelRenderings(observations, now: Date())
            displayLanguageGuardLogger.debug(
                "Display term rendering minted pairs=\(inserted, privacy: .public)"
            )
        } catch {
            displayLanguageGuardLogger.error(
                "Display term rendering mint failed errorKind=\(String(reflecting: type(of: error)), privacy: .public)"
            )
        }
    }

    // MARK: - Replacement

    /// Rewrites each span. A space is added only where a Latin word or digit,
    /// or (for a target that spaces its words) kanji or kana kept verbatim,
    /// would otherwise touch the replacement's Latin edge, so Korean particles
    /// and Russian endings stay attached; an empty replacement removes the
    /// span and its now-doubled space, or, at the start of the text or of a
    /// line, the space after it. A weekday character in parentheses directly
    /// after a date ("10月5日（金）") reads as that weekday.
    static func replacing(
        _ spans: [DisplayLanguageResidue.Span],
        in text: String,
        with renderings: [String: String],
        targetLanguage: String
    ) -> String {
        var output = text
        for span in spans.reversed() {
            let before = span.range.lowerBound > text.startIndex ? text[text.index(before: span.range.lowerBound)] : nil
            let after = span.range.upperBound < text.endIndex ? text[span.range.upperBound] : nil
            let weekday = isWeekdayAfterDate(span.range, in: text, targetLanguage: targetLanguage)
                ? DisplayNumericExpressions.parenthesizedWeekdayRendering(span.text, targetLanguage: targetLanguage)
                : nil
            guard var replacement = weekday ?? renderings[span.text] else { continue }
            if replacement.isEmpty {
                var removal = span.range
                if let before, before.isWhitespace, before.isNewline == false,
                   after == nil || after?.isWhitespace == true || after.map(isClosingPunctuation) == true {
                    removal = text.index(before: span.range.lowerBound)..<span.range.upperBound
                } else if before == nil || before?.isNewline == true,
                          let after, after.isWhitespace, after.isNewline == false {
                    removal = span.range.lowerBound..<text.index(after: span.range.upperBound)
                }
                output.replaceSubrange(removal, with: "")
                continue
            }
            if let before, let first = replacement.first,
               needsSpace(between: before, and: first, targetLanguage: targetLanguage) {
                replacement = " " + replacement
            }
            if let after, let last = replacement.last,
               needsSpace(between: after, and: last, targetLanguage: targetLanguage) {
                replacement += " "
            }
            output.replaceSubrange(span.range, with: replacement)
        }
        return output
    }

    /// Whether a replacement's Latin edge needs a space from its neighbour: a
    /// Latin word or digit, or, where the target spaces its words, kanji or
    /// kana the text keeps verbatim (the reader's own 総務チーム).
    private static func needsSpace(between neighbour: Character, and edge: Character, targetLanguage: String) -> Bool {
        guard isLatinWordCharacter(edge) else { return false }
        if isLatinWordCharacter(neighbour) { return true }
        guard targetLanguage != "ja", targetLanguage != "zh" else { return false }
        return neighbour.unicodeScalars.contains {
            let family = DisplayScriptFamily.of($0)
            return family == .han || family == .kana
        }
    }

    /// A weekday character in parentheses read as a weekday only directly
    /// after a date. The text before the opening parenthesis, ignoring spaces,
    /// must end in a date:
    /// - a numbered source-script day, in digits or kanji numerals ("10月5日",
    ///   "5日", "十月五日", "5일"), or a word for one particular day ("明日",
    ///   "本日", "翌日", "내일"); a word for days in general is not one ("毎日",
    ///   "平日", "休日");
    /// - a numeric date whose month and day are valid, in either order for the
    ///   slash and dotted forms ("10/9", "10/5/2026", "2026/10/5", "5.10.",
    ///   "5.10.2026", "2026-10-05"; never "50/50");
    /// - a day beside a month name of the target language, either order, with
    ///   an optional year ("October 5", "October 5th, 2026", "5 octobre 2026",
    ///   "5. Oktober", "5 de octubre de 2026").
    /// Elsewhere 金 is gold and 月 is the moon ("Item 3 (金)").
    static func isWeekdayAfterDate(
        _ range: Range<String.Index>,
        in text: String,
        targetLanguage: String
    ) -> Bool {
        guard isParenthesized(range, in: text) else { return false }
        let open = text.index(before: range.lowerBound)
        let before = String(text[..<open].suffix(48))
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespaces)
        guard before.isEmpty == false else { return false }
        if endsInDayWord(before) || endsInNumericDate(before) { return true }
        guard let months = monthNamePattern(targetLanguage: targetLanguage) else { return false }
        return months.firstMatch(in: before, range: NSRange(before.startIndex..<before.endIndex, in: before)) != nil
    }

    /// Whether the text ends in a numbered day (5日, 十月五日, 5일) or a word
    /// for one particular day.
    private static func endsInDayWord(_ text: String) -> Bool {
        if let numbered = numberedDay, numbered.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil {
            return true
        }
        return particularDayWords.contains { text.hasSuffix($0) }
    }

    private static let numberedDay = try? NSRegularExpression(pattern: #"(?:\d{1,2}|[〇一二三四五六七八九十]{1,3})[日일]$"#)

    /// Words naming one particular day, so a weekday after them is that
    /// day's: today, tomorrow, the day after tomorrow, yesterday (一昨日 ends
    /// in 昨日), that day, the next day, the day before, the same day.
    private static let particularDayWords = [
        "今日", "本日", "明日", "明後日", "昨日", "当日", "翌日", "前日", "同日", "오늘", "내일", "모레",
    ]

    /// Whether the text ends in a numeric date with a valid month (1–12) and
    /// day (1–31): month and day either way round for the slash and dotted
    /// forms, month first for the year-first forms.
    private static func endsInNumericDate(_ text: String) -> Bool {
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        for (pattern, eitherOrder) in numericDatePatterns {
            guard let match = pattern.firstMatch(in: text, range: whole),
                  let first = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
                  let second = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }) else { continue }
            let months = 1...12, days = 1...31
            if months.contains(first) && days.contains(second)
                || eitherOrder && months.contains(second) && days.contains(first) {
                return true
            }
        }
        return false
    }

    private static let numericDatePatterns: [(NSRegularExpression, eitherOrder: Bool)] = [
        (#"(?<![\d/])(\d{1,2})/(\d{1,2})(?:/\d{2,4})?$"#, true),
        (#"(?<![\d/])\d{4}/(\d{1,2})/(\d{1,2})$"#, false),
        (#"(?<![\d.])(\d{1,2})\.\s?(\d{1,2})\.(?:\s?\d{2,4})?$"#, true),
        (#"(?<!\d)\d{4}-(\d{1,2})-(\d{1,2})$"#, false),
    ].compactMap { pattern, eitherOrder in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, eitherOrder) }
    }

    /// A day number beside one of the target locale's month names, either
    /// order, with an optional year, at the end of the text.
    private static func monthNamePattern(targetLanguage: String) -> NSRegularExpression? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: targetLanguage)
        let names = [
            formatter.monthSymbols, formatter.shortMonthSymbols,
            formatter.standaloneMonthSymbols, formatter.shortStandaloneMonthSymbols,
        ].compactMap { $0 }.flatMap { $0 }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { $0.isEmpty == false }
        guard names.isEmpty == false else { return nil }
        let month = "(?:" + Set(names).sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|") + ")"
        let year = #"(?:,?\s*(?:de\s+)?\d{4})?"#
        let monthFirst = month + #"\.?\s*\d{1,2}(?:st|nd|rd|th)?"# + year
        let dayFirst = #"\d{1,2}\.?\s*(?:de\s+)?"# + month + #"\.?"# + year
        return try? NSRegularExpression(pattern: "(?:\(monthFirst)|\(dayFirst))$", options: [.caseInsensitive])
    }

    static func isParenthesized(_ range: Range<String.Index>, in text: String) -> Bool {
        guard range.lowerBound > text.startIndex, range.upperBound < text.endIndex else { return false }
        let before = text[text.index(before: range.lowerBound)]
        let after = text[range.upperBound]
        return (before == "(" || before == "\u{FF08}") && (after == ")" || after == "\u{FF09}")
    }

    private static func isLatinWordCharacter(_ character: Character) -> Bool {
        if character.isNumber { return true }
        return character.isLetter && character.unicodeScalars.allSatisfy { DisplayScriptFamily.of($0) == .latin }
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        ".,;:!?)]}\u{201D}\u{2019}".contains(character)
    }
}

/// One fetch of the canonical glossary, indexed for a single target language.
struct DisplayGlossarySnapshot: Sendable {
    struct Entry: Sendable {
        let sourceLanguage: String
        let sourceTerm: String
        let rendering: String
        let usable: Bool
        let confirmed: Bool
        let confidence: Double

        /// Usable before excluded, confirmed before inferred, then confidence.
        func outranks(_ other: Entry) -> Bool {
            if usable != other.usable { return usable }
            if confirmed != other.confirmed { return confirmed }
            return confidence > other.confidence
        }
    }

    private let entriesBySourceKey: [String: Entry]
    private let claimedKeys: Set<String>
    private let deletedCanonicalKeys: Set<String>
    private let targetLanguage: String

    static let empty = DisplayGlossarySnapshot(
        entriesBySourceKey: [:],
        claimedKeys: [],
        deletedCanonicalKeys: [],
        targetLanguage: ""
    )

    static func load(from container: ModelContainer, targetLanguage: String) -> DisplayGlossarySnapshot {
        let rows = (try? ModelContext(container).fetch(FetchDescriptor<TranslationGlossaryPair>())) ?? []
        return snapshot(rows: rows.map {
            Row(
                languageA: $0.canonicalLanguageA, termA: $0.termA,
                languageB: $0.canonicalLanguageB, termB: $0.termB,
                canonicalKey: $0.canonicalKey, statusRaw: $0.statusRaw, confidence: $0.confidence
            )
        }, targetLanguage: targetLanguage)
    }

    struct Row: Sendable {
        let languageA: String, termA: String
        let languageB: String, termB: String
        let canonicalKey: String, statusRaw: String, confidence: Double
    }

    static func snapshot(rows: [Row], targetLanguage: String) -> DisplayGlossarySnapshot {
        var entries: [String: Entry] = [:]
        var claimed = Set<String>()
        var deleted = Set<String>()
        for row in rows {
            let status = TranslationGlossaryPairStatus(rawValue: row.statusRaw) ?? .inferred
            guard status != .deleted else {
                deleted.insert(row.canonicalKey)
                continue
            }
            claimed.insert(key(row.languageA, row.termA))
            claimed.insert(key(row.languageB, row.termB))
            let usable = TranslationGlossaryPolicy.authority(status: status, confidence: row.confidence) != .excluded
            let confirmed = status == .confirmed
            let entry: Entry
            if row.languageB == targetLanguage {
                entry = Entry(
                    sourceLanguage: row.languageA, sourceTerm: row.termA, rendering: row.termB,
                    usable: usable, confirmed: confirmed, confidence: row.confidence
                )
            } else if row.languageA == targetLanguage {
                entry = Entry(
                    sourceLanguage: row.languageB, sourceTerm: row.termB, rendering: row.termA,
                    usable: usable, confirmed: confirmed, confidence: row.confidence
                )
            } else {
                continue
            }
            let sourceKey = key(entry.sourceLanguage, entry.sourceTerm)
            if let existing = entries[sourceKey], existing.outranks(entry) { continue }
            entries[sourceKey] = entry
        }
        return DisplayGlossarySnapshot(
            entriesBySourceKey: entries,
            claimedKeys: claimed,
            deletedCanonicalKeys: deleted,
            targetLanguage: targetLanguage
        )
    }

    private init(
        entriesBySourceKey: [String: Entry],
        claimedKeys: Set<String>,
        deletedCanonicalKeys: Set<String>,
        targetLanguage: String
    ) {
        self.entriesBySourceKey = entriesBySourceKey
        self.claimedKeys = claimedKeys
        self.deletedCanonicalKeys = deletedCanonicalKeys
        self.targetLanguage = targetLanguage
    }

    func rendering(of span: String, sourceLanguage: String) -> String? {
        guard let entry = entriesBySourceKey[Self.key(sourceLanguage, span)], entry.usable else { return nil }
        return entry.rendering
    }

    /// Whether any live pair already uses this term on its language's side.
    func claims(term: String, language: String) -> Bool {
        claimedKeys.contains(Self.key(language, term))
    }

    /// A rendering the user deleted for this exact term is never shown again.
    func isRejected(span: String, rendering: String, sourceLanguage: String?) -> Bool {
        guard let sourceLanguage else { return false }
        let canonical = TranslationGlossaryCanonicalizer.canonicalPair(
            language1: sourceLanguage, term1: span,
            language2: targetLanguage, term2: rendering
        )
        return deletedCanonicalKeys.contains(canonical.canonicalKey)
    }

    /// Usable pairs whose source term occurs inside an unresolved span, so a
    /// longer span reuses the established rendering of its parts.
    func established(
        within spans: [String],
        languages: [String: String?]
    ) -> [DisplayTermRenderingPrompt.EstablishedRendering] {
        var result: [DisplayTermRenderingPrompt.EstablishedRendering] = []
        var seen = Set<String>()
        for entry in entriesBySourceKey.values.sorted(by: { $0.sourceTerm.count > $1.sourceTerm.count })
        where entry.usable {
            guard spans.contains(where: { span in
                (languages[span] ?? nil) == entry.sourceLanguage && span.contains(entry.sourceTerm)
            }), seen.insert(entry.sourceTerm).inserted else { continue }
            result.append(.init(sourceTerm: entry.sourceTerm, rendering: entry.rendering))
            if result.count == DisplayTermRenderingPrompt.maximumEstablished { break }
        }
        return result
    }

    private static func key(_ language: String, _ term: String) -> String {
        "\(TranslationGlossaryCanonicalizer.baseLanguageCode(language))|\(TranslationGlossaryCanonicalizer.normalizedIdentityTerm(term))"
    }
}

public extension SummarizationTargetLanguage {
    /// The language a reader wrote in, for answers addressed back to them:
    /// the confident dominant language of `text`, else the language its
    /// script implies, else `fallback`.
    static func readerLanguage(
        of text: String,
        fallback: SummarizationTargetLanguage = .ohiaPreferred()
    ) -> SummarizationTargetLanguage {
        let detected = EmailLanguageDetector.detectDominantLanguageCode(in: text)
            .flatMap(LocalModelLanguageSupport.canonicalLanguageID(for:))
            ?? DisplayLanguageResidue.sourceLanguage(ofSpan: text, sourceLanguageHint: nil, sourceContext: text)
        guard let detected else { return fallback }
        return current(preferredLanguages: [detected], displayLocale: Locale(identifier: "en_US_POSIX"))
    }

    /// Whether `text` names a supported language other than this one, in this
    /// language, in that language's own name, or in English ("in Japanese",
    /// "日本語で", "en japonais"): a question about another language's wording
    /// expects that wording verbatim in the answer.
    func isNamedOtherLanguage(in text: String) -> Bool {
        guard let reader = LocalModelLanguageSupport.canonicalLanguageID(for: identifier) else { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return LocalModelLanguageSupport.supportedLanguageIDs.contains { code in
            guard code != reader else { return false }
            let names = [
                Locale(identifier: reader).localizedString(forLanguageCode: code),
                Locale(identifier: code).localizedString(forLanguageCode: code),
                Locale(identifier: "en").localizedString(forLanguageCode: code),
            ].compactMap { $0 }
            return names.contains { name in
                name.isEmpty == false && text.range(of: name, options: options) != nil
            }
        }
    }
}
