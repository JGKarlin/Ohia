import AppKit

@MainActor
enum WindowMenuIconDecorator {
    private struct WindowMenuPresentation {
        let symbolName: String
        let keyEquivalent: String
    }

    private static let windowPresentations: [String: WindowMenuPresentation] = [
        "Constellation": .init(
            symbolName: "point.3.filled.connected.trianglepath.dotted",
            keyEquivalent: "1"
        ),
        "Composer": .init(
            symbolName: "square.and.pencil",
            keyEquivalent: "2"
        ),
    ]

    private static var observedMenu: NSMenu?
    private static var observerTokens: [NSObjectProtocol] = []
    private static var installRetryCount = 0

    static func install() {
        guard let menu = NSApplication.shared.windowsMenu else {
            scheduleInstallRetry()
            return
        }

        installRetryCount = 0

        guard observedMenu !== menu else {
            decorate(menu)
            return
        }

        removeObservers()
        observedMenu = menu

        let center = NotificationCenter.default
        observerTokens = [
            center.addObserver(
                forName: NSMenu.didAddItemNotification,
                object: menu,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    decorateObservedMenu()
                }
            },
            center.addObserver(
                forName: NSMenu.didChangeItemNotification,
                object: menu,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    decorateObservedMenu()
                }
            },
            center.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: menu,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    decorateObservedMenu()
                }
            },
        ]

        decorate(menu)
    }

    private static func scheduleInstallRetry() {
        guard installRetryCount < 8 else {
            return
        }

        installRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { @MainActor in
                install()
            }
        }
    }

    private static func removeObservers() {
        let center = NotificationCenter.default
        for token in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    private static func decorateObservedMenu() {
        guard let menu = observedMenu ?? NSApplication.shared.windowsMenu else {
            return
        }

        decorate(menu)
    }

    static func decorate(_ menu: NSMenu) {
        for item in menu.items {
            guard let presentation = windowPresentations[item.title] else {
                continue
            }

            if item.image == nil,
               let image = NSImage(
                   systemSymbolName: presentation.symbolName,
                   accessibilityDescription: item.title
               ) {
                image.isTemplate = true
                item.image = image
            }

            item.keyEquivalent = presentation.keyEquivalent
            item.keyEquivalentModifierMask = [.command]
        }
    }
}
