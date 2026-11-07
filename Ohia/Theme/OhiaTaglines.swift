import Foundation

enum OhiaTaglines {
    static let all: [String] = [
        "Meaning emerges from the connections.",
        "Structure beneath the surface.",
        "Patterns form. Meaning follows.",
        "Connections reveal what was always there.",
        "No mind. Just pattern.",
        "Every message leaves a trace.",
        "Your words left traces.",
        "There is no inbox. Only signal.",
        "A spatial interface for your email.",
        "Structure, not inbox. Meaning, not folders.",
        "Enter anywhere. The network is already there.",
        "No hierarchy. Only connection.",
        "Every entry point is the right one.",
        "No root. No center. Only connection.",
        "Folders are walls.",
        "Intensity without hierarchy.",
        "Become the correspondence.",
        "Coherence without a center.",
        "What persists across the signals.",
        "Pattern beneath the noise.",
        "The network holds what no single node contains.",
        "Nothing acts alone.",
        "Meaning forms at the junction, not the origin.",
        "No single message holds the meaning.",
        "The social is in the connections.",
        "The email existed before you read it.",
        "No message more central than another.",
        "Not a hierarchy of importance. A field of objects.",
        "Every message, its own world.",
        "Objects relate. Meaning follows.",
        "The message was something before you opened it.",
        "Not yours to organize. Its own to be.",
        "A pattern in the flow.",
    ]

    static var random: String {
        all.randomElement()!
    }
}
