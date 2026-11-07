// NewStarAlertSound.swift
// Settings and playback for the one-shot mail notification sounds: new-star
// (new-mail arrival), sent-mail confirmation, and send-to-Composer dispatch.
// The bundled-sound catalog is shared for open-ended pickers; Composer uses a
// fixed meteor-family list.
//
// The sound files ship in release builds only: they are licensed for use in
// the app and are not part of the public source. A build without them lists
// "No Sound" alone and plays nothing.

import AppKit
import Foundation

struct NewStarAlertSoundOption: Identifiable, Hashable {
    let filename: String
    let displayName: String

    var id: String { filename }
}

/// Shared catalog of bundled notification sounds. Preference-agnostic: it lists
/// the available sound files, derives display names, and resolves a filename to
/// a bundle URL. The per-use storage key and default filename live on the small
/// preference enums below (`NewStarAlertSoundPreference`, `SentMailSoundPreference`,
/// `ComposerSoundPreference`).
enum AlertSoundCatalog {
    static let noSoundFilename = ""

    /// The leading "No Sound" picker row, shared by every options(...) builder so
    /// the URL-injection variants mirror the bundle-scanning one.
    static var noSoundOption: NewStarAlertSoundOption {
        NewStarAlertSoundOption(filename: noSoundFilename, displayName: "No Sound")
    }

    private static let supportedExtensions = Set([
        "aif",
        "aiff",
        "caf",
        "m4a",
        "mp3",
        "wav"
    ])

    /// Selectable picker options: a leading "No Sound" row, then every sound in
    /// `bundle` not in `excluding`, the default among them when it is bundled.
    static func options(
        ensuring defaultFilename: String,
        excluding excludedFilenames: [String] = [],
        bundle: Bundle = .main
    ) -> [NewStarAlertSoundOption] {
        let soundOptions = options(
            from: soundURLs(bundle: bundle),
            ensuring: defaultFilename,
            excluding: excludedFilenames
        )
        .filter { isBundled($0.filename, bundle: bundle) }
        return [noSoundOption] + soundOptions
    }

    /// Whether `filename` names a sound file in `bundle`.
    static func isBundled(_ filename: String, bundle: Bundle = .main) -> Bool {
        url(forFilename: filename, bundle: bundle) != nil
    }

    /// `filename`, or the silent filename when the sound is not in `bundle`.
    static func playable(_ filename: String, bundle: Bundle) -> String {
        guard filename != noSoundFilename, isBundled(filename, bundle: bundle) else {
            return noSoundFilename
        }
        return filename
    }

    /// The "No Sound" row followed by those of `filenames` that are in `bundle`.
    static func fixedOptions(_ filenames: [String], bundle: Bundle) -> [NewStarAlertSoundOption] {
        [noSoundOption] + filenames
            .filter { isBundled($0, bundle: bundle) }
            .map { NewStarAlertSoundOption(filename: $0, displayName: displayName(forFilename: $0)) }
    }

    static func options(
        from soundURLs: [URL],
        ensuring defaultFilename: String,
        excluding excludedFilenames: [String] = []
    ) -> [NewStarAlertSoundOption] {
        let excluded = Set(excludedFilenames.map { $0.lowercased() })
        var filenames: Set<String> = Set(
            soundURLs
                .map(\.lastPathComponent)
                .filter { !excluded.contains($0.lowercased()) }
        )
        if !excluded.contains(defaultFilename.lowercased()) {
            filenames.insert(defaultFilename)
        }

        return filenames
            .map { filename in
                NewStarAlertSoundOption(
                    filename: filename,
                    displayName: displayName(forFilename: filename)
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    static func displayName(forFilename filename: String) -> String {
        let stem = URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
        guard stem.isEmpty == false else { return filename }

        return stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    static func url(forFilename filename: String, bundle: Bundle = .main) -> URL? {
        guard filename != noSoundFilename else { return nil }

        let fileURL = URL(fileURLWithPath: filename)
        let name = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        guard name.isEmpty == false, ext.isEmpty == false else { return nil }

        for subdirectory in ["Sounds", "Resources/Sounds"] {
            if let url = bundle.url(
                forResource: name,
                withExtension: ext,
                subdirectory: subdirectory
            ) {
                return url
            }
        }

        if let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }

        return soundURLs(bundle: bundle).first { url in
            url.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame
        }
    }

    private static func soundURLs(bundle: Bundle) -> [URL] {
        var urls: [URL] = []

        for ext in supportedExtensions {
            for subdirectory in ["Sounds", "Resources/Sounds"] {
                urls.append(contentsOf: bundle.urls(forResourcesWithExtension: ext, subdirectory: subdirectory) ?? [])
            }
            urls.append(contentsOf: bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
        }

        if urls.isEmpty,
           let resourceURL = bundle.resourceURL,
           let enumerator = FileManager.default.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator {
                guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                urls.append(url)
            }
        }

        var uniqueByFilename: [String: URL] = [:]
        for url in urls {
            uniqueByFilename[url.lastPathComponent.lowercased()] = url
        }
        return Array(uniqueByFilename.values)
    }
}

/// New-mail arrival sound. Plays once when a newly-ingested message forms its
/// node ("a new star"). Composer meteor-family cues are excluded — those live on
/// `ComposerSoundPreference`.
enum NewStarAlertSoundPreference {
    static let storageKey = "newStarAlertSoundFilename"
    static let noSoundFilename = AlertSoundCatalog.noSoundFilename
    static let defaultFilename = "twinkle.caf"

    static func options(bundle: Bundle = .main) -> [NewStarAlertSoundOption] {
        AlertSoundCatalog.options(
            ensuring: defaultFilename,
            excluding: ComposerSoundPreference.allowedFilenames,
            bundle: bundle
        )
    }

    static func options(from soundURLs: [URL]) -> [NewStarAlertSoundOption] {
        [AlertSoundCatalog.noSoundOption] + AlertSoundCatalog.options(
            from: soundURLs,
            ensuring: defaultFilename,
            excluding: ComposerSoundPreference.allowedFilenames
        )
    }

    static func displayName(forFilename filename: String) -> String {
        AlertSoundCatalog.displayName(forFilename: filename)
    }

    static func resolvedFilename(from stored: String?, bundle: Bundle = .main) -> String {
        let candidate = stored ?? defaultFilename
        guard candidate != noSoundFilename else { return noSoundFilename }
        let excluded = Set(ComposerSoundPreference.allowedFilenames.map { $0.lowercased() })
        guard !excluded.contains(candidate.lowercased()) else {
            return AlertSoundCatalog.playable(defaultFilename, bundle: bundle)
        }
        return AlertSoundCatalog.playable(candidate, bundle: bundle)
    }

    static func url(forFilename filename: String, bundle: Bundle = .main) -> URL? {
        AlertSoundCatalog.url(forFilename: resolvedFilename(from: filename, bundle: bundle), bundle: bundle)
    }
}

/// Sent-mail confirmation sound. Plays once when the SMTP server accepts an
/// outgoing message (the confirmed-send moment), gated by the durable
/// `sentConfirmationPendingPlayback` flag on the outbox row. See
/// `SentConfirmationConsumer`.
/// The picker shares the Composer meteor-family cues and adds Coqui.
enum SentMailSoundPreference {
    static let storageKey = "sentMailSoundFilename"
    static let noSoundFilename = AlertSoundCatalog.noSoundFilename
    static let defaultFilename = "comet.caf"
    static let allowedFilenames = ComposerSoundPreference.allowedFilenames + ["coqui.caf"]

    static func options(bundle: Bundle = .main) -> [NewStarAlertSoundOption] {
        AlertSoundCatalog.fixedOptions(allowedFilenames, bundle: bundle)
    }

    static func resolvedFilename(from stored: String?, bundle: Bundle = .main) -> String {
        guard let stored else { return AlertSoundCatalog.playable(defaultFilename, bundle: bundle) }
        guard stored != noSoundFilename else { return noSoundFilename }
        let resolved = allowedFilenames.first { $0.caseInsensitiveCompare(stored) == .orderedSame }
            ?? defaultFilename
        return AlertSoundCatalog.playable(resolved, bundle: bundle)
    }
}

/// Send-to-Composer dispatch sound. Plays once when a message is queued into
/// the Composer and the dispatch comet fires. Options are limited to the bundled
/// meteor-family cues plus silence — see `ComposerSoundPreference.allowedFilenames`.
enum ComposerSoundPreference {
    static let storageKey = "composerSoundFilename"
    static let noSoundFilename = AlertSoundCatalog.noSoundFilename
    static let defaultFilename = "Perseid.caf"

    /// Bundled filenames in picker order. Must match on-disk names under
    /// `Resources/Sounds` (case-sensitive on disk; resolved case-insensitively
    /// when reading a stored preference).
    static let allowedFilenames = [
        "Bolide.caf",
        "comet.caf",
        "Leonid.caf",
        "Meteor.caf",
        "Orionid.caf",
        "Perseid.caf"
    ]

    static func options(bundle: Bundle = .main) -> [NewStarAlertSoundOption] {
        AlertSoundCatalog.fixedOptions(allowedFilenames, bundle: bundle)
    }

    static func displayName(forFilename filename: String) -> String {
        AlertSoundCatalog.displayName(forFilename: filename)
    }

    /// Maps a stored preference to a bundled filename, falling back to the default
    /// when the value is missing or outside the allowed set, and to silence when
    /// the sound is not in the bundle.
    static func resolvedFilename(from stored: String?, bundle: Bundle = .main) -> String {
        guard let stored else { return AlertSoundCatalog.playable(defaultFilename, bundle: bundle) }
        guard stored != noSoundFilename else { return noSoundFilename }
        let resolved = allowedFilenames.first { $0.caseInsensitiveCompare(stored) == .orderedSame }
            ?? defaultFilename
        return AlertSoundCatalog.playable(resolved, bundle: bundle)
    }

    static func url(forFilename filename: String, bundle: Bundle = .main) -> URL? {
        AlertSoundCatalog.url(forFilename: resolvedFilename(from: filename, bundle: bundle), bundle: bundle)
    }
}

final class NewStarAlertSoundPlayer {
    private var currentSound: NSSound?

    @MainActor
    func play(filename: String, bundle: Bundle = .main) {
        currentSound?.stop()
        currentSound = nil

        guard let url = AlertSoundCatalog.url(forFilename: filename, bundle: bundle),
              let sound = NSSound(contentsOf: url, byReference: true) else {
            return
        }

        sound.currentTime = 0
        currentSound = sound
        sound.play()
    }

    /// Build a sound ahead of a tightly-timed play beat, with the sample data
    /// loaded in-memory (`byReference: false`), so file open and decoder setup
    /// are paid up front rather than adding latency on the beat itself. Pair
    /// with `play(prepared:)`.
    @MainActor
    static func prepare(filename: String, bundle: Bundle = .main) -> NSSound? {
        guard let url = AlertSoundCatalog.url(forFilename: filename, bundle: bundle) else {
            return nil
        }
        return NSSound(contentsOf: url, byReference: false)
    }

    /// Play an already-`prepare(filename:)`-built sound on the beat.
    @MainActor
    func play(prepared sound: NSSound) {
        currentSound?.stop()
        sound.currentTime = 0
        currentSound = sound
        sound.play()
    }
}
