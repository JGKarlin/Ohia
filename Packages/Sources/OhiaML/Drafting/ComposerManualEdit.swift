import Foundation
import SwiftData
import OhiaCore

extension ComposerManualEdit {
    /// Capture the author action before queuing model work. Neither saving
    /// nor generating a new body may reset the parent to a different branch.
    @MainActor
    public static func recordSnapshot(on draft: Draft, context: ModelContext) throws {
        let parent: DraftRevision?
        if let id = draft.baseRevisionID {
            guard let recorded = draft.orderedRevisions.first(where: { $0.id == id }) else {
                throw ComposerContentError.invalidRequest("The edited draft's recorded parent is unavailable.")
            }
            parent = recorded
        } else {
            parent = draft.baseGeneratedRevision
        }
        guard let parent, parent.bodyText != draft.replyText else { return }
        let revision = DraftRevision(draft: draft, index: draft.nextRevisionIndex,
            bodyText: draft.replyText, bodyHTML: draft.bodyHTML, triggerRaw: DraftRevisionTrigger.manualEdit,
            styleRegisterID: draft.styleRegisterID, styleControlSnapshot: draft.styleControlSnapshot,
            generatedSourcesJSON: draft.generatedSourcesJSON, baseRevisionID: parent.id)
        context.insert(revision)
        draft.baseRevisionID = revision.id
    }

    /// Widen a character delta to its edited word without copying the whole
    /// edited sentence (which is part of the target in a training example).
    var anchoredReplacement: String {
        let replacement = self.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty, let context = contextAfter else { return replacement }
        var range: Range<String.Index>?
        if let offset = contextAfterOffset, offset >= 0, offset + self.replacement.count <= context.count {
            let lower = context.index(context.startIndex, offsetBy: offset)
            let upper = context.index(lower, offsetBy: self.replacement.count)
            if context[lower..<upper] == self.replacement { range = lower..<upper }
        }
        guard let range = range ?? context.range(of: self.replacement) else { return replacement }
        func joins(_ character: Character) -> Bool {
            (character.isLetter || character.isNumber)
                && !character.unicodeScalars.contains { $0.value >= 0x3000 && $0.value <= 0x9FFF || $0.value >= 0xAC00 && $0.value <= 0xD7AF }
        }
        var lower = range.lowerBound
        while lower > context.startIndex, joins(context[context.index(before: lower)]) {
            lower = context.index(before: lower)
        }
        var upper = range.upperBound
        while upper < context.endIndex, joins(context[upper]) {
            upper = context.index(after: upper)
        }
        let widened = String(context[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        return widened.isEmpty ? replacement : widened
    }

    public static func capture(original: String, edited: String, baseRevisionID: UUID?, sequence: Int? = nil,
                               authoredRevisionID: UUID? = nil, authoredAt: Date? = nil) throws -> [Self] {
        guard original != edited else { return [] }
        guard baseRevisionID != nil || original.isEmpty else {
            throw ComposerContentError.invalidRequest("The edited text has no recorded base revision.")
        }
        let before = Array(original), after = Array(edited)
        func context(_ text: String, start: Int, end: Int) -> (text: String, start: Int)? {
            let passages = ComposerTextPassage.index(text, prefix: "")
            let selected = passages.filter { passage in
                start == end ? passage.start <= start && start < passage.end
                    : passage.start < end && passage.end > start
            }
            guard let lower = selected.first?.start, let upper = selected.last?.end else { return nil }
            return (String(Array(text)[lower..<upper]), lower)
        }
        let difference = after.difference(from: before)
        var removals = Set<Int>(), insertions = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var result: [Self] = []
        var old = 0, new = 0
        while old < before.count || new < after.count {
            let oldStart = old, newStart = new
            while removals.contains(old) { old += 1 }
            while insertions.contains(new) { new += 1 }
            if old != oldStart || new != newStart {
                let removed = String(before[oldStart..<old])
                let prefix = String(before[..<oldStart])
                let occurrence = removed.isEmpty ? oldStart : prefix.components(separatedBy: removed).count - 1
                let contextAfter = context(edited, start: newStart, end: new)
                result.append(Self(baseRevisionID: baseRevisionID, original: removed,
                    replacement: String(after[newStart..<new]), occurrence: occurrence, sequence: sequence,
                    baseCharacterOffset: oldStart,
                    contextBefore: context(original, start: oldStart, end: old)?.text ?? "",
                    contextAfter: contextAfter?.text ?? "",
                    contextAfterOffset: contextAfter.map { newStart - $0.start },
                    authoredRevisionID: authoredRevisionID, authoredAt: authoredAt))
            } else {
                guard old < before.count, new < after.count, before[old] == after[new] else {
                    throw ComposerContentError.invalidRequest("The manual edit cannot be anchored to its recorded base.")
                }
                old += 1
                new += 1
            }
        }
        guard try applying(result, to: original) == edited else {
            throw ComposerContentError.invalidRequest("The recorded manual changes do not reproduce the edited text.")
        }
        return result.filter { !$0.isLayoutOnly }
    }

    /// A change of whitespace alone (the editor joining or splitting
    /// paragraph breaks) is layout, not a decision of the author's. Bases
    /// recorded before this rule still carry such edits; every reader drops
    /// them so inference and training see the same author history.
    var isLayoutOnly: Bool {
        original.allSatisfy(\.isWhitespace) && replacement.allSatisfy(\.isWhitespace)
    }

    public static func applying(_ edits: [Self], to original: String) throws -> String {
        let base = Array(original)
        var spans: [(start: Int, end: Int, replacement: String)] = []
        for edit in edits {
            guard let start = edit.baseCharacterOffset, start >= 0,
                  start <= base.count, start + edit.original.count <= base.count else {
                throw ComposerContentError.invalidRequest("The manual edit has no valid position in its recorded base.")
            }
            let end = start + edit.original.count
            guard String(base[start..<end]) == edit.original else {
                throw ComposerContentError.invalidRequest("The manual edit's original passage has changed.")
            }
            spans.append((start, end, edit.replacement))
        }
        spans.sort { $0.start < $1.start }
        var position = 0, output = ""
        for span in spans {
            guard span.start >= position else { throw ComposerContentError.invalidRequest("The manual edits overlap.") }
            output += String(base[position..<span.start]) + span.replacement
            position = span.end
        }
        return output + String(base[position...])
    }
}
