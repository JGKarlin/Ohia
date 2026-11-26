import AppKit
import OhiaUninstallKit
import SwiftUI

/// The uninstaller's one window: confirmation, progress, then the outcome.
struct UninstallerView: View {
    let model: UninstallerModel
    /// The outcome's tallest content for the window's screen, from
    /// `WindowFrameKeeper`; the least height until the window reports it.
    @State private var finishedHeightCap = FinishedWindowLayout.minimumHeight

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .font(.system(size: 13))
        .foregroundStyle(OhiaColors.textPrimary)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        // 420 tall, except the outcome, which grows to show all of itself up
        // to its cap (620 points for the whole window, less on a small
        // screen) and scrolls beyond that. Fixed at its ideal height, the
        // content sets the window's size (the scene's contentSize
        // resizability); the keeper holds the window inside its screen.
        .frame(width: 480)
        .frame(minHeight: Self.height, maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowFrameKeeper { finishedHeightCap = $0 })
        .background(OhiaColors.wizardBackground)
        .tint(OhiaColors.chipActiveForeground)
        .windowDismissBehavior(model.isRunning ? .disabled : .automatic)
        .task { await model.start() }
    }

    /// The window's height in every state but the outcome, and the
    /// outcome's least.
    private static let height = FinishedWindowLayout.minimumHeight

    private var maximumHeight: CGFloat {
        guard case .finished = model.phase else { return Self.height }
        return finishedHeightCap
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image("ohia")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
    }

    private var title: String {
        if case .finished(let completion) = model.phase {
            return completion.report.isClean ? "Ohia was removed" : "Some items were not removed"
        }
        return "Uninstall Ohia"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checkingAccess, .confirm, .running:
            confirmation
        case .needsAccess(let stillDenied):
            VStack(alignment: .leading, spacing: 12) {
                // "Later" is the System Settings sheet's own label
                // (QUIT_LATER, beside QUIT_APP "Quit & Reopen"); reopening
                // from there would drop the uninstaller's arguments.
                message(stillDenied
                    ? "Uninstall Ohia still can't access Ohia's data. Turn it on in System Settings, then click Continue. If System Settings offers to quit and reopen Uninstall Ohia, choose Later, then click Continue here."
                    : "macOS is asking whether Uninstall Ohia may access Ohia's data. Click Allow in that message, then click Continue.")
                if model.relaunch == .failed {
                    message("Uninstall Ohia could not restart itself. Quit it, then open it again.")
                }
            }
        case .finished(let completion):
            report(completion)
        case .ohiaStillRunning:
            message("Ohia didn't quit. Save your work in Ohia, quit it, then try again.")
        case .ohiaStillRunningAfterCleanup(let cleanupReported):
            message(cleanupReported
                ? "Ohia ran its cleanup but didn't quit, so its files are still here. Quit Ohia, then try again."
                : "Ohia didn't report back and didn't quit, so its files are still here. Quit Ohia, then try again.")
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This permanently removes Ohia and everything it stored on this Mac:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                row("Ohia app", value: model.inventory.map { Self.sizeText($0.appBytes ?? 0) }, measures: true)
                // macOS lets only Ohia open the folder with its mail, models
                // and index; the uninstaller measures it only with Full Disk
                // Access, and leaves the row out when there is no folder.
                switch model.inventory?.groupContainer {
                case nil:
                    row("Mail, models and index", measures: true)
                case .notMeasured?:
                    row("Mail, models and index", value: "Not measured")
                case .measured(let bytes)?:
                    // Measured, so even zero is a size, never "Not found".
                    row("Mail, models and index", value: bytes.formatted(.byteCount(style: .file)))
                case .absent?:
                    EmptyView()
                }
                row("Other Ohia data",
                    value: model.inventory.map { Self.sizeText($0.dataBytes) }, measures: true)
                row("Saved passwords and sign-ins", value: "\(model.keychainServiceCount) keychain services")
                row("Settings, web data, permissions")
                row("The \"Ohia\" calendar and its events")
            }
            .padding(.leading, 12)
            Text("Your mailboxes, Mail, Messages, Notes, Contacts and other calendars are not changed.")
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line of the confirmation list. A row that `measures` shows a
    /// spinner until its size is known.
    private func row(_ label: String, value: String? = nil, measures: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.textSecondary)
            } else if measures {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    private func report(_ completion: UninstallCompletion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Outside the scroll view, so a long list still says how long it is.
            if let countLine = completion.report.leftoverCountLine {
                Text(countLine)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
            }
            reportList(completion)
        }
    }

    private func reportList(_ completion: UninstallCompletion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(completion.report.leftovers.enumerated(), id: \.offset) { _, leftover in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(leftover.item)
                            .fontWeight(.semibold)
                            .textSelection(.enabled)
                        Text(leftover.reason)
                            .foregroundStyle(OhiaColors.textSecondary)
                        Text(leftover.nextStep)
                            .textSelection(.enabled)
                    }
                }
                if !completion.report.otherCopies.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("These other copies of Ohia were left in place:")
                        ForEach(completion.report.otherCopies, id: \.self) { copy in
                            Text(copy.path)
                                .foregroundStyle(OhiaColors.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                if completion.otherAccountsKeepData {
                    Text("Other accounts on this Mac keep their own Ohia data.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if case .running(let step) = model.phase {
                ProgressView()
                    .controlSize(.small)
                Text(Self.describe(step))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            buttons
                .fixedSize()
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.phase {
        case .checkingAccess, .confirm, .running:
            HStack(spacing: 10) {
                Button("Cancel") { NSApp.terminate(nil) }
                    .buttonStyle(Self.emblem(tint: OhiaColors.ohiaGreen))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRunning)
                Button("Uninstall") { model.uninstall() }
                    .buttonStyle(Self.emblem(tint: OhiaColors.ohiaRed))
                    .disabled(model.phase != .confirm)
            }
        case .needsAccess(let stillDenied):
            HStack(spacing: 10) {
                Button("Cancel") { NSApp.terminate(nil) }
                    .buttonStyle(Self.emblem(tint: OhiaColors.ohiaGreen))
                    .keyboardShortcut(.cancelAction)
                if stillDenied {
                    Button("Open System Settings") { model.openPrivacySettings() }
                        .buttonStyle(Self.emblem(tint: OhiaColors.ohiaGreen))
                }
                Button("Continue") { model.continueAfterAccess() }
                    .buttonStyle(Self.emblem(tint: OhiaColors.ohiaGreen))
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.relaunch == .pending)
            }
        case .finished:
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(Self.emblem(tint: OhiaColors.ohiaGreen))
        case .ohiaStillRunning, .ohiaStillRunningAfterCleanup:
            Button("Try Again") { model.uninstall() }
                .buttonStyle(Self.emblem(tint: OhiaColors.ohiaGreen))
        }
    }

    private static func emblem(tint: Color) -> EmblemButtonStyle {
        EmblemButtonStyle(tint: tint, horizontalPadding: 18, verticalPadding: 7)
    }

    // MARK: - Text

    /// A measured size, or "Not found" when nothing of it is on this Mac.
    private static func sizeText(_ bytes: Int64) -> String {
        bytes > 0 ? bytes.formatted(.byteCount(style: .file)) : "Not found"
    }

    private static func describe(_ step: UninstallStep) -> String {
        switch step {
        case .quittingOhia: "Quitting Ohia"
        case .cleaningUp: "Ohia is removing its data, saved passwords and calendar"
        case .resettingPermissions: "Resetting privacy permissions"
        case .removingApp: "Removing the Ohia app"
        case .removingData: "Removing Ohia's data"
        case .askingAdministrator: "Waiting for an administrator password"
        case .done: "Finishing"
        }
    }
}
