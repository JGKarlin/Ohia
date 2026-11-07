import Foundation
import SwiftData
import OhiaCore

/// User-managed lifecycle operations for Composer styles. Styles span
/// accounts and are language-scoped; deletion is a soft retirement so old
/// draft revisions retain truthful provenance.
public enum StyleRegisterCatalog {
    public enum CatalogError: LocalizedError, Equatable {
        case invalidName
        case missingLanguage
        case styleNotFound
        case wrongLanguage
        case lastStyleForLanguage
        case nameTaken(String)

        public var errorDescription: String? {
            switch self {
            case .invalidName:
                "Enter a style name between 1 and \(StyleRegisterDistiller.maxGeneratedNameCharacters) characters."
            case .missingLanguage:
                "This draft needs a language before its style can be saved."
            case .styleNotFound:
                "This style is no longer available."
            case .wrongLanguage:
                "This style does not belong to the selected language."
            case .lastStyleForLanguage:
                "At least one active style is required for this language."
            case .nameTaken(let name):
                "A style named “\(name)” already exists for this language."
            }
        }
    }

    /// Styles span accounts, so a name identifies one style per language
    /// in the pulldown; letter case and accents do not make a new name.
    @MainActor
    private static func requireUnusedName(_ name: String, languages: [String], excluding id: UUID?,
                                          context: ModelContext) throws {
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        let target = folded(name)
        let taken = StyleRegisterResolver.activeRegisters(context: context).contains { register in
            register.id != id && !Set(register.languages).isDisjoint(with: languages) && folded(register.name) == target
        }
        if taken { throw CatalogError.nameTaken(name) }
    }

    @MainActor
    @discardableResult
    public static func saveCustomStyle(
        name: String,
        axes: StyleAxisValues,
        languageID: String?,
        context: ModelContext,
        now: Date = .now
    ) throws -> StyleRegister {
        let trimmed = try validatedName(name)
        guard let languageID = DraftLanguage.familyID(for: languageID) else {
            throw CatalogError.missingLanguage
        }
        let id = UUID()
        let language = StyleLanguageToken.normalize(languageID)
        try requireUnusedName(trimmed, languages: [language], excluding: nil, context: context)
        let register = StyleRegister(
            id: id,
            registerKey: "saved|\(language)|\(id.uuidString.lowercased())",
            name: trimmed,
            summary: "A custom style saved from your Style control settings.",
            styleAxes: axes,
            languages: [language],
            isUserSaved: true,
            isLearned: false,
            userRenamed: true,
            createdAt: now,
            updatedAt: now
        )
        context.insert(register)
        try context.save()
        return register
    }

    @MainActor
    public static func renameStyle(
        id: UUID,
        newName: String,
        context: ModelContext,
        now: Date = .now
    ) throws {
        let trimmed = try validatedName(newName)
        guard let register = fetch(id: id, context: context), register.isActive else {
            throw CatalogError.styleNotFound
        }
        guard register.name != trimmed else { return }
        try requireUnusedName(trimmed, languages: register.languages, excluding: id, context: context)
        register.name = trimmed
        register.userRenamed = true
        register.revision += 1
        register.updatedAt = now
        try context.save()
    }

    /// Retires `id` and returns the active style that should replace it when
    /// the deleted style was selected. The caller owns draft-local selection
    /// and regeneration because reply and standalone compose queue work
    /// through different hosts.
    @MainActor
    @discardableResult
    public static func deleteStyle(
        id: UUID,
        languageID: String?,
        context: ModelContext,
        now: Date = .now
    ) throws -> StyleRegister {
        guard let register = fetch(id: id, context: context), register.isActive else {
            throw CatalogError.styleNotFound
        }
        guard let languageID = DraftLanguage.familyID(for: languageID) else {
            throw CatalogError.missingLanguage
        }
        guard StyleRegisterResolver.covers(register, language: languageID) else {
            throw CatalogError.wrongLanguage
        }
        let remaining = StyleRegisterResolver
            .activeRegisters(context: context)
            .filter {
                $0.id != register.id
                    && StyleRegisterResolver.covers($0, language: languageID)
            }
        guard let replacement = remaining.first else {
            throw CatalogError.lastStyleForLanguage
        }

        register.isActive = false
        register.userDeletedAt = now
        register.updatedAt = now
        try context.save()
        return replacement
    }

    @MainActor
    private static func fetch(id: UUID, context: ModelContext) -> StyleRegister? {
        var descriptor = FetchDescriptor<StyleRegister>(
            predicate: #Predicate<StyleRegister> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func validatedName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= StyleRegisterDistiller.maxGeneratedNameCharacters else {
            throw CatalogError.invalidName
        }
        return trimmed
    }
}
