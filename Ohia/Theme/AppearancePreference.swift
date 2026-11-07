import SwiftUI

// User-level override for Light/Dark appearance.
//
// `.dark` is the default on first launch.
// `.light` / `.dark` pin the preferred color scheme at every scene
// root via `.preferredColorScheme`, which cascades to the window's
// NSAppearance and makes the dynamic NSColor tokens in `OhiaColors`
// resolve to the chosen palette.

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "Auto (System)"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

// Apply this to the root view of every top-level Scene so the user's
// Settings → General choice takes effect across the app (main window,
// Compose windows, Settings itself).
struct AppearancePreferenceModifier: ViewModifier {
    @AppStorage("appearance") private var raw: String = AppearancePreference.dark.rawValue

    func body(content: Content) -> some View {
        let pref = AppearancePreference(rawValue: raw) ?? .dark
        content.preferredColorScheme(pref.colorScheme)
    }
}

extension View {
    func applyAppearancePreference() -> some View {
        modifier(AppearancePreferenceModifier())
    }
}
