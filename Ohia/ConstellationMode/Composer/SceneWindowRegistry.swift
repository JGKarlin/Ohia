import AppKit
import SwiftUI

extension Notification.Name {
    static let ohiaSceneWindowDidRegister = Notification.Name("ohia.scene-window.did-register")
}

/// Resolves the app's scene `NSWindow`s by their `OhiaWindowID` so non-SwiftUI
/// code — specifically the send-to-Composer dispatch heading — can read their
/// live screen frames. Each scene registers its hosting window via
/// `.registerSceneWindow(id:)`, mirroring the `NSViewRepresentable` window-accessor
/// idiom already used by `WindowCloseHidesScene`. Entries hold the window weakly,
/// so a closed window drops out and never resurrects a stale frame.
@MainActor
final class SceneWindowRegistry {
    static let shared = SceneWindowRegistry()

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow?) { self.window = window }
    }

    private var entries: [String: WeakWindow] = [:]

    private init() {}

    func register(_ window: NSWindow?, for id: String) {
        guard let window else { return }
        entries[id] = WeakWindow(window)
        NotificationCenter.default.post(
            name: .ohiaSceneWindowDidRegister,
            object: window,
            userInfo: ["id": id]
        )
    }

    /// The registered window for `id`, or nil if never registered or already
    /// deallocated (the dead entry is pruned).
    func window(for id: String) -> NSWindow? {
        guard let entry = entries[id] else { return nil }
        if entry.window == nil { entries[id] = nil }
        return entry.window
    }
}

extension View {
    /// Registers the hosting `NSWindow` under `id` in `SceneWindowRegistry` so its
    /// screen frame can be resolved later. Mount once on a scene's root content.
    func registerSceneWindow(id: String) -> some View {
        background(
            SceneWindowRegistrar(id: id)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

private struct SceneWindowRegistrar: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        register(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        register(from: nsView)
    }

    private func register(from view: NSView) {
        let id = id
        // `view.window` is nil until the view is installed in its window, so hop
        // to the next main-loop turn (the accessor idiom used app-wide here).
        DispatchQueue.main.async { [weak view] in
            MainActor.assumeIsolated {
                SceneWindowRegistry.shared.register(view?.window, for: id)
            }
        }
    }
}
