// Packages/Sources/OhiaML/Training/EditAnalyzer.swift
import Foundation
import OhiaCore

public protocol EditAnalyzing: Sendable {
    func analyze(
        originalDraft: String,
        editedDraft: String,
        correspondentEmail: String,
        citations: [Citation],
        languageID: String?
    ) -> [TrainingSignal]
}
