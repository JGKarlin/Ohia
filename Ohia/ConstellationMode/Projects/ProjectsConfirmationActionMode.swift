import OhiaML

/// Resolves the selected Projects message's confirmation control into the same
/// three states and glyph language used by the Front Page right rail.
enum ProjectsConfirmationActionMode {
    case confirm
    case confirmed
    case markNeeded

    static func resolve(mark: ProjectMessageMark) -> ProjectsConfirmationActionMode {
        if mark.obligationKinds.contains(.confirmation) { return .confirm }
        if mark.isConfirmed { return .confirmed }
        return .markNeeded
    }

    var glyph: ActionDiscGlyph {
        switch self {
        case .confirmed: return .knockout("checkmark.seal.fill")
        case .confirm, .markNeeded: return .knockout("seal.fill")
        }
    }

    var label: String { "Confirmed" }

    var help: String {
        switch self {
        case .confirm: return "Mark confirmed"
        case .confirmed: return "Mark unconfirmed"
        case .markNeeded: return "Mark confirmation needed"
        }
    }

    var isActive: Bool {
        if case .confirmed = self { return true }
        return false
    }
}
