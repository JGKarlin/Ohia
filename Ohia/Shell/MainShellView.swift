// Ohia/Shell/MainShellView.swift
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

struct MainShellView: View {
    @State private var constellationReady = false
    /// The night-sky launch backdrop stays up until the lens reports it has
    /// *settled* its surface (`onLensSurfaceDidSettle`), then fades. This is a
    /// separate, later signal from `constellationReady` (which makes the
    /// returning-user surface interactive immediately, before the lens has
    /// drawn any content) so the backdrop
    /// survives the lens's heavy first paint — closing the brief flat-black gap
    /// that used to appear between the loading sky and the painted lens.
    @State private var launchSkyVisible = true
    @State private var onboardingHasRenderedNode = false
    @State private var openedStartupComposer = false
    @AppStorage("hasCompletedFirstIngestion", store: OhiaSharedDefaults.store)
    private var hasCompletedFirstIngestion = false
    @AppStorage(
        OnboardingPipelineGate.hasReachedWitnessPanelKey,
        store: OhiaSharedDefaults.store
    )
    private var hasReachedOnboardingWitnessPanel = false
    @AppStorage("constellationSidebarVisible") private var constellationSidebarVisible = true
    @AppStorage("showConstellationActivityStrip") private var showActivityStrip = true

    // AppServices is @Observable — read via @Environment, not @EnvironmentObject.
    @Environment(AppServices.self) private var appServices: AppServices?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geometry in
            let onboardingActive = !hasCompletedFirstIngestion
            let contentReady = onboardingActive || constellationReady
            let activityStripVisible = showActivityStrip
            ZStack {
                OhiaColors.spaceBackground.ignoresSafeArea()

                // Night-sky launch backdrop. It bridges the splash hand-off AND
                // survives the lens's heavy first paint: it is held until the
                // lens reports it has *settled* its surface (which fades
                // `launchSkyVisible`), NOT the much-earlier `constellationReady`
                // (which fires on the lens's first appear, before it has drawn
                // anything). That early signal is exactly what left a brief
                // flat-black gap between the loading sky and the painted lens —
                // the backdrop dropped out while the heavy `ConstellationModeView`
                // was still painting its first frame, exposing the flat
                // `spaceBackground` base. Holding it until settle closes that
                // gap; once the lens has painted, it sits opaque on top and the
                // backdrop fades behind it with no seam (same deterministic
                // field). Scoped to the returning-user path — onboarding carries
                // its own witness backdrop. Shooting stars stay off here; the
                // single meteor belongs to the splash's moon sequence.
                if launchSkyVisible && !onboardingActive {
                    // This bridge can remain mounted while the first packet is
                    // built. Keep it static so a slow startup refresh never
                    // drives an unseen 30 fps SwiftUI layout loop behind the
                    // interactive lens scene.
                    NightSkyView(twinkles: false)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    ZStack {
                        BlankModeSurface()
                            .opacity(contentReady ? 0 : 1)

                        constellationContent(onboardingActive: onboardingActive)
                            .opacity(contentReady ? 1 : 0)
                            .allowsHitTesting(contentReady)
                            .accessibilityHidden(!contentReady)
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Gradual dissolve from the night sky into the Constellation
                    // scene (rather than a quick 0.2s cut).
                    .animation(.easeInOut(duration: 1.0), value: constellationReady)

                    if activityStripVisible {
                        ActivityStripView(mode: .constellation)
                            .frame(width: geometry.size.width, alignment: .leading)
                            .clipped()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .animation(.easeInOut(duration: 0.2), value: showActivityStrip)

                if !hasCompletedFirstIngestion {
                    OnboardingWitnessPanel(
                        hasRenderedNode: onboardingHasRenderedNode,
                        onEnter: completeFirstIngestion
                    )
                    .onAppear {
                        hasReachedOnboardingWitnessPanel = true
                    }
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .onAppear {
            // A returning user's last lens is usable independently of any new
            // mail being processed. The packet-ready callback still retires the
            // launch backdrop, but it must never own input availability.
            if Self.shouldMarkConstellationReadyOnAppear(
                hasCompletedFirstIngestion: hasCompletedFirstIngestion
            ) {
                markConstellationReady()
            }
            openStartupComposerIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaShowFocus)) { notification in
            guard let messageID = focusMessageID(from: notification) else { return }
            openComposer(messageID: messageID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaShowComposer)) { _ in
            openComposer(messageID: nil)
        }
        .onChange(of: hasCompletedFirstIngestion) { _, newValue in
            if newValue {
                constellationReady = true
                openStartupComposerIfNeeded()
            } else {
                onboardingHasRenderedNode = false
                constellationReady = false
                openedStartupComposer = false
                // Dev reset re-enters onboarding then re-runs the splash → lens
                // sequence; re-arm the launch backdrop so the next settle fades
                // it again.
                launchSkyVisible = true
            }
        }
    }

    nonisolated static func shouldMarkConstellationReadyOnAppear(
        hasCompletedFirstIngestion: Bool
    ) -> Bool {
        hasCompletedFirstIngestion
    }

    nonisolated static func sidebarVisibilityAfterCompletingFirstIngestion(
        currentVisibility _: Bool
    ) -> Bool {
        false
    }

    @ViewBuilder
    private func constellationContent(onboardingActive: Bool = false) -> some View {
        if let services = appServices {
            ConstellationModeView(
                services: services,
                onExitToFocus: { uuid in
                    openComposer(messageID: uuid)
                },
                onInitialSceneReady: { markConstellationReady() },
                onFirstVisibleNodeRendered: {
                    onboardingHasRenderedNode = true
                },
                onLensSurfaceDidSettle: { retireLaunchSky() },
                onboardingMode: onboardingActive
            )
        } else {
            BlankModeSurface()
                .onAppear { markConstellationReady() }
        }
    }

    private func openComposer(messageID: UUID?) {
        guard hasCompletedFirstIngestion else { return }
        if let messageID {
            AppCommand.requestComposerFocus(messageID: messageID)
        }
        openWindow(id: OhiaWindowID.composer)
    }

    private func openStartupComposerIfNeeded() {
        guard !openedStartupComposer,
              hasCompletedFirstIngestion,
              AppCommand.pendingNotificationFocusMessageID() == nil,
              StartupViewPreference.stored() == .composer else {
            return
        }
        openedStartupComposer = true
        openComposer(messageID: nil)
    }

    private func focusMessageID(from notification: Notification) -> UUID? {
        if let id = notification.userInfo?["messageID"] as? UUID {
            return id
        }
        if let raw = notification.userInfo?["messageID"] as? String {
            return UUID(uuidString: raw)
        }
        return nil
    }

    private func markConstellationReady() {
        // Match the inner crossfade duration so the night sky fades out as the
        // Constellation scene fades in — a gradual dissolve, not a cut.
        withAnimation(.easeInOut(duration: 1.0)) {
            constellationReady = true
        }
    }

    /// Retire the night-sky launch backdrop once the lens has settled its
    /// surface. The fade is slow enough to outlast the lens's first content
    /// paint (so the hand-off never exposes flat black) and is invisible
    /// regardless: it fades behind the now-painted, opaque lens, and the lens's
    /// own backdrop draws the identical deterministic starfield.
    private func retireLaunchSky() {
        guard launchSkyVisible else { return }
        withAnimation(.easeInOut(duration: 0.8)) {
            launchSkyVisible = false
        }
    }

    private func completeFirstIngestion() {
        withAnimation(.easeInOut(duration: 0.4)) {
            constellationSidebarVisible = Self.sidebarVisibilityAfterCompletingFirstIngestion(
                currentVisibility: constellationSidebarVisible
            )
            constellationReady = true
            hasCompletedFirstIngestion = true
        }
    }
}

/// The loading placeholder shown before the Constellation scene is ready.
/// Transparent on purpose: the full-window `NightSkyView` behind the shell
/// shows through, so the night sky carried over from the splash persists here
/// rather than a flat grey fill.
private struct BlankModeSurface: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}
