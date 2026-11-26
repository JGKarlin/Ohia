import SwiftUI

/// Settings → General card for Sparkle updates. Shown only when the app has
/// an update controller (builds with a feed); otherwise it renders nothing.
struct UpdatesSettingsCard: View {
    @Environment(OhiaUpdateController.self) private var updateController: OhiaUpdateController?

    var body: some View {
        if let updateController {
            UpdatesSettingsCardContent(controller: updateController)
        }
    }
}
