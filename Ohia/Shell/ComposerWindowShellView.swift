import SwiftUI

struct ComposerWindowShellView: View {
    @State private var initialMessageID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    init() {
        _initialMessageID = State(initialValue: AppCommand.pendingComposerFocusMessageID())
    }

    var body: some View {
        GeometryReader { geometry in
            ComposerView(initialMessageID: initialMessageID)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(ComposerNightSkyBackdrop())
        .background(NightSkyWindowChrome(isDark: colorScheme == .dark))
        .onAppear {
            if let pending = AppCommand.pendingComposerFocusMessageID() {
                initialMessageID = pending
                AppCommand.clearPendingComposerFocusMessageID()
            }
        }
    }
}
