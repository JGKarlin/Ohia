import Foundation
import OhiaIngest

enum WizardStep: Int, CaseIterable {
    case welcome
    case appleIntelligence
    case accountDiscovery
    case mailSetup
    case historySelection
    case languageSelection
    case ready

    var next: WizardStep? {
        WizardStep(rawValue: rawValue + 1)
    }

    /// True for steps before account persistence. Navigating Back to one
    /// of these discards the in-progress persisted Account (and detected
    /// languages) so a changed selection re-derives everything on the way
    /// forward. Defined by an exhaustive switch rather than a rawValue
    /// comparison so reordering the cases can't silently move this boundary.
    var isBeforeAccountPersistence: Bool {
        switch self {
        case .welcome, .appleIntelligence, .accountDiscovery:
            return true
        case .mailSetup, .historySelection, .languageSelection, .ready:
            return false
        }
    }

    func canAdvance(
        selectedAccount: DiscoveredAccount?,
        selectedLanguages: [String]
    ) -> Bool {
        switch self {
        case .welcome:          return true
        case .accountDiscovery: return selectedAccount != nil
        case .mailSetup:        return true  // advance is driven only by a successful SMTP save
        case .historySelection: return true
        case .languageSelection:return !selectedLanguages.isEmpty
        case .appleIntelligence:return true
        case .ready:            return true
        }
    }
}
