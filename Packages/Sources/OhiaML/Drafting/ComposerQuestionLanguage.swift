import Foundation

/// The language Draft Questions are written in: the author's reading language
/// (Settings → Languages → Summaries & translation), whatever language the
/// correspondence or the email uses. Planner and repair prompts, reply
/// preparation fingerprints and interview input fingerprints all read it
/// here, so a prepared or planned interview is current only in this language.
public enum ComposerQuestionLanguage {
    /// Where `current()` reads from. A task tree can scope another source,
    /// as tests do to change the language without the stored setting.
    @TaskLocal public static var source: @Sendable () -> SummarizationTargetLanguage = {
        .ohiaPreferred()
    }

    public static func current() -> SummarizationTargetLanguage {
        source()
    }

    /// The language an interview recorded when it was planned, described the
    /// way the stored setting is.
    public static func recorded(_ identifier: String) -> SummarizationTargetLanguage {
        .ohiaPreferred(
            summaryOutputLanguage: identifier,
            activeLanguagesData: nil,
            preferredLanguages: []
        )
    }
}
