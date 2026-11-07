// Ohia/Settings/OhiaSettingsCard.swift
// The Settings card — the slab a group of settings sits on.
//
// This replaces `Form(.grouped)`'s section box, which cannot be used over the
// night-sky backdrop: the system's section fill is not a fill at all but a ~3%
// white *overlay* (measured — a grouped Form's card renders as its backdrop
// plus 3% white). Over stars that yields "sky plus haze", never black, and no
// API reaches it: `.listRowBackground` is inert on a macOS grouped Form, and
// `FormStyleConfiguration` vends only `content`, so a custom `FormStyle`
// structurally cannot draw per-section cards. Drawing the card ourselves is
// the only way to own the fill.
//
// Consequence: this also re-implements the light appearance, since one code
// path draws both. Light mirrors the system grouped-form look
// (`controlBackgroundColor` over the standard window background) rather than
// the night sky, per §18's two-paired-palettes rule — the sky is dark-only.

import SwiftUI
import AppKit

/// A titled group of settings: an optional header above a rounded card.
///
/// Rows are laid out by the caller with `SettingsRow` / `SettingsCaption` and
/// separated by `SettingsRowDivider`. Dividers are explicit rather than
/// auto-inserted because SwiftUI offers no public way to enumerate a
/// `ViewBuilder`'s children — the alternative is `_VariadicView`, an
/// underscored API this codebase avoids.
struct OhiaSettingsCard<Content: View>: View {
    private let title: String?
    private let content: Content

    /// Matches the corner radius the grouped Form drew, so the pane's silhouette
    /// is unchanged by the conversion.
    private static var cornerRadius: CGFloat { 10 }

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(.leading, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(OhiaColors.settingsCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
            )
        }
    }
}

/// One settings row: a leading label with its control pushed to the trailing
/// edge. Reproduces the grouped-Form row that `LabeledContent` / `Toggle` /
/// `Picker` only get for free *inside* a Form — in a plain stack they render
/// label-and-control adjacent instead of spread.
struct SettingsRow<Control: View>: View {
    private let label: String
    private let control: Control

    /// Tracks `.disabled(…)` applied to the row. Inside a Form the label was
    /// part of the control (`Picker("Default reminder", …)`) and greyed out
    /// with it; split apart, the label needs to dim itself or a disabled row
    /// reads as half-live.
    @Environment(\.isEnabled) private var isEnabled

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(isEnabled ? OhiaColors.textPrimary : OhiaColors.textTertiary)
                // The control below carries the name for VoiceOver; without
                // this the row would announce twice.
                .accessibilityHidden(true)
            Spacer(minLength: 12)
            // Controls in these rows are built with `Toggle("", …)` /
            // `Picker("", …)` + `.labelsHidden()`, which leaves them unnamed —
            // inside a Form the label argument supplied the name.
            control.accessibilityLabel(label)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// A free-form row for content that isn't a label/control pair (an explanatory
/// block, a slider with its own caption, a disclosure group).
struct SettingsBlock<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// The secondary explanatory text that sat under a control as its own Form row.
struct SettingsCaption: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
    }
}

/// Hairline between rows, inset from the leading edge the way the grouped
/// Form's row separators were.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 14)
    }
}

/// A stronger, full-width break between groups of related rows within one card.
///
/// The grouped Form separated every row automatically, so an explicit
/// `Divider()` in the source read as an *extra* break marking a group boundary
/// (e.g. the three filter axes: direction, read, replied). Row separators are
/// now drawn explicitly and inset, so the group boundary needs to stay
/// distinguishable from them — it runs full width.
struct SettingsGroupDivider: View {
    var body: some View {
        Divider()
    }
}

/// Applies the black-card GroupBox style in dark only. In light the system
/// GroupBox material is left alone — restyling it would silently redraw the
/// Accounts, Models and Developer panes in an appearance this change is not
/// meant to touch.
private struct SettingsGroupBoxStyling: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content.groupBoxStyle(.ohiaSettingsCard)
        } else {
            content
        }
    }
}

extension View {
    func settingsGroupBoxStyling() -> some View {
        modifier(SettingsGroupBoxStyling())
    }
}

/// Renders every `GroupBox` in Settings as an `OhiaSettingsCard`.
///
/// Applied once at the Settings root, this converts the GroupBox-based panes
/// (Accounts, Models, Developer — ~19 call sites) without touching any of them:
/// `GroupBox`'s own fill is a system material, which over the night sky would
/// render as stars-through-haze exactly like the grouped Form's section box.
/// Unlike `FormStyle`, `GroupBoxStyle.Configuration` vends both `label` and
/// `content`, so the card can be drawn around them here.
///
/// The label stays *inside* the card, where `GroupBox` already drew it, rather
/// than being promoted to a card title — these panes are laid out against that.
struct OhiaSettingsCardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        OhiaSettingsCard {
            SettingsBlock {
                configuration.label
                configuration.content
            }
        }
    }
}

extension GroupBoxStyle where Self == OhiaSettingsCardGroupBoxStyle {
    static var ohiaSettingsCard: OhiaSettingsCardGroupBoxStyle { .init() }
}

/// Paints a night-sky window's title bar black in dark mode.
///
/// The title bar is window chrome, not content, so no SwiftUI background
/// reaches it — it kept drawing the system's tinted grey above the black
/// sidebar and the night sky, leaving a seam along the top edge. Making the
/// title bar transparent lets the window's own background colour show through
/// it, so setting that colour to black covers the bar.
///
/// Light is left exactly as macOS drew it. The original background is captured
/// once and restored rather than re-asserting `windowBackgroundColor`: the
/// window's real fill is desktop-tinted (the measured `#2B2A29` is not the
/// semantic colour's nominal value), so asserting the token would visibly
/// flatten light mode instead of leaving it untouched.
struct NightSkyWindowChrome: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSView {
        // `viewDidMoveToWindow` rather than an async hop: the window is nil
        // until the view joins the hierarchy, and this fires exactly then.
        let view = WindowObservingView()
        view.onMoveToWindow = { [weak coordinator = context.coordinator] window in
            guard let coordinator else { return }
            apply(to: window, coordinator: coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView.window, coordinator: context.coordinator)
    }

    /// Puts the window back the way it was found. Without this, AppKit reusing
    /// the Settings NSWindow across a close/reopen would let the next
    /// Coordinator capture our own black as the "original" and then restore
    /// black into light mode.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func apply(to window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        coordinator.captureOriginalIfNeeded(of: window)

        window.titlebarAppearsTransparent = isDark ? true : coordinator.originalTitlebarTransparent
        window.backgroundColor = isDark ? .black : coordinator.originalBackground
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var didCaptureOriginal = false
        private(set) var originalBackground: NSColor?
        private(set) var originalTitlebarTransparent = false

        func captureOriginalIfNeeded(of window: NSWindow) {
            guard !didCaptureOriginal else { return }
            self.window = window
            originalBackground = window.backgroundColor
            originalTitlebarTransparent = window.titlebarAppearsTransparent
            didCaptureOriginal = true
        }

        func restore() {
            guard didCaptureOriginal, let window else { return }
            window.backgroundColor = originalBackground
            window.titlebarAppearsTransparent = originalTitlebarTransparent
        }
    }
}

/// Reports the moment it gains a window, so chrome can be applied deterministically.
private final class WindowObservingView: NSView {
    var onMoveToWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(window)
    }
}
